"""The slice, cycle by cycle: sequencer (window + scoreboard) and the five units' timing.

Per cycle, in this order (upstream rtl/seq/otpu_seq.sv, rtl/mxu/otpu_mxu.sv):
 1. FETCH/DISPATCH: the next instruction enters the window (WIN slots) with the set of older
    in-flight instructions it conflicts with (RAW / WAR / WAW on TMEM, HBM or ACT ranges).
 2. START: every free unit starts its oldest instruction whose dependencies have completed
    (DMA, QUANT in order; the VPU its oldest ready one). The MXU starts in two phases:
    ACCEPT (ustart) once the MM's HBM dependencies are clear -- the issuer may stream weights
    into the chunk FIFO -- and RELEASE (urel) once all are clear (its ACT operand is ready).
 3. PORT B: one 128-byte chunk per cycle; the DMA has priority, the MXU issuer takes the rest.
 4. MXU: a row is consumed (KB cycles, one chunk each) only when all its KB chunks are in the
    FIFO; results leave through the drain, 2 FP32 per cycle, after the pipeline latency.
 5. COMPLETE: finished instructions leave the window and wake their dependants.
"""
from collections import defaultdict
from math import ceil

from .config import Config
from .isa import COMPOSITE, REDUCE, conflicts
from .memory import HBM, TMEM, ActRAM
from .units import execute

UNITS = ["DMA", "MXU", "QUANT", "VPU"]


class _MM:
    """One MM command inside the MXU."""

    def __init__(self, ins, cyc, cfg):
        self.ins = ins
        a = ins.a
        self.kb = a["K"] // cfg.D
        self.rows = a["N"]
        self.total = self.rows * self.kb
        self.issued = 0
        self.arrivals = []          # cycle each issued chunk reaches the FIFO
        self.arrived = 0
        self.consumed = 0           # chunks
        self.row = 0
        self.prog = 0               # chunks of the current row consumed
        self.released = False
        self.drain = []             # [ready_cycle, results]
        self.accept = cyc


