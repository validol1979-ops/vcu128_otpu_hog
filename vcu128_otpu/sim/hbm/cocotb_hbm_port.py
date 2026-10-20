"""cocotb-тесты otpu_hbm_port: сторона c_* (модель otpu_mem_ch) + модель HBM (hbm_model).

Параметры DUT приходят через окружение (HBM_CH_BASE, HBM_PC_GRAN, HBM_PC_XOR), объём и зерно --
HBM_N, SEED. Итоги каждого теста -- out/<тег запуска>__<тест>.json (для отчёта).
"""

import json
import os
import random
from collections import deque
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from hbm_model import Cfg, HbmModel, default_beat, hbm_map

CH_BASE = int(os.environ.get("HBM_CH_BASE", "0"), 0)
GRAN = int(os.environ.get("HBM_PC_GRAN", "0"))
XOR = os.environ.get("HBM_PC_XOR", "1") == "1"
N = int(os.environ.get("HBM_N", "20000"))
SEED = int(os.environ.get("SEED", "1"))
OUT = Path(os.environ.get("HBM_OUT", "."))
TAG = os.environ.get("HBM_TAG", "port")
M512 = (1 << 512) - 1
FULL = (1 << 64) - 1


def amap(beat):
    return hbm_map(beat, CH_BASE, GRAN, XOR)


def apply_we(old, new, we):
    if we == FULL:
        return new
    m = 0
    for k in range(64):
        if (we >> k) & 1:
            m |= 0xFF << (8 * k)
    return (old & ~m) | (new & m)


class CSide:
    """Сторона контроллера otpu_mem_ch: два порта, эталон памяти по beat.

    Команды порта держатся до приёма; данные записи -- на голове c_wdata, как только команда
    записи сгенерирована (до команды или вместе с ней), в порядке команд записи. Чтения
    проверяются в порядке команд порта; два c_rdata_valid в одном такте -- ошибка.
    """

    def __init__(self, dut, rng, gens, p_valid=0.8, lookahead=(0, 4)):
        self.dut, self.rng, self.gens = dut, rng, gens
        self.p_valid, self.lookahead = p_valid, lookahead
        self.ref = {}
        self.pend = [deque(), deque()]      # сгенерированные, не принятые: (we, beat, data, mask)
        self.cv = [0, 0]                    # c_cmd_valid в текущем такте
        self.exp_r = [deque(), deque()]     # ожидаемые данные чтений
        self.exp_ar = [deque(), deque()]    # ожидаемые адреса AR / AW в порядке команд
        self.exp_aw = [deque(), deque()]
        self.n_rd = [0, 0]
        self.n_wr = [0, 0]
        self.n_rdata = 0
        self.errors = []
        self.t_first = None
        self.t_last = None

    def err(self, msg):
        if len(self.errors) < 50:
            self.errors.append(msg)

    def value(self, beat):
        v = self.ref.get(beat)
        return default_beat(amap(beat)) if v is None else v

    def gen_done(self, p):
        return self.gens[p] is None

    def done(self):
        return all(self.gens[p] is None and not self.pend[p] and not self.exp_r[p]
                   for p in range(2))

    def fill(self, p):
        want = self.rng.randint(*self.lookahead) + 1
        while self.gens[p] is not None and len(self.pend[p]) < want:
            try:
                self.pend[p].append(next(self.gens[p]))
            except StopIteration:
                self.gens[p] = None

    def drive(self):
        cv = cwe = ca = wv = wd = wm = 0
        for p in range(2):
            if not self.cv[p]:
                self.fill(p)
                if self.pend[p] and self.rng.random() < self.p_valid:
                    self.cv[p] = 1
            if self.cv[p]:
                we, beat, _, _ = self.pend[p][0]
                cv |= 1 << p
                cwe |= we << p
                ca |= beat << (25 * p)
            for c in self.pend[p]:
                if c[0]:
                    wv |= 1 << p
                    wd |= c[2] << (512 * p)
                    wm |= c[3] << (64 * p)
                    break
        d = self.dut
        d.c_cmd_valid.value = cv
        d.c_cmd_we.value = cwe
        d.c_cmd_addr.value = ca
        d.c_wdata_valid.value = wv
        d.c_wdata_data.value = wd
        d.c_wdata_we.value = wm
        self._wv = wv

    def sample(self, now):
        d = self.dut
        rdy = d.c_cmd_ready.value.to_unsigned()
        wrdy = d.c_wdata_ready.value.to_unsigned()
        rv = d.c_rdata_valid.value.to_unsigned()
        for p in range(2):
            acc = self.cv[p] and (rdy >> p) & 1
            if (wrdy >> p) & 1 and not (acc and self.pend[p][0][0]):
                self.err(f"{now}: порт {p}: c_wdata_ready без приёма команды записи")
            if not acc:
                continue
            we, beat, data, mask = self.pend[p].popleft()
            self.cv[p] = 0
            if self.t_first is None:
                self.t_first = now
            if we:
                if not (wrdy >> p) & 1 or not (self._wv >> p) & 1:
                    self.err(f"{now}: порт {p}: запись принята без данных")
                self.ref[beat] = apply_we(self.value(beat), data, mask)
                self.exp_aw[p].append(amap(beat))
                self.n_wr[p] += 1
            else:
                self.exp_r[p].append((beat, self.value(beat)))
                self.exp_ar[p].append(amap(beat))
                self.n_rd[p] += 1
        if rv:
            if rv == 3:
                self.err(f"{now}: c_rdata_valid обоих портов в одном такте")
            data = d.c_rdata_data.value.to_unsigned()
            d0, d1 = data & M512, data >> 512
            if d0 != d1:
                self.err(f"{now}: c_rdata_data[1] != [0]")
            for p in range(2):
                if (rv >> p) & 1:
                    if not self.exp_r[p]:
                        self.err(f"{now}: порт {p}: данные чтения без команды")
                        continue
                    beat, exp = self.exp_r[p].popleft()
                    self.n_rdata += 1
                    self.t_last = now
                    if d0 != exp:
                        self.err(f"{now}: порт {p}: beat {beat:#x}: прочитано {d0:#x}, "
                                 f"ожидалось {exp:#x}")

    def on_ar(self, p, addr, rid):
        if not self.exp_ar[p]:
            self.err(f"порт {p}: AR {addr:#x} без команды")
            return
        e = self.exp_ar[p].popleft()
        if e != addr:
            self.err(f"порт {p}: AR {addr:#x}, ожидался {e:#x}")

    def on_aw(self, p, addr, wid):
        if not self.exp_aw[p]:
            self.err(f"порт {p}: AW {addr:#x} без команды")
            return
        e = self.exp_aw[p].popleft()
        if e != addr:
            self.err(f"порт {p}: AW {addr:#x}, ожидался {e:#x}")


