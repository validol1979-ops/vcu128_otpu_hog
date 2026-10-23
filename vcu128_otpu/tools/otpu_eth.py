"""EthTransport: связь ПК с openTPU на VCU128 по 40G Ethernet (UDP), замена XdmaTransport.

Протокол — vcu128_otpu/doc/eth40_protocol.md, сторона платы — src/eth40/otpu_eth_bridge.sv.
Интерфейс тот же, что у upstream opentpu.host.board.XdmaTransport, поэтому

    from opentpu.host.board import Board
    from otpu_eth import EthTransport
    b = Board(transport=EthTransport("192.168.41.2"))

работает как с картой PCIe: mem_write / mem_read (канал j = 2s + c, смещение в канале),
reg_write / reg_read / reg_read_many (окно BAR0: 0x00000 ядро, 0x30000, 0x40000, 0x50000),
poll (опрос выполняет плата: (reg & mask) == val), close; атрибуты, которые смотрит Board
(threaded, streams, ecc, run_h2c, host_idle, bases, devname, poll_exact).

Надёжность: у каждого запроса SEQ; запись памяти — окно из многих кадров, подтверждение
приходит после того, как данные в памяти (B AXI), потерянное — повтор (запись
идемпотентна); чтение — запросы диапазонов, недостающие куски запрашиваются заново;
операции с регистрами — по одной пачке на сокет, повтор с тем же SEQ получает
сохранённый платой ответ (запись не выполняется дважды).

Скорость: окна записи и чтения выполняет помощник на C (otpu_eth_fast.c, sendmmsg /
recvmmsg, собирается gcc при первом использовании в ~/.cache/otpu_eth, root не нужен);
без gcc — тот же алгоритм на Python (медленнее, порядка сотен МБ/с).
Буферы сокетов ограничены net.core.rmem_max/wmem_max (по умолчанию 208 КиБ): окно чтения
по умолчанию выбирается по фактическому буферу приёма (2 запроса при 208 КиБ, до 8 при
`net.core.rmem_max=67108864` — `tools/host/install.sh`, root, однократно).
"""
from __future__ import annotations

import ctypes
import errno
import hashlib
import os
import random
import select
import socket
import struct
import subprocess
import threading
import time
from pathlib import Path

import numpy as np

# ------------------------------------------------------------------------------ протокол
MAGIC_REQ = 0x3034544F          # байты "OT40"
MAGIC_RESP = 0x5234544F         # байты "OT4R"
OP_WRITE, OP_READ, OP_REG = 1, 2, 3
ST_OK, ST_AXI, ST_BAD, ST_TIMEOUT = 0, 1, 2, 3
RO_WRITE, RO_READ, RO_POLL = 1, 2, 3
HDR = struct.Struct("<IIBBIII")  # MAGIC, SEQ, OP, CH/STATUS, OFFSET, LEN, AUX: 22 байта
OPREC = struct.Struct("<IIII")   # операция регистров: код|адрес, данные/маска, значение, таймаут
PHDR = HDR.size
BEAT = 64
MAXW = 8192                     # байт данных в кадре (MTU 9000)
READ_WINDOW_MAX = 8             # запросов чтения в полёте (очередь дескрипторов платы — 8)
REGMAX = 256                    # операций в пачке
ETH_CLK_HZ = 312_500_000        # такты таймаута опроса: eth_clk = tx_clk_out l_ethernet, 312,5 МГц (clocks.rpt)
PORT = 0x4F54                   # 20308
BOARD_IP = "192.168.41.2"
CH_BYTES = 1 << 31
BASE = (0x0000_0000, 0x8000_0000)
M32 = 0xFFFFFFFF
STATUS_NAMES = {ST_OK: "OK", ST_AXI: "AXI error", ST_BAD: "bad request",
                ST_TIMEOUT: "poll timeout"}


class EthError(IOError):
    """Плата ответила ошибкой (STATUS != 0) или не ответила."""


def pack_req(seq: int, op: int, ch: int, off: int, length: int, aux: int = 0,
             payload: bytes = b"") -> bytes:
    return HDR.pack(MAGIC_REQ, seq & M32, op, ch, off & M32, length & M32, aux & M32) + payload


def unpack_resp(b: bytes) -> tuple | None:
    """(seq, op, status, off, len, aux) или None, если это не ответ протокола."""
    if len(b) < PHDR:
        return None
    m, seq, op, st, off, ln, aux = HDR.unpack_from(b)
    if m != MAGIC_RESP:
        return None
    return seq, op, st, off, ln, aux


