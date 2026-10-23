"""cocotb: термоконтроль (vcu128_sysmon_drp + vcu128_thermal в vcu128_platform_regs +
vcu128_ctl_guard). Модель DRP трёх SYSMON — в tb_thermal.sv; регистры — по AXI-Lite.
Проверяются: чтение и пересчёт температур и напряжений, R_TEMP-код, пороги с гистерезисом,
защёлки и их сброс, максимумы, действие (HOLD, запись CTRL = 0, гашение calib), возврат
(RESUME, AUTO_RESUME, ACT_EN = 0), HBM и CATTRIP, таймаут DRP, арбитраж guard."""
from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer
from cocotbext.axi import AxiLiteBus, AxiLiteMaster, AxiLiteRam
from cocotbext.axi.constants import AxiResp

P = 0x40000
TH_INFO, TH_CTRL, TH_STATUS, TH_FPGA, TH_HBM = 0x20, 0x24, 0x28, 0x2C, 0x30
TH_EVENTS, TH_RAW, TH_ABORTS, T_SLR, T_HBM, V_SLR = 0x34, 0x38, 0x3C, 0x40, 0x4C, 0x50
STATUS = 0x04
ACT_EN, AUTO, CATTRIP_ACT, FORCE = 1, 2, 4, 8
RESUME, CLR_FLAGS, CLR_MAX = 1 << 8, 1 << 9, 1 << 10
S_WARN, S_ALARM, S_CATTRIP, S_HOLD = 1, 2, 4, 8
S_WARN_L, S_ALARM_L, S_CATTRIP_L, S_HOLD_L, S_COOL, S_VALID, S_ERR = (
    1 << 4, 1 << 5, 1 << 6, 1 << 7, 1 << 8, 1 << 9, 1 << 10)


def code12(t: float) -> int:
    return round((t + 280.2308787) * 4096 / 509.3140064)


def temp_c(c12: int) -> float:
    return c12 * 509.3140064 / 4096 - 280.2308787


def s16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


class TB:
    def __init__(self, dut):
        self.dut = dut
        cocotb.start_soon(Clock(dut.clk, 5, unit="ns").start())
        cocotb.start_soon(Clock(dut.clk100, 10, unit="ns").start())
        self.p = AxiLiteMaster(AxiLiteBus.from_prefix(dut, "p"), dut.clk, dut.rst)
        self.c = AxiLiteMaster(AxiLiteBus.from_prefix(dut, "c"), dut.clk, dut.rst)
        self.ram = AxiLiteRam(AxiLiteBus.from_prefix(dut, "k"), dut.clk, dut.rst, size=2 ** 12)

    async def reset(self, t=(40.0, 41.0, 42.0)):
        d = self.dut
        d.rst.value = 1
        d.rst100.value = 1
        self.set_fpga(*t)
        d.sm_vint.value = 0x4400       # 0.85 V x 1024 / 3 = 290 -> code 0x122 << 6
        d.sm_vaux.value = 0x9980
        d.sm_vbram.value = 0x4480
        d.sm_dead.value = 0
        d.sm_lat.value = 3
        d.sm_ot.value = 0
        d.hbm_temp0.value = 35
        d.hbm_temp1.value = 36
        d.hbm_calib.value = 3
        d.hbm_cattrip.value = 0
        await ClockCycles(d.clk, 10)
        d.rst.value = 0
        d.rst100.value = 0
        await self.rounds(2)

    def set_fpga(self, t0, t1, t2):
        self.dut.sm_t0.value = code12(t0) << 4
        self.dut.sm_t1.value = code12(t1) << 4
        self.dut.sm_t2.value = code12(t2) << 4

    async def rounds(self, n=1):
        """n full rounds of the DRP reader seen in core_clk (snapshot toggles)."""
        for _ in range(n):
            t = int(self.dut.u_drp.snap_tog.value)
            while int(self.dut.u_drp.snap_tog.value) == t:
                await RisingEdge(self.dut.clk100)
        await ClockCycles(self.dut.clk, 12)

    async def rd(self, a):
        return int.from_bytes((await self.p.read(P + a, 4)).data, "little")

    async def wr(self, a, v):
        await self.p.write(P + a, int(v).to_bytes(4, "little"))

    async def st(self):
        return await self.rd(TH_STATUS)

    def ctrl(self):
        return int.from_bytes(self.ram.read(0x8, 4), "little")


