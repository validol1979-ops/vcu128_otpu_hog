"""Окружение cocotb для otpu_eth_bridge (tb_eth40.sv): источник кадров MAC (RX, без
обратного давления, кадры подряд), приёмник кадров MAC (TX, с обратным давлением),
модели памяти каналов (AxiRam со случайными паузами всех каналов AXI), модель регистров
(AxiLiteRam) и ПК-сторона протокола (кодирование — из tools/otpu_eth.py)."""
from __future__ import annotations

import itertools
import logging
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, with_timeout
from cocotbext.axi import (AxiBus, AxiLiteBus, AxiLiteRam, AxiRam, AxiStreamBus,
                           AxiStreamFrame, AxiStreamSink, AxiStreamSource)
from scapy.layers.inet import IP, UDP
from scapy.layers.l2 import ARP, Ether
from scapy.packet import Raw

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import otpu_eth as P  # noqa: E402

PC_MAC, PC_IP = "1c:fd:08:76:77:f0", "192.168.41.1"
BOARD_MAC, BOARD_IP = "02:00:5e:41:00:01", "192.168.41.2"
PORT = P.PORT
SPORT = 40000
CLK_NS = 6.4                    # 156,25 МГц
R_ETH = 0x50000
EV = {n: i for i, n in enumerate(P.EthTransport.ETH_COUNTERS)}


def pause_gen(p: float, rng: random.Random):
    """Пауза в такте с вероятностью p, пачками (обратное давление и задержки)."""
    while True:
        if rng.random() < p:
            for _ in range(rng.randint(1, 8)):
                yield 1
        yield 0


def req_frame(payload: bytes, *, dst_mac=BOARD_MAC, dst_ip=BOARD_IP, dport=PORT,
              sport=SPORT, src_ip=PC_IP, src_mac=PC_MAC) -> bytes:
    f = Ether(src=src_mac, dst=dst_mac) / IP(src=src_ip, dst=dst_ip, flags="DF") / \
        UDP(sport=sport, dport=dport) / Raw(payload)
    b = bytes(f)
    return b + bytes(max(0, 60 - len(b)))


def arp_frame(target_ip: str, dst="ff:ff:ff:ff:ff:ff") -> bytes:
    b = bytes(Ether(src=PC_MAC, dst=dst) / ARP(op=1, hwsrc=PC_MAC, psrc=PC_IP, pdst=target_ip))
    return b + bytes(max(0, 60 - len(b)))


class Resp:
    """Разобранный ответ платы (проверены Ethernet/IP/UDP)."""

    def __init__(self, b: bytes, board_ip=BOARD_IP, board_mac=BOARD_MAC):
        e = Ether(b)
        assert e.dst == PC_MAC and e.src == board_mac, (e.dst, e.src)
        ip = e[IP]
        assert ip.version == 4 and ip.ihl == 5 and ip.proto == 17 and ip.ttl == 64
        assert ip.src == board_ip and ip.dst == PC_IP, (ip.src, ip.dst)
        chk = ip.chksum
        del ip.chksum
        assert IP(bytes(ip))[IP].chksum == chk, "IP checksum"
        u = e[UDP]
        assert u.sport == PORT and u.chksum == 0
        self.dport = u.dport
        pay = bytes(u.payload)
        assert u.len == 8 + len(pay) and ip.len == 28 + len(pay)
        r = P.unpack_resp(pay)
        assert r is not None, "MAGIC_RESP"
        self.seq, self.op, self.st, self.off, self.len, self.aux = r
        self.data = pay[P.PHDR:]
        self.raw = b

    def words(self) -> list[int]:
        import struct
        return list(struct.unpack(f"<{self.len}I", self.data[:4 * self.len]))


