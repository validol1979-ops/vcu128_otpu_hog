"""A readable subset of the openTPU ISA (upstream docs/isa.md), one dataclass per instruction.

Same opcodes, units and data paths as the hardware; operands are named fields instead of the
packed 8 x 32-bit words, and every instruction carries its memory footprint (what the
sequencer's scoreboard compares) and a Russian description for the trace.

    LD   HBM -> DMA -> TMEM          ST   TMEM -> DMA -> HBM
    MM   HBM (rows) -> MXU <- ACT;  MXU -> TMEM
    QACT TMEM -> QUANT -> ACT        QST  TMEM -> QUANT -> HBM
    VOP  TMEM -> VPU -> TMEM         HALT
"""
from dataclasses import dataclass, field

UNIT_OF = {"LD": "DMA", "ST": "DMA", "MM": "MXU", "QACT": "QUANT", "QST": "QUANT",
           "VOP": "VPU", "HALT": "SEQ"}
# data paths drawn by the player: (from, to) pairs of floorplan blocks
PATHS = {
    "LD": [("HBM", "PORTB"), ("PORTB", "DMA"), ("DMA", "TMEM")],
    "ST": [("TMEM", "DMA"), ("DMA", "PORTB"), ("PORTB", "HBM")],
    "MM": [("HBM", "PORTB"), ("PORTB", "MXU"), ("HBM", "PORTA"), ("PORTA", "MXU"),
           ("ACT", "MXU"), ("MXU", "TMEM")],
    "QACT": [("TMEM", "QUANT"), ("QUANT", "ACT")],
    "QST": [("TMEM", "QUANT"), ("QUANT", "PORTSW"), ("PORTSW", "HBM")],
    "VOP": [("TMEM", "VPU"), ("VPU", "TMEM")],
    "HALT": [],
}
COMPOSITE = {"exp2", "exp2sub", "recip", "rsqrt"}
REDUCE = {"rssq", "rsum", "rmax"}


@dataclass
class Instr:
    op: str
    a: dict
    text: str = ""
    step: str = ""
    layer: int = -1
    reads: list = field(default_factory=list)    # (space, lo, hi): HBM bytes, TMEM words, ACT blocks
    writes: list = field(default_factory=list)
    id: int = -1

    @property
    def unit(self) -> str:
        return UNIT_OF[self.op]

    @property
    def name(self) -> str:
        return f"VOP.{self.a['func']}" if self.op == "VOP" else self.op


def _t(lo, n):
    return ("TMEM", lo, lo + n)


def LD(hbm, tmem, n, **kw):
    """n FP32 words HBM[hbm..] -> TMEM[tmem..]."""
    return Instr("LD", dict(hbm=hbm, tmem=tmem, n=n), reads=[("HBM", hbm, hbm + 4 * n)],
                 writes=[_t(tmem, n)], **kw)


def ST(tmem, hbm, n, **kw):
    return Instr("ST", dict(hbm=hbm, tmem=tmem, n=n), reads=[_t(tmem, n)],
                 writes=[("HBM", hbm, hbm + 4 * n)], **kw)


def MM(w, ws, N, K, M, out, ors, acc=False, ascale=None, rmax=None, unit=False, wrs=None,
       ab=0, **kw):
    """out[j, n] = sum_k ACT[j, k] * W[n, k] (W: N rows of K INT8 at HBM w + n*wrs, row scales
    at ws; unit: scales 1, as for V^T whose scales are folded into P)."""
    assert K % 128 == 0 and 1 <= M <= 4
    wrs = wrs or K
    reads = [("HBM", w, w + (N - 1) * wrs + K), ("ACT", ab, ab + K // 128)]
    if not unit:
        reads.append(("HBM", ws, ws + 4 * N))
    writes = [("TMEM", out, out + (M - 1) * ors + N)]
    if acc or ascale is not None:
        reads.append(("TMEM", out, out + (M - 1) * ors + N))
    if ascale is not None:
        reads.append(_t(ascale, M))
    if rmax is not None:
        writes.append(_t(rmax, M))
    return Instr("MM", dict(w=w, ws=ws, N=N, K=K, M=M, out=out, ors=ors, acc=acc, wrs=wrs, ab=ab,
                            ascale=ascale, rmax=rmax, unit=unit), reads=reads, writes=writes, **kw)


def QACT(src, M, K, stride, rscale=None, cscale=None, imm=1.0, ab=0, **kw):
    """ACT rows 0..M-1, blocks ab.. <- int8(T[src + r*stride + k] * rscale[r] * cscale[k] * imm)."""
    reads = [("TMEM", src, src + (M - 1) * stride + K)]
    if rscale is not None:
        reads.append(_t(rscale, M))
    if cscale is not None:
        reads.append(_t(cscale, K))
    return Instr("QACT", dict(src=src, M=M, K=K, stride=stride, rscale=rscale, cscale=cscale,
                              imm=imm, ab=ab), reads=reads, writes=[("ACT", ab, ab + K // 128)],
                 **kw)


def QST(src, n, dst, dscale, stride=1, **kw):
    """HBM bytes dst + i*stride <- int8(T[src + i]); HBM dscale <- FP32 row scale."""
    return Instr("QST", dict(src=src, n=n, dst=dst, dscale=dscale, stride=stride),
                 reads=[_t(src, n)],
                 writes=[("HBM", dst, dst + (n - 1) * stride + 1), ("HBM", dscale, dscale + 4)],
                 **kw)


def VOP(func, dst, a=None, b=None, rows=1, cols=1, sa=0, sb=0, sd=0, bmode="none", imm=0.0, **kw):
    """Element (r, c): dst[r*sd + c] = f(a[r*sa + c], b) with b full / row / col / imm."""
    reads = []
    if a is not None:
        reads.append(("TMEM", a, a + (rows - 1) * sa + cols))
    if b is not None:
        span = {"full": (rows - 1) * sb + cols, "row": (rows - 1) * sb + 1, "col": cols}[bmode]
        reads.append(("TMEM", b, b + span))
    dcols = 1 if func in REDUCE else cols
    writes = [("TMEM", dst, dst + (rows - 1) * sd + dcols)]
    return Instr("VOP", dict(func=func, dst=dst, a=a, b=b, rows=rows, cols=cols, sa=sa, sb=sb,
                             sd=sd, bmode=bmode, imm=imm), reads=reads, writes=writes, **kw)


def HALT(**kw):
    return Instr("HALT", {}, **kw)


def conflicts(older: Instr, newer: Instr, spaces=None) -> bool:
    """RAW, WAR or WAW on an overlapping range (the scoreboard's comparison)."""
    def hit(xs, ys):
        return any(s1 == s2 and (spaces is None or s1 in spaces) and lo1 < hi2 and lo2 < hi1
                   for s1, lo1, hi1 in xs for s2, lo2, hi2 in ys)
    return (hit(older.writes, newer.reads) or hit(older.reads, newer.writes)
            or hit(older.writes, newer.writes))
