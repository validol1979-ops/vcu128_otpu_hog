"""What each unit does to the data: the functional half of the simulation.

execute(m, ins) applies one instruction to the memories and returns a small record of what
moved (bytes per path) and a preview of the values (for the trace and the player). The
sequencer calls it when the instruction's dependencies are all clear -- at start, or for an MM
at release -- so applying the whole effect at once gives the results of sequential execution,
as the hardware's scoreboard does.
"""
import numpy as np

from .isa import REDUCE
from .numerics import F32, mm_int8, quantize_rows


def _p(x, n=6):
    """Preview of a vector: first n values."""
    x = np.asarray(x).ravel()[:n]
    if x.dtype.kind in "iu":
        return " ".join(str(int(v)) for v in x)
    return " ".join(f"{float(v):.4g}" for v in x)


def execute(m, ins) -> dict:
    return {"LD": _ld, "ST": _st, "MM": _mm, "QACT": _qact, "QST": _qst, "VOP": _vop,
            "HALT": lambda m, a: {}}[ins.op](m, ins.a)


def _ld(m, a):
    v = m.hbm.read_f32(a["hbm"], a["n"]).copy()
    m.tmem.mem[a["tmem"]:a["tmem"] + a["n"]] = v
    return dict(hbm_read=4 * a["n"], chan=m.hbm.channel_bytes(a["hbm"], 4 * a["n"]),
                preview=f"→ TMEM: {_p(v)}")


def _st(m, a):
    v = m.tmem.mem[a["tmem"]:a["tmem"] + a["n"]].copy()
    m.hbm.write_f32(a["hbm"], v)
    return dict(hbm_write=4 * a["n"], chan=m.hbm.channel_bytes(a["hbm"], 4 * a["n"]),
                preview=f"→ HBM: {_p(v)}")


def _mm(m, a):
    N, K, M = a["N"], a["K"], a["M"]
    w = np.stack([m.hbm.read_i8(a["w"] + n * a["wrs"], K) for n in range(N)])
    ws = np.ones(N, F32) if a["unit"] else m.hbm.read_f32(a["ws"], N)
    o = a["ab"] * m.cfg.D
    act = m.act.codes[:M, o:o + K]
    sa = m.act.scale[:M, a["ab"]]
    y, acc = mm_int8(act, sa, w, ws)
    t = m.tmem.mem
    for j in range(M):
        o = a["out"] + j * a["ors"]
        old = t[o:o + N]
        if a["ascale"] is not None:
            y[j] = old * t[a["ascale"] + j] + y[j]
        elif a["acc"]:
            y[j] = old + y[j]
        t[o:o + N] = y[j]
        if a["rmax"] is not None:
            t[a["rmax"] + j] = np.max(y[j])
    rd = N * K + (0 if a["unit"] else 4 * N)
    ex = dict(act=_p(act[0], 8), sa=float(sa[0]), w=_p(w[0], 8), sw=float(ws[0]),
              acc=int(acc[0, 0]), y=float(y[0, 0]))
    return dict(hbm_read=rd, chan=[N * K // 2] * 2, chunks=N * K // 128,
                macs=M * N * K, preview=f"→ TMEM: {_p(y[0])}", example=ex)


def _qact(m, a):
    M, K = a["M"], a["K"]
    t = m.tmem.mem
    x = np.stack([t[a["src"] + r * a["stride"]: a["src"] + r * a["stride"] + K] for r in range(M)])
    x = x.astype(F32) * F32(a["imm"])
    if a["rscale"] is not None:
        x *= t[a["rscale"]:a["rscale"] + M][:, None]
    if a["cscale"] is not None:
        x *= t[a["cscale"]:a["cscale"] + K][None, :]
    codes, scale = quantize_rows(x)
    o, kb = a["ab"] * m.cfg.D, K // m.cfg.D
    m.act.codes[:M, o:o + K] = codes
    m.act.scale[:M, a["ab"]:a["ab"] + kb] = scale[:, None]
    err = float(np.max(np.abs(codes.astype(F32) * scale[:, None] - x)))
    ex = dict(x=_p(x[0], 6), maxabs=float(np.max(np.abs(x[0]))), scale=float(scale[0]),
              codes=_p(codes[0], 6), err=err)
    return dict(preview=f"ACT[0][блок {a['ab']}]: {_p(codes[0], 8)} · Sa={scale[0]:.4g}", example=ex)


def _qst(m, a):
    v = m.tmem.mem[a["src"]:a["src"] + a["n"]]
    codes, scale = quantize_rows(v)
    s = a["stride"]
    if s == 1:
        m.hbm.write_i8(a["dst"], codes[0])
    else:                                    # V^T column: one byte per row of the tile
        for i, c in enumerate(codes[0]):
            m.hbm.mem[a["dst"] + i * s] = np.uint8(np.int8(c).view(np.uint8))
    m.hbm.write_f32(a["dscale"], scale)
    # every byte lands in its own 64-byte beat when strided (read-modify-write of the beat)
    touched = a["n"] if s == 1 else a["n"] * 64
    return dict(hbm_write=touched + 4, preview=f"→ HBM INT8: {_p(codes[0], 8)} · s={scale[0]:.4g}",
                example=dict(x=_p(v), scale=float(scale[0]), codes=_p(codes[0])))


def _vop(m, a):
    t = m.tmem.mem
    f, R, C = a["func"], a["rows"], a["cols"]
    out0 = None
    for r in range(R):
        x = t[a["a"] + r * a["sa"]: a["a"] + r * a["sa"] + C] if a["a"] is not None else None
        bm = a["bmode"]
        if bm == "full":
            b = t[a["b"] + r * a["sb"]: a["b"] + r * a["sb"] + C]
        elif bm == "row":
            b = t[a["b"] + r * a["sb"]]
        elif bm == "col":
            b = t[a["b"]: a["b"] + C]
        else:
            b = F32(a["imm"])
        with np.errstate(over="ignore", divide="ignore"):
            y = {
                "add": lambda: x + b, "sub": lambda: x - b, "mul": lambda: x * b,
                "max": lambda: np.maximum(x, b), "copy": lambda: x.copy(),
                "fill": lambda: np.full(C, F32(a["imm"])), "exp2": lambda: np.exp2(x),
                "exp2sub": lambda: np.exp2(x - b), "recip": lambda: F32(1) / x,
                "rsqrt": lambda: F32(1) / np.sqrt(x), "rssq": lambda: np.sum(x * x),
                "rsum": lambda: np.sum(x), "rmax": lambda: np.max(x),
            }[f]()
        y = np.asarray(y, F32)
        d = a["dst"] + r * a["sd"]
        if f in REDUCE:
            t[d] = y
        else:
            t[d:d + C] = y
        if out0 is None:
            out0 = y
    return dict(preview=f"→ TMEM: {_p(out0)}")