def rand_gen(rng, p, n, p_write=0.5, p_hot=0.5, p_partial=0.2):
    """Случайные команды порта p (бит 7 beat = p): горячие beat (коллизии), окно, всё."""
    def fix(b):
        return (b & ~0x80) | (p << 7)
    hot = [fix(rng.getrandbits(25)) for _ in range(6)] + [fix(rng.randrange(256)) for _ in range(4)]
    for _ in range(n):
        r = rng.random()
        if r < p_hot:
            beat = rng.choice(hot)
        elif r < 0.9:
            beat = fix(rng.randrange(4096))
        else:
            beat = fix(rng.getrandbits(25))
        if rng.random() < p_write:
            mask = FULL if rng.random() >= p_partial else rng.getrandbits(64)
            yield 1, beat, rng.getrandbits(512), mask
        else:
            yield 0, beat, 0, 0


def seq_gen(rng, p, n, kind):
    """Поток соседних beat порта p: kind = 'r', 'w' или 'rw' (чтение и запись по очереди)."""
    i = 0
    for k in range(n):
        beat = ((i >> 7) << 8) | (p << 7) | (i & 127)
        if kind == "r" or (kind == "rw" and k % 2):
            yield 0, beat, 0, 0
        else:
            yield 1, beat, rng.getrandbits(512), FULL
        i += 1


async def setup(dut, cfg, rng, clock=True):
    if clock:
        cocotb.start_soon(Clock(dut.uclk, 4444, unit="ps").start())
    else:
        await RisingEdge(dut.uclk)
    model = HbmModel(dut, rng, cfg, ch_base=CH_BASE)
    for s in ("c_cmd_valid", "c_cmd_we", "c_cmd_addr", "c_wdata_valid", "c_wdata_data",
              "c_wdata_we"):
        getattr(dut, s).value = 0
    dut.urst.value = 1
    for _ in range(8):
        await RisingEdge(dut.uclk)
    dut.urst.value = 0
    return model


