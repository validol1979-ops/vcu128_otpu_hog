"""Эмулятор платы для EthTransport: протокол doc/eth40_protocol.md на UDP (127.0.0.1),
как его выполняет otpu_eth_bridge, поверх модели памяти и регистров. Для тестов
(test_otpu_eth.py) и отладки ПК без платы.

    python otpu_eth_emu.py --port 20308 [--fake] [--drop 0.01] [--dup 0.01] [--reorder 0.01]

Модель (backend) — объект с mem_write / mem_read / reg_read / reg_write: по умолчанию
MemRegs (каналы в ОЗУ, регистры-словарь, пара тестовых регистров), с --fake — upstream
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


class MemRegs:
    def __init__(self, nch: int = 4, ch_bytes: int = 1 << 24):
        self.ch = [np.zeros(ch_bytes, np.uint8) for _ in range(nch)]
        self.regs: dict[int, int] = {}
        self.writes: list[tuple[int, int]] = []
        self._t_ready = 0.0

    def mem_write(self, ch, off, data):
        self.ch[ch][off:off + len(data)] = data

    def mem_read(self, ch, off, n, out=None):
        return self.ch[ch][off:off + n].copy()

    def reg_write(self, off, val):
        if off == R_BAD:
            raise IOError("SLVERR")
        self.writes.append((off, val))
        if off == R_STROBE:
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