@cocotb.test()
async def test_readout(dut):
    """Температуры SLR (1/16 °C), напряжения, R_TEMP-код (самый горячий SLR), INFO."""
    tb = TB(dut)
    await tb.reset((40.0, 55.5, 47.25))
    info = await tb.rd(TH_INFO)
    assert info & 0xF == 3 and (info >> 4) & 0xF == 0 and (info >> 8) & 0xFF == 1, hex(info)
    assert info >> 16 & 1
    for s, t in enumerate((40.0, 55.5, 47.25)):
        v = await tb.rd(T_SLR + 4 * s)
        cur, mx = s16(v & 0xFFFF) / 16, s16(v >> 16) / 16
        ref = temp_c(code12(t))
        assert abs(cur - ref) <= 1 / 16, (s, cur, ref)
        assert cur == mx
        vv = await tb.rd(V_SLR + 4 * s)
        assert vv & 0x3FF == (0x4400 >> 6) + s
        assert (vv >> 10) & 0x3FF == (0x9980 >> 6) + s
        assert (vv >> 20) & 0x3FF == (0x4480 >> 6) + s
    raw = await tb.rd(TH_RAW)
    assert raw & 0xFFF == code12(55.5), (hex(raw), hex(code12(55.5)))
    assert int(dut.th_temp_code.value) == code12(55.5)
    st = await tb.st()
    assert st & S_VALID and st & S_COOL and not st & (S_WARN | S_ALARM | S_HOLD | S_ERR), hex(st)
    h = await tb.rd(T_HBM)
    assert h & 0xFF == 35 and (h >> 8) & 0xFF == 36 and (h >> 16) & 0xFF == 35 and h >> 24 == 36
    assert await tb.rd(TH_FPGA) == (10 << 16) | (100 << 8) | 85
    assert await tb.rd(TH_HBM) == (5 << 16) | (95 << 8) | 85
    assert await tb.rd(TH_CTRL) == ACT_EN | CATTRIP_ACT
    # the formula over the whole code range against the hardware's integer form
    for c in range(0, 4096, 7):
        q = ((c * 32596 + 8192) >> 14) - 4484
        assert abs(q / 16 - temp_c(c)) <= 1 / 16 + 1e-9, c
    # undefined addresses: SLVERR
    r = await tb.p.read(P + 0x60, 4)
    assert r.resp == AxiResp.SLVERR
    w = await tb.p.write(P + 0x60, b"\0\0\0\0")
    assert w.resp == AxiResp.SLVERR


