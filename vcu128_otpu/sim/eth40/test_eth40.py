"""Тесты cocotb otpu_eth_bridge + eth40_regs (tb_eth40.sv). NC — из ETH40_NC (run.py)."""
from __future__ import annotations

import os
import random
import struct

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge
from scapy.layers.inet import IP, UDP
from scapy.layers.inet6 import IPv6
from scapy.layers.l2 import ARP, Ether
from scapy.packet import Raw

import eth40_tb as T
from eth40_tb import P, TB, R_ETH

NC = int(os.environ.get("ETH40_NC", "2"))


def rnd(rng: random.Random, n: int) -> bytes:
    return rng.randbytes(n)


async def setup(dut, **kw) -> TB:
    tb = TB(dut, NC, **kw)
    await tb.reset()
    return tb


# ------------------------------------------------------------------------------ ARP
@cocotb.test()
async def test_arp(dut):
    """ARP: ответ на свой IP (широковещательный и адресный запрос), чужой IP — тишина."""
    tb = await setup(dut)
    for dst in ("ff:ff:ff:ff:ff:ff", T.BOARD_MAC):
        await tb.send(T.arp_frame(T.BOARD_IP, dst))
        e = Ether(await tb.recv())
        assert e.type == 0x0806 and e.dst == T.PC_MAC and e.src == T.BOARD_MAC
        a = e[ARP]
        assert a.op == 2 and a.hwsrc == T.BOARD_MAC and a.psrc == T.BOARD_IP
        assert a.hwdst == T.PC_MAC and a.pdst == T.PC_IP
    await tb.send(T.arp_frame("192.168.41.77"))
    await tb.send(T.arp_frame(T.BOARD_IP), bad=True)        # ошибка FCS — без ответа
    await tb.quiet(1000)
    c = await tb.eth_counters()
    assert c["arp_req"] == 2 and c["arp_tx"] == 2, c