async def run(dut, cs, model, limit):
    """Такт: после фронта -- выходы моделей, в ReadOnly -- рукопожатия этого такта."""
    model.ports[0].on_ar = model.ports[1].on_ar = cs.on_ar
    model.ports[0].on_aw = model.ports[1].on_aw = cs.on_aw
    now, idle = 0, 0
    maxbusy = [0, 0]
    while now < limit:
        await RisingEdge(dut.uclk)
        now += 1
        cs.drive()
        model.drive()
        await ReadOnly()
        cs.sample(now)
        model.sample_step(now)
        if cs.errors or model.errors:
            break
        if cs.done() and not model.busy():
            idle += 1
            if idle > 8 and dut.st_busy.value.to_unsigned() == 0:
                break
        else:
            idle = 0
    return now


def status(dut):
    def arr(sig, w):
        v = sig.value.to_unsigned()
        return [(v >> (w * p)) & ((1 << w) - 1) for p in range(2)]
    return dict(rcmd=arr(dut.st_rcmd, 32), wcmd=arr(dut.st_wcmd, 32), rout=arr(dut.st_rout, 7),
                wout=arr(dut.st_wout, 7), dep=arr(dut.st_dep, 32), busy=dut.st_busy.value.to_unsigned(),
                err_cnt=dut.st_err_cnt.value.to_unsigned(), err=int(dut.st_err.value),
                perr=int(dut.st_perr.value))


def final_checks(dut, cs, model, cycles, limit, name, errs_expected=0, extra=None):
    st = status(dut)
    res = dict(test=name, seed=SEED, ch_base=hex(CH_BASE), gran=GRAN, xor=XOR, cycles=cycles,
               reads=cs.n_rd, writes=cs.n_wr, rdata=cs.n_rdata, status=st,
               hbm_ar=[pm.n_ar for pm in model.ports], hbm_aw=[pm.n_aw for pm in model.ports],
               overtakes=sum(pm.overtakes for pm in model.ports),
               w_before_aw=sum(pm.w_before_aw for pm in model.ports))
    if extra:
        res.update(extra)
    errs = cs.errors + model.errors
    if cycles >= limit:
        errs.append(f"не завершилось за {limit} тактов")
    if st["rcmd"] != cs.n_rd or st["wcmd"] != cs.n_wr:
        errs.append(f"счётчики команд {st['rcmd']}/{st['wcmd']} != {cs.n_rd}/{cs.n_wr}")
    if st["rout"] != [0, 0] or st["wout"] != [0, 0] or st["busy"]:
        errs.append(f"порт не пуст в конце: {st}")
    if st["err_cnt"] != errs_expected or st["perr"] or st["err"] != int(errs_expected > 0):
        errs.append(f"ошибки: st_err_cnt {st['err_cnt']} (ожидалось {errs_expected}), "
                    f"st_err {st['err']}, st_perr {st['perr']}")
    if res["w_before_aw"]:
        errs.append(f"W раньше AW: {res['w_before_aw']}")
    # итоговая память = эталон (по отображению адресов)
    bad = 0
    for beat, v in cs.ref.items():
        a = amap(beat)
        got = model.mem.read(a) | (model.mem.read(a + 32) << 256)
        if got != v:
            bad += 1
    if bad:
        errs.append(f"итоговая память: {bad} beat не совпали")
    res["beats_checked"] = len(cs.ref)
    res["errors"] = errs[:20]
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{TAG}__{name}.json").write_text(json.dumps(res, indent=1, ensure_ascii=False))
    dut._log.info(json.dumps(res, ensure_ascii=False))
    assert not errs, "\n".join(errs[:20])
    return res


@cocotb.test()
async def random_traffic(dut):
    """Случайный трафик обоих портов с коллизиями по beat, случайные задержки и давление."""
    rng = random.Random(SEED)
    cfg = Cfg(stall=(0.002, 5, 60))
    model = await setup(dut, cfg, rng)
    cs = CSide(dut, rng, [rand_gen(rng, p, N) for p in range(2)])
    limit = 60 * N + 20000
    cycles = await run(dut, cs, model, limit)
    res = final_checks(dut, cs, model, cycles, limit, f"random_traffic_g{GRAN}")
    assert res["status"]["dep"][0] > 0 and res["status"]["dep"][1] > 0, "нет ожиданий по beat"
    assert res["overtakes"] > 0, "модель ни разу не выполнила чтение раньше записи"