def op_write(addr: int, val: int) -> bytes:
    return OPREC.pack(RO_WRITE << 28 | (addr & 0xFFFFF), val & M32, 0, 0)


def op_read(addr: int) -> bytes:
    return OPREC.pack(RO_READ << 28 | (addr & 0xFFFFF), 0, 0, 0)


def op_poll(addr: int, mask: int, val: int, cycles: int) -> bytes:
    return OPREC.pack(RO_POLL << 28 | (addr & 0xFFFFF), mask & M32, val & M32,
                      min(max(int(cycles), 0), M32))


# ------------------------------------------------------------------------------ цель VCU128
TARGET_TOML = Path(__file__).resolve().parents[1] / "target" / "vcu128.toml"
PLATFORM_ID = 3


def install_target() -> bool:
    """Научить upstream opentpu.target.by_platform цели VCU128 (platform_id 3), которой нет
    в upstream targets/: Board.info берёт по ней формулу температуры (family "xilinxus",
    SYSMONE4), иначе temp_c считается по формуле XADC 7-series (на ~4 °C выше). Upstream не
    меняется: обёртка над функцией модуля (Board.info импортирует её при каждом вызове).
    Без opentpu в PYTHONPATH — ничего; True — обёртка стоит."""
    try:
        import opentpu.target as T
    except ImportError:
        return False
    if getattr(T.by_platform, "_vcu128", False):
        return True
    orig = T.by_platform

    def by_platform(pid: int):
        t = orig(pid)
        if t is None and pid == PLATFORM_ID and TARGET_TOML.exists():
            t = T.load(str(TARGET_TOML))
        return t

    by_platform._vcu128 = True
    T.by_platform = by_platform
    return True


# ------------------------------------------------------------------------------ помощник на C
_FAST = None
_FAST_LOCK = threading.Lock()


def _fast_lib():
    """otpu_eth_fast.so из исходника рядом (собирается один раз, кэш по хэшу); None — нет gcc
    или OTPU_ETH_NOFAST=1."""
    global _FAST
    with _FAST_LOCK:
        if _FAST is not None:
            return _FAST or None
        _FAST = False
        if os.environ.get("OTPU_ETH_NOFAST"):
            return None
        src = Path(__file__).with_name("otpu_eth_fast.c")
        try:
            code = src.read_bytes()
            cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "otpu_eth"
            so = cache / f"otpu_eth_fast_{hashlib.sha1(code).hexdigest()[:12]}.so"
            if not so.exists():
                cache.mkdir(parents=True, exist_ok=True)
                tmp = so.with_suffix(f".{os.getpid()}.tmp")
                subprocess.run(["gcc", "-O2", "-shared", "-fPIC", "-o", str(tmp), str(src)],
                               check=True, capture_output=True)
                os.replace(tmp, so)
            lib = ctypes.CDLL(str(so), use_errno=True)
        except (OSError, subprocess.CalledProcessError):
            return None
        P, I, U64, D = ctypes.c_void_p, ctypes.c_int, ctypes.c_uint64, ctypes.c_double
        pu32, pi64, pint, pu64 = (ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_int64),
                                  ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint64))
        lib.oe_write.argtypes = [I, pu32, I, U64, P, U64, I, I, D, I, pi64, pint, pu64]
        lib.oe_read.argtypes = [I, pu32, I, U64, P, U64, I, I, I, D, I, pi64, pint, pu64]
        lib.oe_emu.argtypes = [I, P, U64, I, P]          # плата-заглушка (замеры, тесты)
        lib.oe_write.restype = lib.oe_read.restype = lib.oe_emu.restype = I
        _FAST = lib
        return lib


def _buf_addr(a: np.ndarray) -> int:
    return a.__array_interface__["data"][0]


