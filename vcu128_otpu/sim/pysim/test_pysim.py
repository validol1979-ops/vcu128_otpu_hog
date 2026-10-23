"""Checks of the teaching simulator: numerics, scoreboard equivalence, calibration with the RTL.

    python3 -m pytest -q vcu128_otpu/sim/pysim/test_pysim.py
"""
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from otpusim import Config, Model, Spec, isa  # noqa: E402
from otpusim.memory import HBM  # noqa: E402
from run import LENS_QWEN_TINY_POS8, simulate  # noqa: E402


@pytest.mark.parametrize("pos", [0, 8, 300])
def test_logits_match_float_reference(pos):
    md, prog, res, probe, ref, _ = simulate(pos)
    lg = md.logits()
    cos = lg @ ref / np.linalg.norm(lg) / np.linalg.norm(ref)
    assert cos > 0.998
    assert len(set(np.argsort(-lg)[:5]) & set(np.argsort(-ref)[:5])) >= 4
    if pos == 300:          # two attention blocks of 256: the online softmax spans both
        assert sum("q·Kᵀ, блок 1 (" in i.text for i in prog) == md.spec.L * md.spec.Hkv


def test_overlapped_execution_equals_sequential():
    """The scoreboard lets units overlap; the results must equal in-order execution bit for bit."""
    cfg, sp = Config(), Spec()
    toks = [3, 141, 59, 265]
    out = []
    for timed in (False, True):
        md = Model(cfg, sp, 256)
        for p, t in enumerate(toks):
            md.host_inputs(t, p)
            prog = md.compile_step(p)
            md.m.run(prog) if timed else md.m.run_functional(prog)
        out.append(md.logits())
    assert np.array_equal(out[0], out[1])


def test_cycles_close_to_upstream_rtl():
    md, prog, res, *_ = simulate(8)
    assert abs(res["cycles"] / LENS_QWEN_TINY_POS8 - 1) < 0.10
    busy = {k[5:]: 100 * sum(v) / res["cycles"] for k, v in res["series"].items() if k.startswith("busy_")}
    assert busy["MXU"] > 95        # Lens: MXU 99.1 %, VPU 36.7 %, QUANT 17.2 %, DMA 3.4 %
    assert 25 < busy["VPU"] < 45 and 10 < busy["QUANT"] < 25 and busy["DMA"] < 10


def test_scoreboard_conflicts():
    w = isa.VOP("add", 100, a=0, cols=8)                 # writes T[100], reads T[0..8)
    r = isa.VOP("mul", 200, a=100, cols=1)               # reads T[100]: RAW
    other = isa.VOP("mul", 300, a=400, cols=8)
    assert isa.conflicts(w, r) and not isa.conflicts(w, other)
    st = isa.QST(0, 128, 4096, 8192)
    mm = isa.MM(4096, 8192, 1, 128, 1, 500, 0)
    assert isa.conflicts(st, mm, {"HBM"})                # K written by QST, read by the MM


def test_beat_interleave():
    h = HBM(Config(), 1 << 16)
    assert h.channel_bytes(0, 128) == [64, 64]           # one MXU chunk = one beat per channel
    assert h.channel_bytes(64, 64) == [0, 64]