class TB:
    def __init__(self, dut, nc: int, seed: int = 1, axi_pause: float = 0.0,
                 tx_pause: float = 0.0, ram_size: int = 1 << 31):
        self.dut, self.nc = dut, nc
        self.rng = random.Random(seed)
        for name in ("cocotb.tb_eth40", "cocotbext", "cocotb"):
            logging.getLogger(name).setLevel(logging.WARNING)
        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.INFO)
        cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
        self.src = AxiStreamSource(AxiStreamBus.from_prefix(dut, "rx"), dut.clk, dut.rst)
        self.sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, "tx"), dut.clk, dut.rst)
        self.ram = [AxiRam(AxiBus.from_prefix(dut, f"m{j}"), dut.clk, dut.rst, size=ram_size)
                    for j in range(nc)]
        self.regs = AxiLiteRam(AxiLiteBus.from_prefix(dut, "r"), dut.clk, dut.rst, size=1 << 20)
        self.set_pauses(axi_pause, tx_pause)
        self.seq = itertools.count(self.rng.getrandbits(31))
        self.axil_writes = 0
        self.cycle = 0
        dut.link_stat.value = 0x1
        cocotb.start_soon(self._count())

    def set_pauses(self, axi: float, tx: float) -> None:
        for r in self.ram:
            for c in (r.write_if.aw_channel, r.write_if.w_channel, r.write_if.b_channel,
                      r.read_if.ar_channel, r.read_if.r_channel):
                if axi:
                    c.set_pause_generator(pause_gen(axi, random.Random(self.rng.random())))
                else:
                    c.clear_pause_generator()
        if tx:
            self.sink.set_pause_generator(pause_gen(tx, random.Random(self.rng.random())))
        else:
            self.sink.clear_pause_generator()

    async def _count(self):
        d = self.dut
        while True:
            await RisingEdge(d.clk)
            self.cycle += 1
            if d.r_awvalid.value and d.r_awready.value:
                self.axil_writes += 1

    async def reset(self):
        self.dut.rst.value = 1
        await ClockCycles(self.dut.clk, 10)
        self.dut.rst.value = 0
        await ClockCycles(self.dut.clk, 5)

    # ---------------------------------------------------------------- кадры
    async def send(self, frame: bytes, bad: bool = False):
        await self.src.send(AxiStreamFrame(frame, tuser=1 if bad else 0))

    async def recv(self, cycles: int = 20000) -> bytes:
        f = await with_timeout(self.sink.recv(), cycles * CLK_NS, "ns")
        return bytes(f.tdata)

    async def resp(self, cycles: int = 20000, **kw) -> Resp:
        return Resp(await self.recv(cycles), **kw)

    async def quiet(self, cycles: int = 2000) -> None:
        """Ни одного кадра на выходе за cycles тактов."""
        await ClockCycles(self.dut.clk, cycles)
        assert self.sink.empty(), "unexpected frame"

    def next_seq(self) -> int:
        return next(self.seq) & P.M32

    # ---------------------------------------------------------------- запросы
    def w_req(self, seq, ch, off, data: bytes, **kw) -> bytes:
        return req_frame(P.pack_req(seq, P.OP_WRITE, ch, off, len(data), 0, data), **kw)

    def r_req(self, seq, ch, off, n, fsz=0, **kw) -> bytes:
        return req_frame(P.pack_req(seq, P.OP_READ, ch, off, n, fsz), **kw)

    def g_req(self, seq, ops: list[bytes], **kw) -> bytes:
        return req_frame(P.pack_req(seq, P.OP_REG, 0, 0, len(ops), 0, b"".join(ops)), **kw)

    async def mem_write(self, ch, off, data: bytes, window: int = 12, pkt: int = 8192):
        """Окно как у ПК: не больше window кадров без подтверждения. Такты от первого
        кадра до последнего подтверждения."""
        pk = [(self.next_seq(), off + o, data[o:o + pkt]) for o in range(0, len(data), pkt)]
        pend, i, t0 = {}, 0, self.cycle
        while i < len(pk) or pend:
            while i < len(pk) and len(pend) < window:
                s, o, d = pk[i]
                await self.send(self.w_req(s, ch, o, d))
                pend[s] = o
                i += 1
            r = await self.resp()
            assert r.op == P.OP_WRITE and r.st == P.ST_OK and r.seq in pend, vars(r)
            assert r.off == pend.pop(r.seq)
        return self.cycle - t0

    async def mem_read(self, ch, off, n, fsz: int = 8192, req: int = 1 << 20):
        """Запросы по req байт подряд; данные по OFFSET ответов; такты до последнего кадра."""
        out = bytearray(n)
        seqs, left, t0 = {}, 0, self.cycle
        for o in range(0, n, req):
            s = self.next_seq()
            k = min(req, n - o)
            seqs[s] = off + o
            left += -(-k // fsz)
            await self.send(self.r_req(s, ch, off + o, k, fsz))
        while left:
            r = await self.resp()
            assert r.op == P.OP_READ and r.st == P.ST_OK and r.seq in seqs, vars(r)
            assert r.len == len(r.data) and r.len <= fsz and r.aux == seqs[r.seq]
            out[r.off - off:r.off - off + r.len] = r.data
            left -= 1
        return bytes(out), self.cycle - t0

    async def regs_batch(self, ops, seq=None, **kw) -> Resp:
        s = self.next_seq() if seq is None else seq
        await self.send(self.g_req(s, ops, **kw))
        r = await self.resp()
        assert r.op == P.OP_REG and r.seq == s
        return r

    async def eth_counters(self) -> dict:
        ops = [P.op_read(R_ETH + 0x40 + 4 * i) for i in range(len(EV))]
        r = await self.regs_batch(ops)
        return dict(zip(EV, r.words()))