@cocotb.test()
async def hazard_pairs(dut):
    """Пары запись->чтение (RAW) и чтение->запись (WAR) одного beat подряд; запись выполняется
    медленно, чтение быстро (RAW), и наоборот (WAR)."""
    rng = random.Random(SEED + 1)
    for i, (lat_r, lat_w) in enumerate((((1, 3), (40, 80)), ((40, 80), (1, 3)))):
        cfg = Cfg(rlat=lat_r, wlat=lat_w, p_rgap=0.0, p_bgap=0.0, p_awready=0.9,
                  p_arready=0.9, p_wready=0.9)
        model = await setup(dut, cfg, rng, clock=(i == 0))

        def gen(p, n=N // 4):
            beats = [(rng.randrange(1 << 18) & ~0x80) | (p << 7) for _ in range(4)]
            for _ in range(n):
                b = rng.choice(beats)
                if rng.random() < 0.5:
                    yield 1, b, rng.getrandbits(512), FULL
                    yield 0, b, 0, 0
                else:
                    yield 0, b, 0, 0
                    yield 1, b, rng.getrandbits(512), FULL
        cs = CSide(dut, rng, [gen(0), gen(1)], p_valid=1.0)
        limit = 400 * N
        cycles = await run(dut, cs, model, limit)
        final_checks(dut, cs, model, cycles, limit, f"hazard_pairs_r{lat_r[0]}_w{lat_w[0]}_g{GRAN}")


@cocotb.test()
async def resp_errors(dut):
    """RRESP/BRESP = SLVERR: счётчик st_err_cnt (по словам R и по B), данные всё равно идут."""
    rng = random.Random(SEED + 2)
    cfg = Cfg(p_rerr=0.05, p_berr=0.05)
    model = await setup(dut, cfg, rng)
    n = min(N, 4000)
    cs = CSide(dut, rng, [rand_gen(rng, p, n) for p in range(2)])

    # ожидаемое число: перехват ответов модели
    count = {"n": 0}
    for pm in model.ports:
        orig = pm.step

        def step(now, s, pm=pm, orig=orig):
            if pm.rvalid and s["rready"] and pm.rcur[0][3]:
                count["n"] += 1
            if pm.bvalid and s["bready"] and pm.bcur[2]:
                count["n"] += 1
            orig(now, s)
        pm.step = step
    limit = 60 * n + 20000
    cycles = await run(dut, cs, model, limit)
    final_checks(dut, cs, model, cycles, limit, f"resp_errors_g{GRAN}", errs_expected=count["n"])


async def stream(dut, kind, lat, n):
    rng = random.Random(SEED + 3)
    model = await setup(dut, Cfg.fast(lat), rng)
    cs = CSide(dut, rng, [seq_gen(rng, p, n, kind) for p in range(2)], p_valid=1.0,
               lookahead=(4, 4))
    # время окончания: последние данные чтения / последний B
    t_b = {"t": None}
    for pm in model.ports:
        orig = pm.step

        def step(now, s, pm=pm, orig=orig):
            if pm.bvalid and s["bready"]:
                t_b["t"] = now
            orig(now, s)
        pm.step = step
    limit = 20 * n + 5000
    cycles = await run(dut, cs, model, limit)
    t_end = max(x for x in (cs.t_last, t_b["t"]) if x is not None)
    span = t_end - cs.t_first + 1
    nbytes = 2 * n * 64
    bpc = nbytes / span
    final_checks(dut, cs, model, cycles, limit, f"stream_{kind}_lat{lat}_g{GRAN}",
                 extra=dict(span_cycles=span, bytes=nbytes, bytes_per_cycle=round(bpc, 2),
                            gbps_225mhz=round(bpc * 0.225, 2)))
    dut._log.info(f"поток {kind}, задержка {lat}: {bpc:.2f} байт/такт uclk "
                  f"({bpc * 0.225:.2f} ГБ/с при 225 МГц)")


@cocotb.test()
async def stream_read(dut):
    await stream(dut, "r", 40, 4096)


@cocotb.test()
async def stream_write(dut):
    await stream(dut, "w", 40, 4096)


@cocotb.test()
async def stream_mixed(dut):
    await stream(dut, "rw", 40, 4096)


@cocotb.test()
async def stream_read_lat100(dut):
    await stream(dut, "r", 100, 4096)
