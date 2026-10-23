"""cocotb-тесты связки upstream otpu_mem_ch + otpu_hbm_port + модель HBM (hbm_model).

Ускоритель (n_*, clk): модель мастера с эталоном -- записи (полные и частичные: RMW в
otpu_mem_ch) и чтения, данные записи в порядке команд записи, до или после команды; проверка
данных чтения, n_wdone, n_err. XDMA (x_*, xclk, AXI4 128 бит): cocotbext-axi AxiMaster, записи
и чтения произвольной длины и выравнивания с проверкой. Такты clk, xclk, uclk -- разные.
Окно ускорителя -- beat с битом 24 = 0, окно XDMA -- с битом 24 = 1 (байтовый адрес 0x40000000+);
в конце каждая сторона читает окно другой. Итоги -- out/<тег запуска>__<тест>.json.
"""

import json
import os
import random
from collections import deque
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer
from cocotb.utils import get_sim_time
from cocotbext.axi import AxiBus, AxiMaster

from hbm_model import PCB, Cfg, HbmModel, default_beat, hbm_map

N = int(os.environ.get("HBM_N", "20000"))
SEED = int(os.environ.get("SEED", "1"))
OUT = Path(os.environ.get("HBM_OUT", "."))
TAG = os.environ.get("HBM_TAG", "sys")
CLK_PS = int(os.environ.get("SYS_CLK_PS", "10000"))     # ускоритель: 100 МГц
XCLK_PS = 6400                                           # 156,25 МГц
UCLK_PS = int(os.environ.get("SYS_UCLK_PS", "4444"))     # 225 МГц
NS = int(os.environ.get("HBM_NS", "1"))                  # AXI-портов на native-порт
NA = 2 * NS
FULL = (1 << 64) - 1
XBASE = 1 << (27 + PCB)                                  # окно XDMA: верхняя половина канала


class Ref:
    """Эталон канала по beat (оба мастера; окна не пересекаются до фазы перекрёстной проверки)."""

    def __init__(self):
        self.m = {}

    def get(self, beat):
        v = self.m.get(beat)
        return default_beat(hbm_map(beat)) if v is None else v

    def put(self, beat, data, mask):
        if mask == FULL:
            self.m[beat] = data
            return
        old = self.get(beat)
        for k in range(64):
            if (mask >> k) & 1:
                m = 0xFF << (8 * k)
                old = (old & ~m) | (data & m)
        self.m[beat] = old

    def read_bytes(self, addr, n):
        out = bytearray()
        a = addr
        while a < addr + n:
            beat = (a >> 6) & ((1 << 25) - 1)
            v = self.get(beat).to_bytes(64, "little")
            lo = a & 63
            k = min(64 - lo, addr + n - a)
            out += v[lo:lo + k]
            a += k
        return bytes(out)

    def write_bytes(self, addr, data):
        a, i = addr, 0
        while i < len(data):
            beat = (a >> 6) & ((1 << 25) - 1)
            lo = a & 63
            k = min(64 - lo, len(data) - i)
            d = int.from_bytes(bytes(lo) + data[i:i + k] + bytes(64 - lo - k), "little")
            self.put(beat, d, ((1 << k) - 1) << lo)
            a += k
            i += k