# ------------------------------------------------------------------------------ транспорт
class EthTransport:
    """Плата по 40G Ethernet. host — IP платы (eth40_regs IP, по умолчанию 192.168.41.2),
    port — порт UDP платы. Два подключённых сокета: память и регистры (у каждого свой
    поток SEQ и своя блокировка), так что опрос регистра из одного потока не ждёт
    передачи памяти из другого, как у XDMA (BAR0 и DMA независимы).

    window — кадров записи без подтверждения (по 8 КиБ; приёмная FIFO платы 128 КиБ);
    read_req / read_window — байт в запросе чтения и запросов в полёте (в полёте не больше
    буфера приёма сокета; None — по фактическому SO_RCVBUF, 2…READ_WINDOW_MAX);
    rto — таймаут повтора, с; retries — повторов одного кадра."""
    ecc = False                 # HBM без инициализации ECC хостом (Board.scrub не нужен)
    threaded = True             # Board может звать mem_* из рабочего потока
    streams = True              # память доступна во время прогона (отдельный сокет)
    run_h2c = 0                 # ограничения XDMA H2C нет
    host_idle = 0.0
    bases = BASE
    poll_exact = True           # опрос — чтения подряд на плате

    def __init__(self, host: str = BOARD_IP, port: int = PORT, *, window: int = 12,
                 read_req: int = 96 << 10, read_window: int | None = None, frame: int = MAXW,
                 rto: float = 0.02, reg_rto: float = 0.05, retries: int = 50,
                 poll_slice: float = 0.01, bufsize: int = 64 << 20, fast: bool | None = None,
                 devname: str | None = None, lock: bool = False):
        if frame % BEAT or not BEAT <= frame <= MAXW:
            raise ValueError(f"frame {frame}: multiple of 64, 64..{MAXW}")
        self.host, self.port = host, port
        self.window, self.frame, self.rto, self.reg_rto = window, frame, rto, reg_rto
        self.read_req = max(frame, read_req // frame * frame)
        self.read_window, self.retries, self.poll_slice = read_window, retries, poll_slice
        self.devname = devname or f"otpu-eth-{host}"
        self.dev = f"udp://{host}:{port}"
        self.stats = {"tx": 0, "resend": 0, "stray": 0, "rx": 0, "reg": 0, "reg_resend": 0}
        self.poll_exact = True
        self._otpu_lock = None
        if lock:            # как XdmaTransport: замок устройства до открытия (иначе его
            from opentpu.host.runstate import DeviceLock    # берёт Board по devname)
            self._otpu_lock = DeviceLock(self.devname)
        self._mlock, self._rlock = threading.RLock(), threading.RLock()
        self._mseq = random.getrandbits(32)
        self._rseq = random.getrandbits(32)
        self.msock = self.rsock = None
        try:
            self.msock = self._sock(bufsize)
            self.rsock = self._sock(1 << 20)
            if read_window is None:         # ядро удваивает SO_RCVBUF: половина — под данные
                rcv = self.msock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF) // 2
                self.read_window = max(2, min(READ_WINDOW_MAX, rcv // self.read_req))
        except BaseException:
            self.close()
            raise
        install_target()
        self._fast = _fast_lib() if fast in (None, True) else None
        if fast and self._fast is None:
            raise RuntimeError("otpu_eth_fast: no C helper (gcc?)")

    def _sock(self, bufsize: int) -> socket.socket:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for opt in (socket.SO_RCVBUF, socket.SO_SNDBUF):
            try:
                s.setsockopt(socket.SOL_SOCKET, opt, bufsize)   # (обрезается rmem_max)
            except OSError:
                pass
        # подключённый сокет: ядро держит одну очередь передачи (кадры не обгоняют друг
        # друга) и отбрасывает дейтаграммы не от платы
        s.connect((self.host, self.port))
        s.setblocking(False)
        return s

    def close(self) -> None:
        for name in ("msock", "rsock"):
            s = getattr(self, name, None)
            if s is not None:
                s.close()
                setattr(self, name, None)
        if getattr(self, "_otpu_lock", None) is not None:
            self._otpu_lock.release()
            self._otpu_lock = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # ---------------------------------------------------------------- память
    def mem_write(self, ch: int, off: int, data: np.ndarray) -> None:
        """Целые 64-байтные beat: диапазон не по границам beat расширяется, крайние beat
        читаются и сливаются здесь (как XdmaTransport.mem_write)."""
        a = np.ascontiguousarray(data, np.uint8).reshape(-1)
        if len(a) == 0:
            return
        if off % BEAT or len(a) % BEAT:
            o0, o1 = off // BEAT * BEAT, -(-(off + len(a)) // BEAT) * BEAT
            if o1 - o0 == BEAT:
                buf = self.mem_read(ch, o0, BEAT)
            else:
                buf = np.empty(o1 - o0, np.uint8)
                buf[:BEAT] = self.mem_read(ch, o0, BEAT)
                buf[-BEAT:] = self.mem_read(ch, o1 - BEAT, BEAT)
            buf[off - o0:off - o0 + len(a)] = a
            a, off = buf, o0
        self._check(ch, off, len(a))
        with self._mlock:
            if self._fast is not None:
                self._fast_write(ch, off, a)
            else:
                self._py_write(ch, off, a)

    def mem_read(self, ch: int, off: int, n: int, out: np.ndarray | None = None) -> np.ndarray:
        """n байт канала ch со смещения off (в out, если дан)."""
        buf = np.empty(n, np.uint8) if out is None else out
        if n == 0:
            return buf
        o0, o1 = off // BEAT * BEAT, -(-(off + n) // BEAT) * BEAT
        self._check(ch, o0, o1 - o0)
        direct = (o0, o1) == (off, off + n) and buf.flags.c_contiguous and buf.dtype == np.uint8
        tgt = buf if direct else np.empty(o1 - o0, np.uint8)
        with self._mlock:
            if self._fast is not None:
                self._fast_read(ch, o0, tgt)
            else:
                self._py_read(ch, o0, tgt)
        if not direct:
            buf.reshape(-1)[:] = tgt[off - o0:off - o0 + n]
        return buf

    @staticmethod
    def _check(ch: int, off: int, n: int) -> None:
        if not 0 <= ch < 256 or off < 0 or off + n > CH_BYTES:
            raise ValueError(f"channel {ch} [{off:#x}, +{n:#x}) outside 2 GiB")

    def _status(self, st: int, what: str, off: int):
        raise EthError(f"{what}: board answered {STATUS_NAMES.get(st, st)} (offset {off:#x})")

    def _fast_call(self, fn, ch, off, buf, *args):
        seq = ctypes.c_uint32(self._mseq)
        stats = (ctypes.c_int64 * 4)()
        st, bad = ctypes.c_int(0), ctypes.c_uint64(0)
        rc = fn(self.msock.fileno(), ctypes.byref(seq), ch, off, _buf_addr(buf), len(buf),
                *args, stats, ctypes.byref(st), ctypes.byref(bad))
        self._mseq = seq.value
        return rc, list(stats), st.value, bad.value

    def _fast_write(self, ch, off, a):
        rc, s, st, bad = self._fast_call(self._fast.oe_write, ch, off, a, self.frame,
                                         self.window, self.rto, self.retries)
        self.stats["tx"] += s[0]
        self.stats["resend"] += s[1]
        self.stats["stray"] += s[2]
        self._rc(rc, st, bad, "memory write")

    def _fast_read(self, ch, off, a):
        rc, s, st, bad = self._fast_call(self._fast.oe_read, ch, off, a, self.frame,
                                         self.read_req, self.read_window, self.rto, self.retries)
        self.stats["tx"] += s[0]
        self.stats["resend"] += s[1]
        self.stats["stray"] += s[2]
        self.stats["rx"] += s[3]
        self._rc(rc, st, bad, "memory read")

    def _rc(self, rc, st, bad, what):
        if rc == -1:
            raise OSError(ctypes.get_errno() or errno.EIO, f"{what}: socket error")
        if rc == -2:
            raise EthError(f"{what}: no answer from {self.host}:{self.port} "
                           f"after {self.retries} retries")
        if rc == -3:
            self._status(st, what, bad)

    # ---- тот же алгоритм на Python (без gcc; медленнее)
    def _recv_all(self, s: socket.socket, wait: float):
        """Принятые дейтаграммы: ждёт до wait секунд первую, затем берёт всё, что есть."""
        out = []
        if wait > 0:
            r, _, _ = select.select([s], [], [], wait)
            if not r:
                return out
        while True:
            try:
                out.append(s.recv(MAXW + 256))
            except (BlockingIOError, InterruptedError):
                return out
            except ConnectionRefusedError:      # ICMP «порт закрыт»: как потеря
                continue

    def _send(self, s: socket.socket, parts) -> None:
        while True:
            try:
                s.sendmsg(parts)
                return
            except (BlockingIOError, InterruptedError):
                select.select([], [s], [], 0.01)
            except ConnectionRefusedError:
                return

    def _py_write(self, ch, off, a):
        s, pkt, n = self.msock, self.frame, len(a)
        npk = -(-n // pkt)
        seq0 = self._mseq
        self._mseq = (seq0 + npk) & M32
        mv = memoryview(a)
        sent, tries, acked = [0.0] * npk, [0] * npk, bytearray(npk)
        nxt = base = done = inflight = 0

        def send(i):
            o = i * pkt
            k = min(pkt, n - o)
            self._send(s, [pack_req(seq0 + i, OP_WRITE, ch, off + o, k), mv[o:o + k]])
            sent[i] = time.monotonic()
            tries[i] += 1
            self.stats["tx"] += 1

        while done < npk:
            now = time.monotonic()
            for i in range(base, nxt):
                if not acked[i] and now - sent[i] > self.rto:
                    if tries[i] > self.retries:
                        self._rc(-2, 0, 0, "memory write")
                    self.stats["resend"] += 1
                    send(i)
            while nxt < npk and inflight < self.window:
                send(nxt)
                nxt += 1
                inflight += 1
            for b in self._recv_all(s, 0.001):
                r = unpack_resp(b)
                if r is None or r[1] != OP_WRITE:
                    self.stats["stray"] += 1
                    continue
                i = (r[0] - seq0) & M32
                if i >= npk or acked[i]:
                    self.stats["stray"] += 1
                    continue
                if r[2] != ST_OK:
                    self._status(r[2], "memory write", r[3])
                acked[i] = 1
                done += 1
                inflight -= 1
            while base < nxt and acked[base]:
                base += 1

    def _py_read(self, ch, off, a):
        s, fsz, n = self.msock, self.frame, len(a)
        nf = -(-n // fsz)
        fpr = self.read_req // fsz
        got = bytearray(nf)
        seq0 = self._mseq
        act = []                                # [seq, f0, nf, left, t, tries]
        redo = []                               # (f0, nf, tries)
        next_f = ngot = 0
        while ngot < nf:
            while len(act) < self.read_window and (redo or next_f < nf):
                if redo:
                    f0, k, tr = redo.pop()
                    self.stats["resend"] += 1
                else:
                    f0, k, tr = next_f, min(fpr, nf - next_f), 0
                    next_f += k
                left = k - sum(got[f0:f0 + k])
                if not left:
                    continue
                if tr > self.retries:
                    self._rc(-2, 0, 0, "memory read")
                o, e = f0 * fsz, min(n, (f0 + k) * fsz)
                q = [self._mseq, f0, k, left, 0.0, tr + 1]
                self._mseq = (self._mseq + 1) & M32
                self._send(s, [pack_req(q[0], OP_READ, ch, off + o, e - o, fsz)])
                q[4] = time.monotonic()
                self.stats["tx"] += 1
                act.append(q)
            issued = (self._mseq - seq0) & M32
            for b in self._recv_all(s, 0.001):
                r = unpack_resp(b)
                if r is None or r[1] != OP_READ or ((r[0] - seq0) & M32) >= issued:
                    self.stats["stray"] += 1
                    continue
                if r[2] != ST_OK:
                    self._status(r[2], "memory read", r[3])
                fo = (r[3] - off) & M32
                if fo % fsz or fo >= n:
                    self.stats["stray"] += 1
                    continue
                f = fo // fsz
                want = min(fsz, n - fo)
                if r[4] != want or len(b) < PHDR + want or got[f]:
                    self.stats["stray"] += 1
                    continue
                a[fo:fo + want] = np.frombuffer(b, np.uint8, want, PHDR)
                got[f] = 1
                ngot += 1
                self.stats["rx"] += 1
                for q in act:
                    if q[1] <= f < q[1] + q[2]:
                        q[3] -= 1
                        q[4] = time.monotonic()
                        break
            now = time.monotonic()
            keep = []
            for q in act:
                if q[3] and now - q[4] > self.rto:
                    f = q[1]
                    while f < q[1] + q[2]:
                        if got[f]:
                            f += 1
                            continue
                        g = f
                        while g < q[1] + q[2] and not got[g]:
                            g += 1
                        redo.append((f, g - f, q[5]))
                        f = g
                    q[3] = 0
                if q[3]:
                    keep.append(q)
            act = keep

    # ---------------------------------------------------------------- регистры
    def reg_batch(self, ops: list[bytes], timeout: float | None = None) -> tuple[int, int, list]:
        """Одна пачка операций (op_write / op_read / op_poll, не больше REGMAX): (STATUS,
        операций выполнено, результаты чтений). Повтор по таймауту — с тем же SEQ: плата
        отвечает сохранённым ответом, не выполняя пачку снова."""
        if not 0 < len(ops) <= REGMAX:
            raise ValueError(f"{len(ops)} register operations (1..{REGMAX})")
        rto = self.reg_rto if timeout is None else timeout
        s = self.rsock
        with self._rlock:
            seq = self._rseq
            self._rseq = (seq + 1) & M32
            req = pack_req(seq, OP_REG, 0, 0, len(ops), 0, b"".join(ops))
            for attempt in range(self.retries + 1):
                if attempt:
                    self.stats["reg_resend"] += 1
                self._send(s, [req])
                self.stats["reg"] += 1
                t_end = time.monotonic() + rto
                while (left := t_end - time.monotonic()) > 0:
                    for b in self._recv_all(s, left):
                        r = unpack_resp(b)
                        if r is None or r[1] != OP_REG or r[0] != seq:
                            self.stats["stray"] += 1
                            continue
                        _, _, st, done, nres, _ = r
                        if st == ST_BAD:
                            raise EthError(f"register batch rejected by the board "
                                           f"(operation {r[5]})")
                        if len(b) < PHDR + 4 * nres:
                            self.stats["stray"] += 1
                            continue
                        return st, done, list(struct.unpack_from(f"<{nres}I", b, PHDR))
            raise EthError(f"registers: no answer from {self.host}:{self.port} "
                           f"after {self.retries} retries")

    def _regs(self, ops: list[bytes]) -> list[int]:
        out = []
        for i in range(0, len(ops), REGMAX):
            st, done, vals = self.reg_batch(ops[i:i + REGMAX])
            if st != ST_OK:
                raise EthError(f"register operation {i + done}: {STATUS_NAMES.get(st, st)}")
            out += vals
        return out

    def reg_write(self, off: int, val: int) -> None:
        self._regs([op_write(off, val)])

    def reg_read(self, off: int) -> int:
        return self._regs([op_read(off)])[0]

    def reg_read_many(self, offs: list[int]) -> list[int]:
        return self._regs([op_read(o) for o in offs]) if offs else []

    def reg_write_many(self, pairs: list[tuple[int, int]]) -> None:
        if pairs:
            self._regs([op_write(o, v) for o, v in pairs])

    def poll(self, off: int, mask: int, val: int, timeout: float = 600.0,
             expect: float = 0.0) -> int:
        """Ждать (reg & mask) == val. Опрашивает плата (чтения подряд, eth_clk), отрезками
        до poll_slice секунд: между ними — проверка общего таймаута и Ctrl-C на ПК, а
        другие потоки успевают со своими пачками. expect не нужен (ожидание без сна)."""
        t0 = time.monotonic()
        while True:
            left = timeout - (time.monotonic() - t0)
            sl = max(0.0, min(self.poll_slice, left))
            st, _, vals = self.reg_batch([op_poll(off, mask, val, sl * ETH_CLK_HZ)],
                                         timeout=sl + self.reg_rto)
            r = vals[0] if vals else 0
            if st == ST_OK:
                return r
            if st != ST_TIMEOUT:
                raise EthError(f"poll {off:#x}: {STATUS_NAMES.get(st, st)}")
            if time.monotonic() - t0 > timeout:
                raise TimeoutError(f"register {off:#x} = {r:#x}, waiting for {val:#x}/{mask:#x}")

    # ---------------------------------------------------------------- регистры моста
    R_ETH = 0x50000
    ETH_REGS = {"ID": 0x00, "VERSION": 0x04, "LINK": 0x08, "STATUS": 0x0C, "MAC_LO": 0x14,
                "MAC_HI": 0x18, "IP": 0x1C, "PORT": 0x20, "PARAMS": 0x24}
    ETH_COUNTERS = ("rx_frames", "rx_bad", "rx_accept", "rx_ignore", "rx_overflow",
                    "arp_req", "arp_tx", "mac_ctl", "req_write", "req_read", "req_reg",
                    "req_dup", "req_busy", "req_bad", "tx_frames", "rd_frames", "axi_err")

    def eth_info(self) -> dict:
        """Регистры eth40_regs (окно 0x50000): идентификатор, линк, состояние, счётчики."""
        names = list(self.ETH_REGS) + list(self.ETH_COUNTERS)
        offs = [self.R_ETH + o for o in self.ETH_REGS.values()] + \
               [self.R_ETH + 0x40 + 4 * i for i in range(len(self.ETH_COUNTERS))]
        return dict(zip(names, self.reg_read_many(offs)))