# ------------------------------------------------------------------------------ память
@cocotb.test()
async def test_write_read_sizes(dut):
    """Запись и чтение разных размеров, выравниваний (границы 4 КиБ) и размеров кадра в
    разные каналы со случайными паузами AXI и TX; сверка с моделью памяти."""
    tb = await setup(dut, axi_pause=0.3, tx_pause=0.2, seed=2)
    rng = random.Random(3)
    cases = [(0, 0, 64), (1, 4096 - 64, 128), (0, 4032, 8192), (1, 0x1234_5000 - 192, 8192),
             (0, 64, 4096), (1, 0x7FFF_E000, 8192), (0, 4096 * 7 + 640, 3008)]
    if NC > 2:
        cases += [(2, 8192, 8192), (3, 0x4000_0040, 1600 // 64 * 64)]
    for ch, off, n in cases:
        d = rnd(rng, n)
        await tb.mem_write(ch, off, d)
        assert tb.ram[ch].read(off, n) == d, (ch, off, n)
        for fsz in (8192, 1024, 64):
            got, _ = await tb.mem_read(ch, off, n, fsz=fsz)
            assert got == d, (ch, off, n, fsz)
    # несколько кадров записи на запрос ПК, чтение одним запросом поверх нескольких
    d = rnd(rng, 40960)
    await tb.mem_write(NC - 1, 0x10_0000 + 192, d)
    got, _ = await tb.mem_read(NC - 1, 0x10_0000 + 192, len(d), fsz=8192, req=24576)
    assert got == d
    # каналы не задевают друг друга
    for ch in range(NC):
        tb.ram[ch].write(0x20_0000, bytes([ch]) * 256)
    for ch in range(NC):
        got, _ = await tb.mem_read(ch, 0x20_0000, 256)
        assert got == bytes([ch]) * 256


@cocotb.test()
async def test_bad_requests(dut):
    """Неверные запросы: ответ ST_BAD, память и регистры не тронуты, разбор не сбит."""
    tb = await setup(dut)
    rng = random.Random(5)
    tb.ram[0].write(0, bytes(16384))
    good = rnd(rng, 128)
    bad = [
        P.pack_req(1, P.OP_WRITE, 0, 32, 64, 0, rnd(rng, 64)),              # смещение не по 64
        P.pack_req(2, P.OP_WRITE, 0, 0, 96, 0, rnd(rng, 96)),               # длина не по 64
        P.pack_req(3, P.OP_WRITE, NC, 0, 64, 0, rnd(rng, 64)),              # канала нет
        P.pack_req(4, P.OP_WRITE, 0, 0x7FFF_FFC0, 128, 0, rnd(rng, 128)),   # за 2 ГиБ
        P.pack_req(5, P.OP_WRITE, 0, 0, 128, 0, rnd(rng, 64)),              # данных меньше LEN
        P.pack_req(6, P.OP_READ, 0, 0, 0, 0),                               # длина 0
        P.pack_req(7, P.OP_READ, 0, 0, 128, 96),                            # кадр не по 64
        P.pack_req(8, P.OP_READ, 0, 0, 128, 16384),                         # кадр > 8 КиБ
        P.pack_req(9, 7, 0, 0, 64, 0),                                      # нет такой OP
        P.pack_req(10, P.OP_REG, 0, 0, 2, 0, P.op_write(0x100, 5) +
                   P.OPREC.pack(0x5 << 28, 0, 0, 0)),                       # код операции 5
        P.pack_req(11, P.OP_REG, 0, 0, 1, 0, P.OPREC.pack(1 << 28 | 0x102, 1, 0, 0)),  # адрес
        P.pack_req(12, P.OP_REG, 0, 0, 3, 0, P.op_read(0)),                 # операций меньше
        P.pack_req(13, P.OP_REG, 0, 0, 0, 0),                               # пустая пачка
    ]
    w0 = tb.axil_writes
    for b in bad:
        await tb.send(T.req_frame(b))
        await tb.send(tb.w_req(100 + len(b), 0, 4096, good))  # верный следом
        r = await tb.resp()
        assert r.st == P.ST_BAD and r.seq == struct.unpack_from("<I", b, 4)[0], vars(r)
        r = await tb.resp()
        assert r.st == P.ST_OK and r.op == P.OP_WRITE
    assert tb.ram[0].read(0, 4096) == bytes(4096) and tb.ram[0].read(4096, 128) == good
    assert tb.axil_writes == w0
    r = await tb.regs_batch([P.op_read(0x100)])
    assert r.words() == [0]
    # ошибка в пачке — номер первой неверной операции
    await tb.send(T.req_frame(bad[9]))
    r = await tb.resp()
    assert r.st == P.ST_BAD and r.aux == 1
    c = await tb.eth_counters()
    assert c["req_bad"] == len(bad) + 1, c


# ------------------------------------------------------------------------------ регистры
@cocotb.test()
async def test_regs(dut):
    """Пачка регистров: запись/чтение модели и eth40_regs; смена IP и порта платы."""
    tb = await setup(dut, axi_pause=0.3)
    ops = [P.op_write(0x100 + 4 * i, 0x1111_0000 + i) for i in range(20)]
    ops += [P.op_read(0x100 + 4 * i) for i in range(20)]
    ops += [P.op_read(R_ETH + 0x00), P.op_read(R_ETH + 0x14), P.op_read(R_ETH + 0x18),
            P.op_read(R_ETH + 0x1C), P.op_read(R_ETH + 0x20), P.op_read(R_ETH + 0x24),
            P.op_read(R_ETH + 0x08)]
    r = await tb.regs_batch(ops)
    assert r.st == P.ST_OK and r.off == len(ops) and r.len == 27
    w = r.words()
    assert w[:20] == [0x1111_0000 + i for i in range(20)]
    assert w[20:] == [0x3034_5445, 0x5E41_0001, 0x0200, 0xC0A8_2902, P.PORT, NC, 1]
    assert tb.regs.read_dword(0x100 + 4 * 7) == 0x1111_0007
    # максимальная пачка: 256 чтений
    r = await tb.regs_batch([P.op_read(0x100 + 4 * (i % 20)) for i in range(256)])
    assert r.len == 256 and r.words()[19] == 0x1111_0013
    # новый IP и порт: ответ на запрос, сменивший IP, приходит уже с нового адреса
    await tb.send(tb.g_req(tb.next_seq(), [P.op_write(R_ETH + 0x1C, 0xC0A8_2905),
                                           P.op_write(R_ETH + 0x20, 0x1234)]))
    b = await tb.recv()                                 # ответ уже с нового IP и порта
    assert Ether(b)[IP].src == "192.168.41.5" and Ether(b)[UDP].sport == 0x1234
    await tb.send(tb.g_req(tb.next_seq(), [P.op_read(0x100)]))       # старый IP — тишина
    await tb.quiet(1500)
    s = tb.next_seq()
    await tb.send(tb.g_req(s, [P.op_read(0x104)], dst_ip="192.168.41.5", dport=0x1234))
    b = await tb.recv()
    e = Ether(b)
    assert e[IP].src == "192.168.41.5" and e[UDP].sport == 0x1234
    pay = bytes(e[UDP].payload)
    assert P.unpack_resp(pay)[0] == s and struct.unpack_from("<I", pay, P.PHDR)[0] == 0x1111_0001
    await tb.send(tb.g_req(tb.next_seq(), [P.op_write(R_ETH + 0x1C, 0xC0A8_2902),
                                           P.op_write(R_ETH + 0x20, P.PORT)],
                           dst_ip="192.168.41.5", dport=0x1234))
    await tb.recv()
    r = await tb.regs_batch([P.op_read(0x108)])
    assert r.words() == [0x1111_0002]


@cocotb.test()
async def test_reg_replay(dut):
    """Повтор пачки с тем же SEQ и источником: тот же ответ, запись не выполняется второй
    раз; другой источник с тем же SEQ — новая пачка; повтор во время выполнения
    отбрасывается (ответ один)."""
    tb = await setup(dut)
    s = tb.next_seq()
    ops = [P.op_write(0x200, 1), P.op_read(0x200), P.op_write(0x204, 2)]
    w0 = tb.axil_writes
    r1 = await tb.regs_batch(ops, seq=s)
    assert tb.axil_writes == w0 + 2
    for _ in range(3):
        r2 = await tb.regs_batch(ops, seq=s)
        assert r2.raw == r1.raw
    assert tb.axil_writes == w0 + 2
    r3 = await tb.regs_batch(ops, seq=s, sport=T.SPORT + 1)     # другой порт ПК
    assert r3.dport == T.SPORT + 1 and tb.axil_writes == w0 + 4
    # дубль во время долгого опроса
    tb.regs.write_dword(0x300, 0)
    s = tb.next_seq()
    req = tb.g_req(s, [P.op_poll(0x300, 1, 1, 100000), P.op_write(0x304, 9)])
    await tb.send(req)
    await ClockCycles(dut.clk, 300)
    await tb.send(req)
    await ClockCycles(dut.clk, 300)
    tb.regs.write_dword(0x300, 3)
    r = await tb.resp()
    assert r.seq == s and r.st == P.ST_OK and r.words() == [3]
    await tb.quiet(1500)
    assert tb.regs.read_dword(0x304) == 9
    await tb.send(req)                                          # после — из кэша
    r = await tb.resp()
    assert r.seq == s and r.words() == [3]
    c = await tb.eth_counters()
    assert c["req_dup"] == 4 and c["req_busy"] == 1, c


@cocotb.test()
async def test_poll(dut):
    """Опрос на плате: ждёт условия; таймаут — ST_TIMEOUT с последним значением и номером
    операции; ошибка AXI-Lite останавливает пачку (ST_AXI)."""
    tb = await setup(dut, axi_pause=0.2)
    tb.regs.write_dword(0x400, 0x10)

    async def later():
        await ClockCycles(dut.clk, 2000)
        tb.regs.write_dword(0x400, 0x13)

    cocotb.start_soon(later())
    t0 = tb.cycle
    r = await tb.regs_batch([P.op_read(0x400), P.op_poll(0x400, 0x3, 0x3, 1 << 20),
                             P.op_read(0x400)])
    assert r.st == P.ST_OK and r.words() == [0x10, 0x13, 0x13]
    assert tb.cycle - t0 >= 2000
    t0 = tb.cycle
    r = await tb.regs_batch([P.op_write(0x404, 7), P.op_poll(0x400, 0x4, 0x4, 3000),
                             P.op_write(0x408, 7)])
    assert r.st == P.ST_TIMEOUT and r.off == 1 and r.words() == [0x13]
    assert 3000 <= tb.cycle - t0 < 6000
    assert tb.regs.read_dword(0x404) == 7 and tb.regs.read_dword(0x408) == 0


# ------------------------------------------------------------------------------ чужие кадры
@cocotb.test()
async def test_foreign_frames(dut):
    """Не IPv4/ARP, PAUSE, чужие MAC/IP/порт, широковещательный UDP, испорченный заголовок
    IP, фрагмент, чужой MAGIC, кадр короче длины IP, плохой кадр MAC (tuser) — молча
    отброшены вперемешку с верными запросами, которые выполняются."""
    tb = await setup(dut)
    rng = random.Random(9)
    d = rnd(rng, 256)
    wq = P.pack_req(77, P.OP_WRITE, 0, 0x8000, 256, 0, d)
    ip_bad = bytearray(T.req_frame(wq))
    ip_bad[24] ^= 0x01                                    # контрольная сумма IP
    frag = bytes(Ether(src=T.PC_MAC, dst=T.BOARD_MAC) /
                 IP(src=T.PC_IP, dst=T.BOARD_IP, flags="MF") / UDP(sport=1, dport=P.PORT) / Raw(wq))
    trunc = T.req_frame(wq)[:-64]                         # IP длиннее кадра
    pause = bytes.fromhex("0180c2000001" + "1cfd087677f0" + "8808" + "0001ffff") + bytes(42)
    foreign = [
        bytes(Ether(src=T.PC_MAC, dst=T.BOARD_MAC) / IPv6() / UDP(dport=P.PORT) / Raw(wq)),
        pause, pause,
        T.req_frame(wq, dst_mac="02:00:5e:41:00:09"),
        T.req_frame(wq, dst_ip="192.168.41.3"),
        T.req_frame(wq, dport=P.PORT + 1),
        T.req_frame(wq, dst_mac="ff:ff:ff:ff:ff:ff", dst_ip="255.255.255.255"),
        bytes(ip_bad), frag, trunc,
        T.req_frame(b"\x00" * 4 + wq[4:]),                # MAGIC
        T.req_frame(b"OT40"),                             # короче заголовка протокола
        bytes(Ether(src=T.PC_MAC, dst=T.BOARD_MAC, type=0x88B5) / Raw(bytes(100))),
    ]
    n_ok = 0
    for i, f in enumerate(foreign):
        await tb.send(f)
        if i % 3 == 0:
            await tb.send(tb.w_req(tb.next_seq(), 1, 64 * i, d))
            n_ok += 1
    await tb.send(T.req_frame(wq), bad=True)              # ошибка FCS: tuser на TLAST
    for _ in range(n_ok):
        r = await tb.resp()
        assert r.op == P.OP_WRITE and r.st == P.ST_OK
    await tb.quiet(2000)
    assert tb.ram[0].read(0x8000, 256) == bytes(256)
    c = await tb.eth_counters()
    assert c["mac_ctl"] == 2 and c["rx_bad"] == 1, c
    assert c["rx_ignore"] == len(foreign) and c["req_write"] == n_ok, c


# ------------------------------------------------------------------------------ сеть
@cocotb.test()
async def test_loss_dup_reorder(dut):
    """Как ПК при потерях: дубли и перестановка кадров записи, повтор запросов чтения
    кусками, повтор пачки регистров — результат верный, запись регистра одна."""
    tb = await setup(dut, axi_pause=0.2, tx_pause=0.1, seed=11)
    rng = random.Random(12)
    d = rnd(rng, 8192 * 6)
    pk = [(tb.next_seq(), 0x4000 + o, d[o:o + 8192]) for o in range(0, len(d), 8192)]
    order = [0, 2, 1, 1, 3, 5, 4, 0, 5]                   # перестановка и дубли
    for i in order:
        s, o, x = pk[i]
        await tb.send(tb.w_req(s, 1, o, x))
    acks = [await tb.resp() for _ in order]
    assert sorted(r.seq for r in acks) == sorted(pk[i][0] for i in order)
    assert all(r.st == P.ST_OK for r in acks)
    assert tb.ram[1].read(0x4000, len(d)) == d
    # чтение: запрос целиком и перезапрос «потерянной» середины
    got, _ = await tb.mem_read(1, 0x4000, len(d), fsz=4096)
    assert got == d
    got2, _ = await tb.mem_read(1, 0x4000 + 8192, 8192, fsz=1024)
    assert got2 == d[8192:16384]
    # пачка регистров: «ответ потерян», ПК повторяет — одно выполнение
    w0 = tb.axil_writes
    s = tb.next_seq()
    req = tb.g_req(s, [P.op_write(0x500, 0xABCD)])
    for _ in range(4):                                  # подряд: пока пачка в работе,
        await tb.send(req)                              # дубли отбрасываются
    rs = [await tb.resp()]
    await ClockCycles(dut.clk, 1500)
    while not tb.sink.empty():
        rs.append(await tb.resp())
    for _ in range(2):                                  # по таймауту ПК — из кэша
        await tb.send(req)
        rs.append(await tb.resp())
    assert all(r.raw == rs[0].raw and r.st == P.ST_OK for r in rs), len(rs)
    assert tb.axil_writes == w0 + 1


@cocotb.test()
async def test_overflow(dut):
    """Кадры записи подряд без окна переполняют FIFO приёма: лишние отброшены целиком
    (счётчик rx_overflow), принятые выполнены; повтор потерянных — память верна."""
    tb = await setup(dut, axi_pause=0.3, seed=13)
    rng = random.Random(14)
    d = rnd(rng, 8192 * 40)
    pk = [(tb.next_seq(), o, d[o:o + 8192]) for o in range(0, len(d), 8192)]
    for s, o, x in pk:
        await tb.send(tb.w_req(s, 0, o, x))
    acked = set()
    try:
        while True:
            r = await tb.resp(cycles=6000)
            assert r.st == P.ST_OK
            acked.add(r.seq)
    except Exception:
        pass
    lost = [p for p in pk if p[0] not in acked]
    tb.log.info("overflow: %d of %d frames dropped", len(lost), len(pk))
    assert lost
    for s, o, x in lost:
        await tb.send(tb.w_req(s, 0, o, x))
        r = await tb.resp()
        assert r.seq == s
    assert tb.ram[0].read(0, len(d)) == d
    c = await tb.eth_counters()
    assert c["rx_overflow"] == len(lost), c


# ------------------------------------------------------------------------------ скорость
@cocotb.test()
async def test_throughput(dut):
    """Сквозная скорость (без пауз AXI и TX): запись окном 12 кадров по 8 КиБ, чтение
    запросами по 128 КиБ (по 2 в полёте у ПК — здесь все сразу). Байт/такт и ГБ/с при
    156,25 МГц; предел AXI — 16 байт/такт (2,5 ГБ/с) на канал."""
    tb = await setup(dut, seed=15)
    rng = random.Random(16)
    n = 256 << 10
    d = rnd(rng, n)
    cyc = await tb.mem_write(0, 0, d, window=12)
    bw = n / cyc
    assert tb.ram[0].read(0, n) == d
    got, cyc_r = await tb.mem_read(0, 0, n, fsz=8192, req=128 << 10)
    br = n / cyc_r
    assert got == d
    # с паузами AXI 20% и TX 10%
    tb.set_pauses(0.2, 0.1)
    cyc_p = await tb.mem_write(1, 0, d, window=12)
    got, cyc_rp = await tb.mem_read(1, 0, n, fsz=8192, req=128 << 10)
    assert got == d
    f = 156.25e6 / 1e9
    msg = (f"throughput NC={NC} {n} B: write {bw:.2f} B/cycle ({bw * f:.2f} GB/s), "
           f"read {br:.2f} B/cycle ({br * f:.2f} GB/s); with pauses: write "
           f"{n / cyc_p:.2f}, read {n / cyc_rp:.2f} B/cycle")
    tb.log.info(msg)
    with open(os.path.join(os.path.dirname(__file__), "out", f"nc{NC}", "throughput.txt"),
              "w") as fh:
        fh.write(msg + "\n")
    assert bw > 12.8 and br > 12.8, msg                   # >= 2 ГБ/с