class NMaster:
    """Мастер ускорителя (otpu_native_dram): команды по одной на beat, данные записи -- отдельным
    потоком в порядке команд записи, данные чтения -- в порядке команд, без обратного давления."""

    def __init__(self, dut, rng, ref, p_cvalid=0.8, p_wvalid=0.8):
        self.dut, self.rng, self.ref = dut, rng, ref
        self.p_cvalid, self.p_wvalid = p_cvalid, p_wvalid
        self.gen = None
        self.pend = deque()
        self.wdq = deque()
        self.cv = self.wv = 0
        self.exp = deque()
        self.n_rd = self.n_wr = self.n_rdata = 0
        self.wdone = 0
        self.errors = []
        self.t_first = self.t_last = None
        self.t_first_r = None                 # первые данные чтения (установившийся поток)

    def err(self, msg):
        if len(self.errors) < 30:
            self.errors.append(msg)

    def start(self, gen):
        self.gen = gen

    def done(self):
        return self.gen is None and not self.pend and not self.wdq and not self.exp

    def fill(self):
        while self.gen is not None and len(self.pend) < 4:
            try:
                c = next(self.gen)
            except StopIteration:
                self.gen = None
                break
            self.pend.append(c)
            if c[0]:
                self.wdq.append((c[2], c[3]))

    def drive(self):
        d = self.dut
        self.fill()
        if not self.cv and self.pend and self.rng.random() < self.p_cvalid:
            self.cv = 1
        if not self.wv and self.wdq and self.rng.random() < self.p_wvalid:
            self.wv = 1
        d.n_cvalid.value = self.cv
        if self.cv:
            d.n_cwe.value = self.pend[0][0]
            d.n_caddr.value = self.pend[0][1]
        d.n_wvalid.value = self.wv
        if self.wv:
            d.n_wdata.value = self.wdq[0][0]
            d.n_wmask.value = self.wdq[0][1]

    def sample(self):
        d = self.dut
        now = get_sim_time("ns")
        if int(d.n_err.value):
            self.err(f"{now} нс: n_err")
        if self.cv and int(d.n_cready.value):
            we, beat, data, mask = self.pend.popleft()
            self.cv = 0
            if self.t_first is None:
                self.t_first = now
            if we:
                self.ref.put(beat, data, mask)
                self.n_wr += 1
            else:
                self.exp.append((beat, self.ref.get(beat)))
                self.n_rd += 1
        if self.wv and int(d.n_wready.value):
            self.wdq.popleft()
            self.wv = 0
        if int(d.n_rvalid.value):
            if not self.exp:
                self.err(f"{now} нс: n_rvalid без команды")
            else:
                beat, e = self.exp.popleft()
                got = d.n_rdata.value.to_unsigned()
                self.n_rdata += 1
                if self.t_first_r is None:
                    self.t_first_r = now
                self.t_last = now
                if got != e:
                    self.err(f"{now} нс: n: beat {beat:#x}: прочитано {got:#x}, ожидалось {e:#x}")
        wd = d.n_wdone.value.to_unsigned()
        if ((wd - self.wdone) & 0xFFFF) >= 0x8000:
            self.err(f"{now} нс: n_wdone назад {self.wdone} -> {wd}")
        self.wdone = wd
        if wd != self.n_wr & 0xFFFF and ((self.n_wr - wd) & 0xFFFF) > 0x8000:
            self.err(f"{now} нс: n_wdone {wd} больше принятых записей {self.n_wr}")


class Env:
    def __init__(self, dut, cfg, rng):
        self.dut, self.rng = dut, rng
        self.ref = Ref()
        self.model = HbmModel(dut, rng, cfg, nports=NA)
        self.n = NMaster(dut, rng, self.ref)
        self.cdiag = {"rv2": 0}
        self.t_lastb = self.t_firstb = None
        self.stop = False

    async def uloop(self):
        d, m = self.dut, self.model
        now = 0
        while not self.stop:
            await RisingEdge(d.uclk)
            now += 1
            m.drive()
            await ReadOnly()
            m.sample_step(now)
            for pm in m.ports:
                if pm.bvalid:
                    self.t_lastb = get_sim_time("ns")
                    if self.t_firstb is None:
                        self.t_firstb = self.t_lastb
            if d.c_rdata_valid.value.to_unsigned() == 3:
                self.cdiag["rv2"] += 1

    async def nloop(self):
        d = self.dut
        while not self.stop:
            await RisingEdge(d.clk)
            self.n.drive()
            await ReadOnly()
            self.n.sample()


async def setup(dut, cfg, seed):
    rng = random.Random(seed)
    cocotb.start_soon(Clock(dut.clk, CLK_PS, unit="ps").start())
    cocotb.start_soon(Clock(dut.xclk, XCLK_PS, unit="ps").start())
    cocotb.start_soon(Clock(dut.uclk, UCLK_PS, unit="ps").start())
    for s in ("n_cvalid", "n_cwe", "n_caddr", "n_wvalid", "n_wdata", "n_wmask"):
        getattr(dut, s).value = 0
    dut.rst.value = 1
    dut.xrst.value = 1
    dut.urst.value = 1
    env = Env(dut, cfg, rng)
    axi = AxiMaster(AxiBus.from_prefix(dut, "x"), dut.xclk, dut.xrst)
    await Timer(300, unit="ns")
    await RisingEdge(dut.uclk)
    dut.urst.value = 0
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.xclk)
    dut.xrst.value = 0
    cocotb.start_soon(env.uloop())
    cocotb.start_soon(env.nloop())
    for _ in range(100):
        await RisingEdge(dut.clk)
    return env, axi


async def wait_n(env, limit_ns):
    t0 = get_sim_time("ns")
    while not env.n.done() or env.n.wdone != env.n.n_wr & 0xFFFF:
        await RisingEdge(env.dut.clk)
        if env.n.errors or env.model.errors or get_sim_time("ns") - t0 > limit_ns:
            break


async def wait_idle(env):
    for _ in range(100000):
        await RisingEdge(env.dut.uclk)
        if not env.model.busy() and env.dut.st_busy.value.to_unsigned() == 0:
            break