@cocotb.test()
async def test_hysteresis_and_latches(dut):
    """WARN с гистерезисом, защёлки, сброс записью, максимум и его сброс, STATUS бит 19/20."""
    tb = TB(dut)
    await tb.reset()
    await tb.wr(TH_CTRL, 0)                      # no action: flags only
    tb.set_fpga(40, 86, 40)
    await tb.rounds(2)
    st = await tb.st()
    assert st & S_WARN and st & S_WARN_L and (st >> 16) & 0x1F == 0b00010, hex(st)
    assert (await tb.rd(STATUS)) >> 19 & 1
    tb.set_fpga(40, 80, 40)                      # below 85 but above 85 - 10: stays
    await tb.rounds(2)
    assert (await tb.st()) & S_WARN
    tb.set_fpga(40, 74, 40)                      # below 75: falls, sticky stays
    await tb.rounds(2)
    st = await tb.st()
    assert not st & S_WARN and st & S_WARN_L, hex(st)
    ev = await tb.rd(TH_EVENTS)
    assert ev >> 16 == 1 and ev & 0xFFFF == 0, hex(ev)
    await tb.wr(TH_CTRL, CLR_FLAGS)
    assert not (await tb.st()) & S_WARN_L
    # the maximum 86 C survives and clears to the current value
    v = await tb.rd(T_SLR + 4)
    assert abs(s16(v >> 16) / 16 - 86) < 0.2 and abs(s16(v & 0xFFFF) / 16 - 74) < 0.2
    await tb.wr(TH_CTRL, CLR_MAX)
    await ClockCycles(dut.clk, 4)
    v = await tb.rd(T_SLR + 4)
    assert v >> 16 == v & 0xFFFF
    # alarm without the action: ALARM and sticky, no HOLD; STATUS bit 20
    tb.set_fpga(40, 40, 101)
    await tb.rounds(2)
    st = await tb.st()
    assert st & S_ALARM and st & S_ALARM_L and not st & S_HOLD and (st >> 24) & 0x1F == 0b00100
    assert not st & S_COOL
    assert (await tb.rd(STATUS)) >> 20 & 1
    assert int(dut.th_hold.value) == 0
    # thresholds: lower warn to 30 -> every sensor warns (HBM limits separate: 85)
    await tb.wr(TH_FPGA, (2 << 16) | (120 << 8) | 30)
    await tb.rounds(1)
    st = await tb.st()
    assert (st >> 16) & 0x1F == 0b00111 and not st & S_ALARM, hex(st)


@cocotb.test()
async def test_hold_action(dut):
    """Авария: HOLD, guard пишет CTRL = 0, calib гасится; возврат только после охлаждения
    ниже A − H и RESUME; повторная авария — снова запись."""
    tb = TB(dut)
    await tb.reset()
    tb.ram.write(0x8, (1).to_bytes(4, "little"))     # RUN = 1
    tb.set_fpga(40, 100.5, 40)
    await tb.rounds(2)
    st = await tb.st()
    assert st & S_HOLD and st & S_HOLD_L and st & S_ALARM, hex(st)
    assert tb.ctrl() == 0
    assert await tb.rd(TH_ABORTS) == 1
    assert int(dut.calib_gated.value) == 0
    assert (await tb.rd(STATUS)) >> 21 & 1
    assert (await tb.rd(TH_EVENTS)) & 0xFFFF == 1
    # host writes RUN again: the slave gets it (the guard only delays), calib keeps it off
    await tb.c.write(0x8, (1).to_bytes(4, "little"))
    assert tb.ctrl() == 1
    tb.ram.write(0x8, (0).to_bytes(4, "little"))
    # resume while hot: ignored
    await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT | RESUME)
    await ClockCycles(dut.clk, 4)
    assert (await tb.st()) & S_HOLD
    tb.set_fpga(40, 92, 40)                          # below 100, not below 90
    await tb.rounds(2)
    await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT | RESUME)
    await ClockCycles(dut.clk, 4)
    st = await tb.st()
    assert st & S_HOLD and st & S_ALARM and not st & S_COOL, hex(st)
    tb.set_fpga(40, 89, 40)                          # cooled: no auto resume, still held
    await tb.rounds(2)
    st = await tb.st()
    assert st & S_HOLD and st & S_COOL and not st & S_ALARM, hex(st)
    await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT | RESUME)
    await ClockCycles(dut.clk, 4)
    st = await tb.st()
    assert not st & S_HOLD and st & S_HOLD_L, hex(st)
    assert int(dut.calib_gated.value) == 1
    # again
    tb.ram.write(0x8, (1).to_bytes(4, "little"))
    tb.set_fpga(110, 40, 40)
    await tb.rounds(2)
    assert (await tb.st()) & S_HOLD
    assert tb.ctrl() == 0 and await tb.rd(TH_ABORTS) == 2
    # ACT_EN = 0 releases at once (the host takes over), the alarm stays
    await tb.wr(TH_CTRL, CATTRIP_ACT)
    await ClockCycles(dut.clk, 4)
    st = await tb.st()
    assert not st & S_HOLD and st & S_ALARM, hex(st)


