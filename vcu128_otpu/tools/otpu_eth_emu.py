"""Эмулятор платы для EthTransport: протокол doc/eth40_protocol.md на UDP (127.0.0.1),
как его выполняет otpu_eth_bridge, поверх модели памяти и регистров. Для тестов
(test_otpu_eth.py) и отладки ПК без платы.

    python otpu_eth_emu.py --port 20308 [--fake] [--drop 0.01] [--dup 0.01] [--reorder 0.01]

Модель (backend) — объект с mem_write / mem_read / reg_read / reg_write: по умолчанию
MemRegs (каналы в ОЗУ, регистры-словарь, пара тестовых регистров, модель термоконтроля
ThermalRegs в окне 0x40000), с --fake — upstream
opentpu.host.fake.FakeTransport (нужен импорт opentpu). Ошибки сети вводятся в обе стороны:
потеря, дубликат, перестановка (кадр придерживается и уходит после следующего).
Повторы пачек регистров обслуживаются из кэша последнего ответа (SEQ, IP, порт), как на
плате; счётчики — в Emulator.stats.
"""
from __future__ import annotations

import argparse
import random
import socket
import struct
import threading
import time

import numpy as np

from otpu_eth import (ETH_CLK_HZ, HDR, MAGIC_REQ, MAGIC_RESP, MAXW, OP_READ, OP_REG, OP_WRITE,
                      OPREC, PHDR, PORT, REGMAX, RO_POLL, RO_READ, RO_WRITE, ST_AXI, ST_BAD,
                      ST_OK, ST_TIMEOUT)

# тестовые регистры MemRegs
R_STROBE = 0x0FF0       # запись: +1 к R_STROBE_N (как CTRL.run: побочный эффект)
R_STROBE_N = 0x0FF4
R_TIMER = 0x0FE0        # запись t (мкс): через t мкс чтение даёт 1, до того 0
R_BAD = 0x0FD0          # доступ — ошибка AXI (SLVERR)