def n_rand(rng, n, hot):
    """Команды ускорителя в его окне: горячие beat, окно 8192 beat, частичные записи (RMW)."""
    for _ in range(n):
        r = rng.random()
        beat = rng.choice(hot) if r < 0.4 else rng.randrange(8192)
        if rng.random() < 0.5:
            mask = FULL if rng.random() >= 0.1 else rng.getrandbits(64)
            yield 1, beat, rng.getrandbits(512), mask
        else:
            yield 0, beat, 0, 0


def n_reads(beats):
    for b in beats:
        yield 0, b, 0, 0


async def x_worker(axi, ref, rng, base, size, ops, stats, errors):
    for _ in range(ops):
        if errors:
            return
        ln = rng.choice([rng.randint(1, 64), rng.randint(1, 600), rng.randint(64, 4096)])
        off = rng.randrange(size - ln)
        addr = base + off
        if rng.random() < 0.5:
            data = rng.randbytes(ln)
            await axi.write(addr, data)
            ref.write_bytes(addr, data)
            stats["xw"] += 1
            stats["xw_bytes"] += ln
        else:
            exp = ref.read_bytes(addr, ln)
            got = (await axi.read(addr, ln)).data
            stats["xr"] += 1
            stats["xr_bytes"] += ln
            if bytes(got) != exp:
                errors.append(f"XDMA чтение {addr:#x}+{ln}: не совпало")


def status(dut):
    def arr(sig, w):
        v = sig.value.to_unsigned()
        return [(v >> (w * a)) & ((1 << w) - 1) for a in range(NA)]
    return dict(rcmd=arr(dut.st_rcmd, 32), wcmd=arr(dut.st_wcmd, 32), dep=arr(dut.st_dep, 32),
                rout=arr(dut.st_rout, 7), wout=arr(dut.st_wout, 7),
                busy=dut.st_busy.value.to_unsigned(), err_cnt=dut.st_err_cnt.value.to_unsigned(),
                err=int(dut.st_err.value), perr=int(dut.st_perr.value), n_err=int(dut.n_err.value))


def finish(env, name, extra, errors=()):
    st = status(env.dut)
    errs = list(errors) + env.n.errors + env.model.errors
    if env.cdiag["rv2"]:
        errs.append(f"c_rdata_valid обоих портов: {env.cdiag['rv2']} раз")
    if st["n_err"] or st["err"] or st["perr"] or st["busy"]:
        errs.append(f"состояние в конце: {st}")
    if sum(pm.w_before_aw for pm in env.model.ports):
        errs.append("W раньше AW")
    bad = 0
    for beat, v in env.ref.m.items():
        a = hbm_map(beat)
        if (env.model.mem.read(a) | (env.model.mem.read(a + 32) << 256)) != v:
            bad += 1
    if bad:
        errs.append(f"итоговая память HBM: {bad} beat не совпали с эталоном")
    res = dict(test=name, seed=SEED, ns=NS, clk_ps=CLK_PS, xclk_ps=XCLK_PS, uclk_ps=UCLK_PS,
               n_reads=env.n.n_rd, n_writes=env.n.n_wr, n_rdata=env.n.n_rdata, n_wdone=env.n.wdone,
               hbm_ar=[pm.n_ar for pm in env.model.ports], hbm_aw=[pm.n_aw for pm in env.model.ports],
               overtakes=sum(pm.overtakes for pm in env.model.ports),
               beats_checked=len(env.ref.m), status=st, **extra, errors=errs[:20])
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{TAG}__{name}.json").write_text(json.dumps(res, indent=1, ensure_ascii=False))
    env.dut._log.info(json.dumps(res, ensure_ascii=False))
    assert not errs, "\n".join(errs[:20])
    return res