@cocotb.test()
async def test_auto_resume_and_force(dut):
    """AUTO_RESUME: возврат сам после охлаждения; FORCE_HOLD — проверка действия хостом."""
    tb = TB(dut)
    await tb.reset()
    await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT | AUTO)
    tb.set_fpga(40, 40, 105)
    await tb.rounds(2)
    assert (await tb.st()) & S_HOLD
    tb.set_fpga(40, 40, 91)
    await tb.rounds(2)
    assert (await tb.st()) & S_HOLD
    tb.set_fpga(40, 40, 89)
    await tb.rounds(2)
    assert not (await tb.st()) & S_HOLD
    tb.ram.write(0x8, (1).to_bytes(4, "little"))
    await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT | AUTO | FORCE)
    await ClockCycles(dut.clk, 20)
    assert (await tb.st()) & S_HOLD and tb.ctrl() == 0
    await tb.rounds(1)
    assert (await tb.st()) & S_HOLD                  # forced: held while set
    await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT | AUTO)
    await ClockCycles(dut.clk, 4)
    assert not (await tb.st()) & S_HOLD
    assert await tb.rd(TH_ABORTS) == 2


@cocotb.test()
async def test_hbm(dut):
    """HBM: пороги HBM_LIM, фильтр двух одинаковых отсчётов, до калибровки не учитывается,
    CATTRIP — HOLD при CATTRIP_ACT и без него."""
    tb = TB(dut)
    await tb.reset()
    dut.hbm_temp1.value = 96
    await ClockCycles(dut.clk, 6)
    st = await tb.st()
    assert st & S_HOLD and (st >> 24) & 0x1F == 0b10000, hex(st)
    h = await tb.rd(T_HBM)
    assert (h >> 8) & 0xFF == 96 and h >> 24 == 96
    dut.hbm_temp1.value = 50
    await ClockCycles(dut.clk, 6)
    await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT | RESUME)
    await ClockCycles(dut.clk, 4)
    assert not (await tb.st()) & S_HOLD
    # a one-cycle glitch (bits caught mid-change) does not count
    dut.hbm_temp0.value = 127
    await RisingEdge(dut.clk)
    dut.hbm_temp0.value = 35
    await ClockCycles(dut.clk, 8)
    st = await tb.st()
    assert not (st >> 24) & 0b01000 and not (st >> 16) & 0b01000, hex(st)
    # before calibration: ignored
    dut.hbm_calib.value = 1
    dut.hbm_temp0.value = 120
    await ClockCycles(dut.clk, 8)
    assert not (await tb.st()) & S_ALARM
    dut.hbm_temp0.value = 35
    dut.hbm_calib.value = 3
    # CATTRIP with CATTRIP_ACT = 0: flag only
    await tb.wr(TH_CTRL, ACT_EN)
    dut.hbm_cattrip.value = 2
    await ClockCycles(dut.clk, 6)
    st = await tb.st()
    assert st & S_CATTRIP and st & S_CATTRIP_L and not st & S_HOLD, hex(st)
    await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT)
    await ClockCycles(dut.clk, 4)
    st = await tb.st()
    assert st & S_HOLD and not st & S_COOL, hex(st)
    assert (await tb.rd(STATUS)) >> 3 & 3 == 2           # STATUS [4:3] CATTRIP as before
    dut.hbm_cattrip.value = 0
    await ClockCycles(dut.clk, 6)
    await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT | RESUME)
    await ClockCycles(dut.clk, 4)
    st = await tb.st()
    assert not st & S_HOLD and st & S_CATTRIP_L and not st & S_CATTRIP, hex(st)