class ThermalRegs:
    """Модель термоконтроля платформы (vcu128_thermal, окно 0x40000: STATUS биты 19..21 и
    0x20..0x5C; doc/design.md «Температура и контроль»): те же пороги с гистерезисом,
    защёлки, максимумы, HOLD и возврат. Температуры задаются полями slr_c (°C, None — SLR
    не прочитан) и hbm_c / hbm_cattrip; состояние пересчитывается при каждом доступе
    (как будто после каждого раунда опроса SYSMON)."""
    BASE = 0x40000
    NSLR = 3

    def __init__(self, slr_c=(41.0, 43.5, 42.25), hbm_c=(35, 36)):
        self.slr_c = list(slr_c)
        self.hbm_c = list(hbm_c)
        self.hbm_cattrip = [False, False]
        self.vcc = (0.85, 1.80, 0.85)
        self.act, self.auto, self.cattrip_act, self.force = True, False, True, False
        self.fpga_lim = [85, 100, 10]
        self.hbm_lim = [85, 95, 5]
        n = self.NSLR + 2
        self.warn, self.alarm = [False] * n, [False] * n
        self.warn_l, self.alarm_l = [False] * n, [False] * n
        self.cattrip_l = self.hold = self.hold_l = False
        self.tmax: list = [None] * n
        self.n_hold = self.n_warn = self.n_abort = 0
        self.ctl_writes: list[int] = []       # CTRL = 0 от guard (модель: список)

    @staticmethod
    def code12(t: float) -> int:
        return max(0, min(4095, round((t + 280.2308787) * 4096 / 509.3140064)))

    @staticmethod
    def q4(code: int) -> int:
        return ((code * 32596 + 8192) >> 14) - 4484

    def _cur(self) -> list:
        """Текущие значения в 1/16 °C (None — нет)."""
        v = [None if c is None else self.q4(self.code12(c)) for c in self.slr_c]
        return v + [16 * int(h) for h in self.hbm_c]

    def update(self, resume: bool = False) -> None:
        cur = self._cur()
        wa = any(self.warn)
        for i, t in enumerate(cur):
            w, a, h = self.fpga_lim if i < self.NSLR else self.hbm_lim
            if t is None:
                self.warn[i] = self.alarm[i] = False
                continue
            if t >= 16 * w:
                self.warn[i] = True
            elif t < 16 * (w - h):
                self.warn[i] = False
            if t >= 16 * a:
                self.alarm[i] = True
            elif t < 16 * (a - h):
                self.alarm[i] = False
            self.warn_l[i] |= self.warn[i]
            self.alarm_l[i] |= self.alarm[i]
            self.tmax[i] = t if self.tmax[i] is None else max(self.tmax[i], t)
        if any(self.warn) and not wa:
            self.n_warn += 1
        ct = any(self.hbm_cattrip)
        self.cattrip_l |= ct
        cool = not any(self.alarm) and not (self.cattrip_act and ct)
        trig = (self.act and (any(self.alarm) or (self.cattrip_act and ct))) or self.force
        if not self.hold and trig:
            self.hold = self.hold_l = True
            self.n_hold += 1
            self.n_abort += 1
            self.ctl_writes.append(0)
        elif self.hold and not self.force and (not self.act or (cool and (self.auto or resume))):
            self.hold = False
        self.hold_l |= self.hold

    def owns(self, off: int) -> bool:
        o = off - self.BASE
        return o == 0x04 or 0x20 <= o < 0x60

    def read(self, off: int) -> int:
        self.update()
        o = off - self.BASE
        n = self.NSLR + 2
        bits = lambda v: sum(1 << i for i, b in enumerate(v) if b)
        lim = lambda L: L[2] << 16 | L[1] << 8 | L[0]
        cur = self._cur()
        if o == 0x04:                   # STATUS: locks, HBM calibrated, thermal bits
            return (any(self.warn) << 19 | any(self.alarm_l) << 20 | self.hold << 21
                    | self.hbm_cattrip[0] << 3 | self.hbm_cattrip[1] << 4 | 0x3 << 1 | 1)
        if o == 0x20:
            return 1 << 16 | 1 << 8 | 0 << 4 | self.NSLR
        if o == 0x24:
            return self.act | self.auto << 1 | self.cattrip_act << 2 | self.force << 3
        if o == 0x28:
            ct = any(self.hbm_cattrip)
            cool = not any(self.alarm) and not (self.cattrip_act and ct)
            valid = all(c is not None for c in self.slr_c)
            return (any(self.warn) | any(self.alarm) << 1 | ct << 2 | self.hold << 3
                    | any(self.warn_l) << 4 | any(self.alarm_l) << 5 | self.cattrip_l << 6
                    | self.hold_l << 7 | cool << 8 | valid << 9
                    | bits(self.warn_l) << 16 | bits(self.alarm_l) << 24)
        if o == 0x2C:
            return lim(self.fpga_lim)
        if o == 0x30:
            return lim(self.hbm_lim)
        if o == 0x34:
            return min(self.n_warn, 0xFFFF) << 16 | min(self.n_hold, 0xFFFF)
        if o == 0x38:
            codes = [self.code12(c) for c in self.slr_c if c is not None]
            return max(codes, default=0)
        if o == 0x3C:
            return self.n_abort & 0xFFFF
        if 0x40 <= o < 0x40 + 4 * self.NSLR:
            s = (o - 0x40) // 4
            c, m = cur[s], self.tmax[s]
            return ((0x8000 if m is None else m & 0xFFFF) << 16) | (0 if c is None else c & 0xFFFF)
        if o == 0x4C:
            h = [x // 16 for x in cur[self.NSLR:]]
            m = [0 if x is None else x // 16 for x in self.tmax[self.NSLR:]]
            return h[0] | h[1] << 8 | m[0] << 16 | m[1] << 24
        if 0x50 <= o < 0x50 + 4 * self.NSLR:
            c = [min(1023, round(v * 1024 / 3)) for v in self.vcc]
            return c[0] | c[1] << 10 | c[2] << 20
        return 0

    def write(self, off: int, val: int) -> None:
        o = off - self.BASE
        if o == 0x24:
            self.act, self.auto = bool(val & 1), bool(val & 2)
            self.cattrip_act, self.force = bool(val & 4), bool(val & 8)
            if val & 1 << 9:
                n = self.NSLR + 2
                self.warn_l, self.alarm_l = [False] * n, [False] * n
                self.cattrip_l = self.hold_l = False
            if val & 1 << 10:
                self.tmax = [None] * (self.NSLR + 2)
            self.update(resume=bool(val & 1 << 8))
        elif o == 0x2C:
            self.fpga_lim = [val & 0xFF, val >> 8 & 0xFF, val >> 16 & 0xFF]
        elif o == 0x30:
            self.hbm_lim = [val & 0xFF, val >> 8 & 0xFF, val >> 16 & 0xFF]


class MemRegs:
    def __init__(self, nch: int = 4, ch_bytes: int = 1 << 24, thermal: bool = True):
        self.ch = [np.zeros(ch_bytes, np.uint8) for _ in range(nch)]
        self.regs: dict[int, int] = {}
        self.writes: list[tuple[int, int]] = []
        self._t_ready = 0.0
        self.thermal = ThermalRegs() if thermal else None

    def mem_write(self, ch, off, data):
        self.ch[ch][off:off + len(data)] = data

    def mem_read(self, ch, off, n, out=None):
        return self.ch[ch][off:off + n].copy()

    def reg_write(self, off, val):
        if off == R_BAD:
            raise IOError("SLVERR")
        self.writes.append((off, val))
        if self.thermal is not None and self.thermal.owns(off):
            self.thermal.write(off, val)
        elif off == R_STROBE:
            self.regs[R_STROBE_N] = self.regs.get(R_STROBE_N, 0) + 1
        elif off == R_TIMER:
            self._t_ready = time.monotonic() + val * 1e-6
        else:
            self.regs[off] = val

    def reg_read(self, off):
        if off == R_BAD:
            raise IOError("SLVERR")
        if off == R_TIMER:
            return int(time.monotonic() >= self._t_ready)
        if self.thermal is not None and self.thermal.owns(off):
            return self.thermal.read(off)
        return self.regs.get(off, 0)


class Emulator:
    def __init__(self, backend=None, host: str = "127.0.0.1", port: int = PORT,
                 nch: int = 4, drop: float = 0.0, dup: float = 0.0, reorder: float = 0.0,
                 seed: int = 1):
        self.be = backend if backend is not None else MemRegs(nch)
        self.nch = nch
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for opt in (socket.SO_RCVBUF, socket.SO_SNDBUF):
            self.sock.setsockopt(socket.SOL_SOCKET, opt, 64 << 20)
        self.sock.bind((host, port))
        self.port = self.sock.getsockname()[1]
        self.drop, self.dup, self.reorder = drop, dup, reorder
        self.rng = random.Random(seed)
        self.held = None                        # придержанный для перестановки кадр
        self.cache = None                       # ((seq, ip, port), ответ)
        self.stats = dict(req=0, write=0, read=0, reg=0, dup=0, bad=0, rx_drop=0, tx_drop=0,
                          tx_dup=0, tx_reorder=0)
        self._stop = threading.Event()

    # ---------------------------------------------------------------- сеть с ошибками
    def _faulty(self) -> tuple[bool, bool, bool]:
        r = self.rng.random
        return r() < self.drop, r() < self.dup, r() < self.reorder

    def _tx(self, data: bytes, addr) -> None:
        drop, dup, reo = self._faulty()
        if drop:
            self.stats["tx_drop"] += 1
            return
        if reo and self.held is None:
            self.held = (data, addr)
            self.stats["tx_reorder"] += 1
            return
        self.sock.sendto(data, addr)
        if dup:
            self.stats["tx_dup"] += 1
            self.sock.sendto(data, addr)
        if self.held is not None:
            d, a = self.held
            self.held = None
            self.sock.sendto(d, a)

    def stop(self) -> None:
        self._stop.set()

    def serve(self) -> None:
        self.sock.settimeout(0.05)
        rx_held = None
        while not self._stop.is_set():
            try:
                b, addr = self.sock.recvfrom(65536)
            except socket.timeout:
                if self.held is not None:       # не держать дольше паузы
                    d, a = self.held
                    self.held = None
                    self.sock.sendto(d, a)
                if rx_held is not None:
                    self.handle(*rx_held)
                    rx_held = None
                continue
            drop, dup, reo = self._faulty()
            if drop:
                self.stats["rx_drop"] += 1
                continue
            if reo and rx_held is None:
                rx_held = (b, addr)
                continue
            self.handle(b, addr)
            if dup:
                self.handle(b, addr)
            if rx_held is not None:
                self.handle(*rx_held)
                rx_held = None

    # ---------------------------------------------------------------- протокол
    def _resp(self, addr, seq, op, st, off, ln, aux, data: bytes = b"") -> None:
        self._tx(HDR.pack(MAGIC_RESP, seq, op, st, off, ln, aux) + data, addr)

    def handle(self, b: bytes, addr) -> None:
        if len(b) < PHDR:
            return
        magic, seq, op, ch, off, ln, aux = HDR.unpack_from(b)
        if magic != MAGIC_REQ:                  # плата такой кадр не пропускает в разбор
            return
        self.stats["req"] += 1
        body = b[PHDR:]
        rng_ok = off % 64 == 0 and ln % 64 == 0 and ln > 0 and off + ln <= 1 << 31
        if op == OP_WRITE:
            if not (ch < self.nch and rng_ok and ln <= MAXW and len(body) == ln):
                return self._bad(addr, seq, op, off, ln, 0)
            self.stats["write"] += 1
            self.be.mem_write(ch, off, np.frombuffer(body, np.uint8))
            self._resp(addr, seq, OP_WRITE, ST_OK, off, ln, ch)
        elif op == OP_READ:
            fsz = aux or MAXW
            if not (ch < self.nch and rng_ok and fsz % 64 == 0 and 0 < fsz <= MAXW):
                return self._bad(addr, seq, op, off, ln, 0)
            self.stats["read"] += 1
            for o in range(0, ln, fsz):
                k = min(fsz, ln - o)
                d = np.asarray(self.be.mem_read(ch, off + o, k), np.uint8).tobytes()
                self._resp(addr, seq, OP_READ, ST_OK, off + o, k, off, d)
        elif op == OP_REG:
            key = (seq, addr[0], addr[1])
            if self.cache is not None and self.cache[0] == key:
                self.stats["dup"] += 1
                self._tx(self.cache[1], addr)
                return
            if not (0 < ln <= REGMAX and len(body) == 16 * ln):
                return self._bad(addr, seq, op, off, ln, 0)
            ops = [OPREC.unpack_from(body, 16 * i) for i in range(ln)]
            for i, (w0, *_r) in enumerate(ops):
                if w0 >> 28 not in (RO_WRITE, RO_READ, RO_POLL) or w0 & 0x0FF00003:
                    return self._bad(addr, seq, op, off, ln, i)
            self.stats["reg"] += 1
            st, done, res = ST_OK, 0, []
            for w0, w1, w2, w3 in ops:
                code, a = w0 >> 28, w0 & 0xFFFFF
                try:
                    if code == RO_WRITE:
                        self.be.reg_write(a, w1)
                    elif code == RO_READ:
                        res.append(self.be.reg_read(a) & 0xFFFFFFFF)
                    else:
                        t_end = time.monotonic() + w3 / ETH_CLK_HZ
                        while True:
                            v = self.be.reg_read(a) & 0xFFFFFFFF
                            if v & w1 == w2:
                                break
                            if time.monotonic() >= t_end:
                                st = ST_TIMEOUT
                                break
                        res.append(v)
                except (IOError, KeyError):
                    st = ST_AXI
                    if code != RO_WRITE:
                        res.append(0)
                if st != ST_OK:
                    break
                done += 1
            r = HDR.pack(MAGIC_RESP, seq, OP_REG, st, done, len(res), 2 if st == ST_AXI else 0)
            r += struct.pack(f"<{len(res)}I", *res)
            self.cache = (key, r)
            self._tx(r, addr)

    def _bad(self, addr, seq, op, off, ln, idx):
        self.stats["bad"] += 1
        self._resp(addr, seq, op, ST_BAD, off, ln, idx)


def run_process(port_q, kw: dict, fake: dict | None = None) -> None:
    """Точка входа процесса эмулятора (multiprocessing): порт — в port_q, затем работа
    до сигнала. fake — аргументы FakeTransport (тогда модель — upstream)."""
    be = None
    if fake is not None:
        from opentpu.host.fake import FakeTransport
        be = FakeTransport(**fake)
        kw = dict(kw, nch=len(be.ch))
    emu = Emulator(be, **kw)
    port_q.put(emu.port)
    emu.serve()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--fake", action="store_true", help="upstream FakeTransport as the model")
    ap.add_argument("--drop", type=float, default=0.0)
    ap.add_argument("--dup", type=float, default=0.0)
    ap.add_argument("--reorder", type=float, default=0.0)
    a = ap.parse_args()
    be = None
    if a.fake:
        from opentpu.host.fake import FakeTransport
        be = FakeTransport(devname=None, ch_bytes=1 << 24)
    emu = Emulator(be, a.host, a.port, nch=len(be.ch) if be else 4, drop=a.drop, dup=a.dup,
                   reorder=a.reorder)
    print(f"otpu_eth_emu on {a.host}:{emu.port}")
    emu.serve()


if __name__ == "__main__":
    main()