@cocotb.test()
async def random_both(dut):
    """Ускоритель и XDMA одновременно, случайная модель HBM; затем перекрёстное чтение окон."""
    env, axi = await setup(dut, Cfg(stall=(0.002, 5, 60)), SEED)
    rng = env.rng
    hot = [rng.randrange(XBASE >> 6) for _ in range(8)] + [rng.randrange(512) for _ in range(8)]
    env.n.start(n_rand(rng, N, hot))
    stats = dict(xw=0, xr=0, xw_bytes=0, xr_bytes=0)
    xerr = []
    nx = max(4, N // 200)
    workers = [cocotb.start_soon(x_worker(axi, env.ref, random.Random(SEED * 100 + i),
                                          XBASE + i * 0x10000, 0x10000, nx, stats, xerr))
               for i in range(4)]
    await wait_n(env, 400 * N * CLK_PS / 1000 + 1e6)
    for w in workers:
        await w
    # перекрёстно: XDMA читает окно ускорителя, ускоритель -- окно XDMA
    nbeats = [b for b in env.ref.m if b < (1 << 24)]
    xbeats = [b for b in env.ref.m if b >= (1 << 24)]
    for b in rng.sample(nbeats, min(200, len(nbeats))):
        got = (await axi.read(b << 6, 64)).data
        if bytes(got) != env.ref.read_bytes(b << 6, 64):
            xerr.append(f"XDMA: beat ускорителя {b:#x} не совпал")
    env.n.start(n_reads(rng.sample(xbeats, min(2000, len(xbeats)))))
    await wait_n(env, 1e7)
    await wait_idle(env)
    env.stop = True
    if not env.n.done():
        xerr.append("ускоритель не завершил команды")
    finish(env, "random_both", dict(x=stats), xerr)


HBM_LAT = int(os.environ.get("SYS_HBM_LAT", "40"))      # задержка модели HBM в потоках, такты uclk


async def n_stream(dut, kind, nb):
    env, axi = await setup(dut, Cfg.fast(HBM_LAT), SEED)
    env.n.p_cvalid = env.n.p_wvalid = 1.0
    rng = env.rng
    if kind == "r":
        gen = n_reads(range(nb))
    else:
        gen = ((1, b, rng.getrandbits(512), FULL) for b in range(nb))
    env.n.start(gen)
    await wait_n(env, 1e8)
    await wait_idle(env)
    env.stop = True
    t_end = env.n.t_last if kind == "r" else env.t_lastb
    span_ns = t_end - env.n.t_first
    nbytes = nb * 64
    ucyc = span_ns * 1000 / UCLK_PS
    # установившийся поток: от первого до последнего beat ответа (данные чтения / B), без
    # задержки первого обращения; B -- по одному на beat (два порта HBM могут дать B в одном
    # такте, поэтому для записи это оценка снизу точнее, чем по команде)
    t0_ss = env.n.t_first_r if kind == "r" else env.t_firstb
    ss_ns = t_end - t0_ss
    gbps_ss = (nb - 1) * 64 / ss_ns if ss_ns > 0 else 0.0
    res = dict(stream=kind, hbm_lat=HBM_LAT, beats=nb, span_ns=round(span_ns, 1), bytes=nbytes,
               bytes_per_uclk=round(nbytes / ucyc, 2), gbps=round(nbytes / span_ns, 2),
               bytes_per_clk=round(nbytes / (span_ns * 1000 / CLK_PS), 2),
               gbps_ss=round(gbps_ss, 2), bytes_per_clk_ss=round(gbps_ss * CLK_PS / 1000, 2),
               core_peak_gbps=round(64 / (CLK_PS / 1000), 2))
    dut._log.info(f"поток ускорителя {kind}: {res}")
    finish(env, f"stream_n_{kind}_clk{CLK_PS}", res)


@cocotb.test()
async def stream_n_read(dut):
    await n_stream(dut, "r", 8192)


@cocotb.test()
async def stream_n_write(dut):
    await n_stream(dut, "w", 8192)


@cocotb.test()
async def stream_x(dut):
    """XDMA: запись 256 КиБ пакетами по 4 КиБ, затем чтение (4 параллельных потока)."""
    env, axi = await setup(dut, Cfg.fast(40), SEED)
    rng = env.rng
    total, blk = 256 * 1024, 4096
    data = rng.randbytes(total)
    res = {}
    for kind in ("w", "r"):
        t0 = get_sim_time("ns")
        errs = []

        async def wk(i):
            for a in range(i * blk, total, 4 * blk):
                if kind == "w":
                    await axi.write(XBASE + a, data[a:a + blk])
                else:
                    got = (await axi.read(XBASE + a, blk)).data
                    if bytes(got) != data[a:a + blk]:
                        errs.append(f"XDMA поток: {a:#x}")
        ws = [cocotb.start_soon(wk(i)) for i in range(4)]
        for w in ws:
            await w
        span = get_sim_time("ns") - t0
        if kind == "w":
            env.ref.write_bytes(XBASE, data)
        res[kind] = dict(bytes=total, span_ns=round(span, 1), gbps=round(total / span, 2),
                         bytes_per_uclk=round(total / (span * 1000 / UCLK_PS), 2),
                         bytes_per_xclk=round(total / (span * 1000 / XCLK_PS), 2))
        assert not errs, errs[:5]
    await wait_idle(env)
    env.stop = True
    dut._log.info(f"поток XDMA: {res}")
    finish(env, "stream_x", dict(x_stream=res))