@cocotb.test()
async def test_drp_timeout(dut):
    """SLR без ответа DRP: таймаут, флаг ошибки, остальные SLR читаются; латентность DRP
    (арбитраж JTAG) не мешает."""
    tb = TB(dut)
    dut.sm_dead.value = 0
    await tb.reset((40, 41, 42))
    dut.sm_dead.value = 0b100
    dut.sm_lat.value = 50
    tb.set_fpga(45, 46, 99)
    await tb.rounds(2)
    st = await tb.st()
    assert st & S_ERR and st & S_VALID, hex(st)  # SLR2 answered before: still valid
    v = await tb.rd(T_SLR)
    assert abs(s16(v & 0xFFFF) / 16 - 45) < 0.2
    v = await tb.rd(T_SLR + 8)
    assert abs(s16(v & 0xFFFF) / 16 - 42) < 0.2  # the last value it gave
    dut.sm_dead.value = 0
    await tb.rounds(2)
    await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT | CLR_FLAGS)
    await tb.rounds(1)
    st = await tb.st()
    assert not st & S_ERR, hex(st)


@cocotb.test()
async def test_never_valid(dut):
    """SLR, не ответивший ни разу: не участвует, TH_STATUS[9] = 0, максимум 0x8000."""
    tb = TB(dut)
    d = dut
    d.rst.value = 1
    d.rst100.value = 1
    tb.set_fpga(40, 41, 130)
    d.sm_vint.value = d.sm_vaux.value = d.sm_vbram.value = 0
    d.sm_dead.value = 0b100
    d.sm_lat.value = 1
    d.sm_ot.value = 0
    d.hbm_temp0.value = d.hbm_temp1.value = 30
    d.hbm_calib.value = 3
    d.hbm_cattrip.value = 0
    await ClockCycles(d.clk, 10)
    d.rst.value = 0
    d.rst100.value = 0
    await tb.rounds(2)
    st = await tb.st()
    assert not st & S_VALID and not st & S_ALARM and st & S_ERR, hex(st)
    v = await tb.rd(T_SLR + 8)
    assert v >> 16 == 0x8000
    assert (await tb.rd(TH_RAW)) & 0xFFF == code12(41)
    d.sm_ot.value = 0b101
    await ClockCycles(d.clk, 4)
    assert ((await tb.rd(TH_RAW)) >> 16) & 7 == 0b101


@cocotb.test()
async def test_guard_traffic(dut):
    """guard под нагрузкой: поток чтений/записей ведущего не теряется и не портится, запись
    CTRL = 0 вклинивается между транзакциями."""
    tb = TB(dut)
    await tb.reset()
    rng = random.Random(7)
    ref = {}
    stop = False

    async def traffic():
        n = 0
        while not stop:
            a = 0x100 + 4 * rng.randrange(64)
            if rng.random() < 0.5:
                v = rng.getrandbits(32)
                await tb.c.write(a, v.to_bytes(4, "little"))
                ref[a] = v
            elif a in ref:
                r = int.from_bytes((await tb.c.read(a, 4)).data, "little")
                assert r == ref[a], (hex(a), hex(r), hex(ref[a]))
            n += 1
        return n

    t = cocotb.start_soon(traffic())
    for k in range(6):
        tb.ram.write(0x8, (5).to_bytes(4, "little"))
        await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT | FORCE)
        await ClockCycles(dut.clk, 40)
        assert tb.ctrl() == 0, k
        await tb.wr(TH_CTRL, ACT_EN | CATTRIP_ACT | RESUME)
        await ClockCycles(dut.clk, rng.randrange(5, 30))
    stop = True
    n = await t
    assert n > 50
    assert await tb.rd(TH_ABORTS) == 6
    for a, v in ref.items():
        assert int.from_bytes(tb.ram.read(a, 4), "little") == v