class Machine:
    def __init__(self, cfg: Config, hbm_bytes: int):
        self.cfg = cfg
        self.hbm = HBM(cfg, hbm_bytes)
        self.tmem = TMEM(cfg)
        self.act = ActRAM(cfg)

    # ---------------------------------------------------------------- functional only
    def run_functional(self, program, observer=None):
        for ins in program:
            r = execute(self, ins)
            if observer:
                observer(ins, r, self)

    # ---------------------------------------------------------------- timed run
    def run(self, program, bucket=16, max_cycles=5_000_000, observer=None):
        cfg = self.cfg
        for i, ins in enumerate(program):
            ins.id = i
        rec = {i.id: dict(dispatch=None, start=None, release=None, end=None) for i in program}
        info = {}
        window = []                 # instructions in flight, program order
        deps, hdeps = {}, {}
        done = set()
        pc = 0
        halting = False
        unit_cur = {"DMA": None, "QUANT": None, "VPU": None}   # (ins, end or state)
        ustate = {}
        mxu = []                    # accepted _MM commands (<= 2)
        fifo = 0                    # chunks reserved in the FIFO (issued - consumed)
        series = defaultdict(lambda: defaultdict(int))
        cyc = 0

        def ex(ins):
            info[ins.id] = r = execute(self, ins)
            if observer:
                observer(ins, r, self)

        def finish(ins):
            rec[ins.id]["end"] = cyc
            done.add(ins.id)
            window.remove(ins)

        while True:
            # 1. fetch / dispatch
            if not halting and pc < len(program) and len(window) < cfg.WIN:
                ins = program[pc]
                pc += 1
                if ins.op == "HALT":
                    halting = True
                    rec[ins.id].update(dispatch=cyc, start=cyc)
                else:
                    older = [o for o in window if conflicts(o, ins)]
                    deps[ins.id] = {o.id for o in older}
                    hdeps[ins.id] = {o.id for o in older if conflicts(o, ins, {"HBM"})}
                    window.append(ins)
                    rec[ins.id]["dispatch"] = cyc
            if halting and not window:
                rec[program[-1].id]["end"] = cyc
                break

            ready = lambda i: deps[i.id] <= done          # noqa: E731
            pending = [i for i in window if rec[i.id]["start"] is None]

            # 2. starts
            for u in ("DMA", "QUANT"):
                if unit_cur[u] is None:
                    cand = next((i for i in pending if i.unit == u), None)
                    if cand is not None and ready(cand):
                        rec[cand.id]["start"] = cyc
                        ex(cand)
                        unit_cur[u] = cand
                        if u == "QUANT":
                            ustate[cand.id] = cyc + self._quant_cycles(cand)
                        else:
                            n = cand.a["n"]
                            ustate[cand.id] = dict(chunks=ceil(4 * n / cfg.D), issued=0,
                                                      words=n, last=None)
            if unit_cur["VPU"] is None:
                cand = next((i for i in pending if i.unit == "VPU" and ready(i)), None)
                if cand is not None:
                    rec[cand.id]["start"] = cyc
                    ex(cand)
                    unit_cur["VPU"] = cand
                    ustate[cand.id] = cyc + self._vpu_cycles(cand)
            if len(mxu) < 2:                                  # ACCEPT, in order
                cand = next((i for i in pending if i.unit == "MXU"), None)
                if cand is not None and hdeps[cand.id] <= done:
                    rec[cand.id]["start"] = cyc
                    mxu.append(_MM(cand, cyc, cfg))
            for c in mxu:                                     # RELEASE, in order
                if not c.released:
                    if ready(c.ins):
                        c.released = True
                        rec[c.ins.id]["release"] = cyc
                        ex(c.ins)
                    break

            # 3. port B: DMA first, then the MXU issuer
            owner = None
            d = unit_cur["DMA"]
            if d is not None:
                st = ustate[d.id]
                if st["issued"] < st["chunks"]:
                    st["issued"] += 1
                    owner = "dma"
                    if st["issued"] == st["chunks"]:
                        st["last"] = cyc
            if owner is None:
                for c in mxu:
                    if c.issued < c.total:
                        if fifo < cfg.FIFO_DEPTH:
                            c.issued += 1
                            c.arrivals.append(cyc + cfg.mem_lat)
                            fifo += 1
                            owner = "mxu"
                        break
            if owner:
                series["portb_" + owner][cyc // bucket] += 1

            # 4. MXU consumer (in order) and drain
            computing = False
            for c in mxu:
                while c.arrived < len(c.arrivals) and c.arrivals[c.arrived] <= cyc:
                    c.arrived += 1
            cons = next((c for c in mxu if c.row < c.rows), None)
            if cons is not None and cons.released:
                need = (cons.row + 1) * cons.kb
                if cons.prog > 0 or cons.arrived >= need:     # a row starts only when complete
                    cons.prog += 1
                    cons.consumed += 1
                    fifo -= 1
                    computing = True
                    if cons.prog == cons.kb:
                        cons.drain.append([cyc + cfg.mxu_pipe, cons.ins.a["M"]])
                        cons.row += 1
                        cons.prog = 0
                elif cons.arrived < need:
                    series["mxu_starve"][cyc // bucket] += 1
            for c in mxu:
                cap = cfg.mxu_drain
                while c.drain and c.drain[0][0] <= cyc and cap:
                    k = min(cap, c.drain[0][1])
                    c.drain[0][1] -= k
                    cap -= k
                    if c.drain[0][1] == 0:
                        c.drain.pop(0)
            if computing:
                series["mxu_busy"][cyc // bucket] += 1
            series["fifo"][cyc // bucket] = max(series["fifo"][cyc // bucket], fifo)
            series["window"][cyc // bucket] = max(series["window"][cyc // bucket], len(window))
            for u in UNITS:
                busy = (bool(mxu) if u == "MXU" else unit_cur[u] is not None)
                if busy:
                    series["busy_" + u][cyc // bucket] += 1

            # 5. completions
            for c in list(mxu):
                if c.row == c.rows and not c.drain and c.released:
                    mxu.remove(c)
                    finish(c.ins)
            d = unit_cur["DMA"]
            if d is not None:
                st = ustate[d.id]
                if st["last"] is not None:
                    t_end = max(st["last"] + cfg.mem_lat,
                                rec[d.id]["start"] + ceil(st["words"] / cfg.LANES) + cfg.mem_lat)
                    if cyc >= t_end:
                        finish(d)
                        unit_cur["DMA"] = None
            for u in ("QUANT", "VPU"):
                i = unit_cur[u]
                if i is not None and cyc >= ustate[i.id]:
                    finish(i)
                    unit_cur[u] = None
            cyc += 1
            assert cyc < max_cycles, "watchdog: the simulation does not finish"

        nb = cyc // bucket + 1
        ser = {k: [v.get(b, 0) for b in range(nb)] for k, v in series.items()}
        return dict(cycles=cyc, rec=rec, info=info, series=ser, bucket=bucket)

    # ---------------------------------------------------------------- unit durations
    def _vpu_cycles(self, ins):
        a, cfg = ins.a, self.cfg
        e = a["rows"] * a["cols"]
        if a["func"] in COMPOSITE:
            return ceil(e / cfg.vpu_comp_rate) + cfg.vpu_comp_lat
        extra = 28 if a["func"] in REDUCE else 0
        return ceil(e / cfg.LANES) + cfg.vpu_lat + extra

    def _quant_cycles(self, ins):
        a, cfg = ins.a, self.cfg
        if ins.op == "QACT":
            return a["M"] * 2 * ceil(a["K"] / cfg.LANES) + cfg.quant_lat
        return a["n"] + cfg.qst_lat                    # QST: one word per cycle on port SW
