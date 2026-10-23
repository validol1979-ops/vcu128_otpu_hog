"""A tiny Qwen3 decoder, laid out in HBM and compiled to a program per token.

Shape and weights are upstream Lens' `qwen-tiny` (opentpu/lens.py _tiny_qwen: 2 layers, hidden
256, 4 query / 2 KV heads of 128, MLP 512, vocab 1000, rng seed 0), so the cycle count can be
compared with the RTL profile in sim/lens/. The lowering follows upstream qwen3_step /
kernels (attention.py, mlp.py): RMSNorm fused into QACT, operands in ACT RAM block ranges (ab), K/V appended by QST, q.K^T and P.V^T
on the MXU with the cache streamed from HBM, online softmax on the VPU, gate/up in chunks.
"""
from dataclasses import dataclass
from math import ceil, log2, sqrt

import numpy as np

from . import isa as I
from .config import Config
from .machine import Machine
from .numerics import F32, quantize_rows

LOG2E = 1.0 / np.log(2.0)


@dataclass(frozen=True)
class Spec:
    H: int = 256
    L: int = 2
    Hq: int = 4
    Hkv: int = 2
    d: int = 128
    F: int = 512
    V: int = 1000
    eps: float = 1e-6
    theta: float = 1e6
    block: int = 256          # attention block (upstream ATTN_BLOCK)
    fchunk: int = 256         # MLP chunk


def tiny_qwen_weights(spec: Spec):
    """Exactly lens._tiny_qwen()'s tensors (same generator calls in the same order)."""
    rng = np.random.default_rng(0)
    H, d, F, V = spec.H, spec.d, spec.F, spec.V
    W = {"embed": rng.normal(0, 0.02, (V, H)).astype(F32),
         "norm": (1 + 0.1 * rng.normal(size=H)).astype(F32)}
    for i in range(spec.L):
        W[f"{i}.g_in"] = (1 + 0.1 * rng.normal(size=H)).astype(F32)
        W[f"{i}.g_post"] = (1 + 0.1 * rng.normal(size=H)).astype(F32)
        W[f"{i}.qn"] = (1 + 0.1 * rng.normal(size=d)).astype(F32)
        W[f"{i}.kn"] = (1 + 0.1 * rng.normal(size=d)).astype(F32)
        for n, shp in (("q", (spec.Hq * d, H)), ("k", (spec.Hkv * d, H)),
                       ("v", (spec.Hkv * d, H)), ("o", (H, spec.Hq * d)),
                       ("gate", (F, H)), ("up", (F, H)), ("down", (H, F))):
            W[f"{i}.{n}"] = rng.normal(0, 0.05, shp).astype(F32)
    return W


class Model:
    """Image in HBM + compiler + host side (embedding row in, logits out)."""

    def __init__(self, cfg: Config, spec: Spec, cap: int):
        self.cfg, self.spec, self.cap = cfg, spec, cap
        self.W = tiny_qwen_weights(spec)
        self.m = Machine(cfg, hbm_bytes=8 << 20)
        self._layout()

    # ------------------------------------------------------------------ HBM image
    def _put_matrix(self, name, w, layer):
        codes, scale = quantize_rows(w)
        hb = self.m.hbm
        a = hb.alloc(name, codes.size, "weights", layer)
        hb.write_i8(a, codes)
        s = hb.alloc(name + ".scale", 4 * len(scale), "scales", layer)
        hb.write_f32(s, scale)
        return a, s

    def _put_vec(self, name, v, layer=-1, kind="norms"):
        a = self.m.hbm.alloc(name, 4 * len(v), kind, layer)
        self.m.hbm.write_f32(a, v)
        return a

    def _layout(self):
        sp, W, hb = self.spec, self.W, self.m.hbm
        self.io = dict(x=hb.alloc("io.x", 4 * sp.H, "io"), cos=hb.alloc("io.cos", 2 * sp.d, "io"),
                       sin=hb.alloc("io.sin", 2 * sp.d, "io"), logits=hb.alloc("io.logits", 4 * sp.V, "io"))
        self.lay = []
        for l in range(sp.L):
            p = f"L{l}."
            e = dict(g_in=self._put_vec(p + "g_in", W[f"{l}.g_in"], l),
                     g_post=self._put_vec(p + "g_post", W[f"{l}.g_post"], l),
                     qn=self._put_vec(p + "q_norm", W[f"{l}.qn"], l),
                     kn=self._put_vec(p + "k_norm", W[f"{l}.kn"], l))
            for n in ("q", "k", "v", "o"):
                e[n] = self._put_matrix(p + "W_" + n, W[f"{l}.{n}"], l)
            fc = sp.fchunk
            for f in range(sp.F // fc):
                e[f"gate{f}"] = self._put_matrix(p + f"W_gate[{f}]", W[f"{l}.gate"][f * fc:(f + 1) * fc], l)
                e[f"up{f}"] = self._put_matrix(p + f"W_up[{f}]", W[f"{l}.up"][f * fc:(f + 1) * fc], l)
                e[f"down{f}"] = self._put_matrix(p + f"W_down[:,{f}]",
                                                 W[f"{l}.down"][:, f * fc:(f + 1) * fc], l)
            for h in range(sp.Hkv):           # KV cache: K token-major, V transposed
                e[f"K{h}"] = hb.alloc(p + f"K[{h}]", self.cap * sp.d, "kv", l)
                e[f"ks{h}"] = hb.alloc(p + f"K_scale[{h}]", 4 * self.cap, "kv", l)
                e[f"Vt{h}"] = hb.alloc(p + f"Vt[{h}]", sp.d * self.cap, "kv", l)
                e[f"vs{h}"] = hb.alloc(p + f"V_scale[{h}]", 4 * self.cap, "kv", l)
            self.lay.append(e)
        self.final = self._put_vec("final_norm", W["norm"])
        self.head = self._put_matrix("LM_head (= embed)", W["embed"], -1)

    # ------------------------------------------------------------------ host side
    def rope(self, pos):
        sp = self.spec
        inv = sp.theta ** (-np.arange(0, sp.d, 2) / sp.d)
        ang = pos * inv
        return np.cos(ang).astype(F32), np.sin(ang).astype(F32)

    def host_inputs(self, token, pos):
        c, s = self.rope(pos)
        hb = self.m.hbm
        hb.write_f32(self.io["x"], self.W["embed"][token])
        hb.write_f32(self.io["cos"], c)
        hb.write_f32(self.io["sin"], s)

    def logits(self):
        return self.m.hbm.read_f32(self.io["logits"], self.spec.V).copy()

    # ------------------------------------------------------------------ compiler
    def compile_step(self, pos):
        """The program of one decode token at position pos (KV for 0..pos-1 already in HBM)."""
        sp, cfg, tm = self.spec, self.cfg, self.m.tmem
        H, d, G = sp.H, sp.d, sp.Hq // sp.Hkv
        P = []
        cur = dict(step="", layer=-1)

        def emit(ins, text):
            ins.text, ins.step, ins.layer = text, cur["step"], cur["layer"]
            P.append(ins)

        def T(name, n):
            return tm.alloc(name, n)

        act_blocks = self.act_map = {}

        def A(name, k):
            """ACT RAM block range of an operand (field ab): operands of upcoming MMs coexist."""
            if name not in act_blocks:
                act_blocks[name] = sum(v for _, v in act_blocks.values()), ceil(k / cfg.D)
                assert sum(v for _, v in act_blocks.values()) <= cfg.ACT_BLOCKS
            return act_blocks[name][0]

        def rms_stats(src, n, dst, rows=1, stride=0, what="x"):
            emit(I.VOP("rssq", dst, a=src, rows=rows, cols=n, sa=stride, sd=1),
                 f"RMSNorm {what}: Σx² по {n} элементам (VPU, редукция)")
            emit(I.VOP("mul", dst, a=dst, rows=rows, sa=1, sd=1, imm=1.0 / n),
                 f"RMSNorm {what}: ×1/{n} → среднее квадратов")
            emit(I.VOP("add", dst, a=dst, rows=rows, sa=1, sd=1, imm=sp.eps),
                 f"RMSNorm {what}: + eps")
            emit(I.VOP("rsqrt", dst, a=dst, rows=rows, sa=1, sd=1),
                 f"RMSNorm {what}: r = 1/√(…) (VPU, составная операция)")

        def mm(wpair, N, K, M, out, ors, what, **kw):
            w, s = wpair
            emit(I.MM(w, s, N, K, M, out, ors, **kw),
                 f"{what}: {N}×{K} INT8 = {N * K // 1024} KiB стримятся из HBM в MXU "
                 f"({N * K // 128} чанков по 128 B), {M} строк(и) из ACT RAM (блок {kw.get('ab', 0)}) "
                 "→ FP32 в TMEM")

        x, cos, sin = T("x", H), T("cos", d // 2), T("sin", d // 2)
        cur.update(step="входы", layer=-1)
        emit(I.LD(self.io["x"], x, H), f"x — эмбеддинг токена ({H} FP32), записанный хостом: HBM → TMEM")
        emit(I.LD(self.io["cos"], cos, d // 2), f"cos(pos·θ) для RoPE: HBM → TMEM")
        emit(I.LD(self.io["sin"], sin, d // 2), f"sin(pos·θ) для RoPE: HBM → TMEM")
        T_ = pos + 1
        for l, e in enumerate(self.lay):
            cur.update(step="RMSNorm", layer=l)
            g_in = T(f"g_in{l}", H)
            emit(I.LD(e["g_in"], g_in, H), "γ RMSNorm слоя: HBM → TMEM")
            r = T("r", 1)
            rms_stats(x, H, r)
            cur["step"] = "QACT x"
            emit(I.QACT(x, 1, H, H, rscale=r, cscale=g_in, ab=A("x_attn", H)),
                 "x·r·γ квантуется в INT8 (масштаб на строку) прямо в ACT RAM — "
                 "нормированный x в TMEM не пишется")
            cur["step"] = "Q/K/V"
            k, v, q = T("k", sp.Hkv * d), T("v", sp.Hkv * d), T("q", sp.Hq * d)
            ab = A("x_attn", H)
            mm(e["k"], sp.Hkv * d, H, 1, k, 0, "K-проекция", ab=ab)
            mm(e["v"], sp.Hkv * d, H, 1, v, 0, "V-проекция", ab=ab)
            for h in range(sp.Hkv):
                wq, sq = e["q"]
                rows = G * d
                mm((wq + h * rows * H, sq + 4 * h * rows), rows, H, 1, q + h * rows, 0,
                   f"Q-проекция группы KV-головы {h}", ab=ab)
            cur["step"] = "q/k-norm + RoPE"
            qn, kn = T(f"qn{l}", d), T(f"kn{l}", d)
            emit(I.LD(e["qn"], qn, d), "γ q-norm: HBM → TMEM")
            emit(I.LD(e["kn"], kn, d), "γ k-norm: HBM → TMEM")
            kr, qr = T("kr", sp.Hkv * d), T("qr", sp.Hq * d)
            tmp = T("rope_tmp", 4 * sp.Hq * d)
            for name, src, nh, gam, dst in (("k", k, sp.Hkv, kn, kr), ("q", q, sp.Hq, qn, qr)):
                rs = T(f"r_{name}", nh)
                rms_stats(src, d, rs, rows=nh, stride=d, what=f"{name} по головам")
                emit(I.VOP("mul", src, a=src, b=rs, rows=nh, cols=d, sa=d, sb=1, sd=d, bmode="row"),
                     f"{name}-norm: × r каждой головы")
                emit(I.VOP("mul", src, a=src, b=gam, rows=nh, cols=d, sa=d, sd=d, bmode="col"),
                     f"{name}-norm: × γ")
                h2 = d // 2
                t1, t2, t3, t4 = tmp, tmp + sp.Hq * d, tmp + 2 * sp.Hq * d, tmp + 3 * sp.Hq * d
                kw = dict(rows=nh, cols=h2, sa=d, sd=d, bmode="col")
                emit(I.VOP("mul", t1, a=src, b=cos, **kw), f"RoPE {name}: x₁·cos")
                emit(I.VOP("mul", t2, a=src + h2, b=sin, **kw), f"RoPE {name}: x₂·sin")
                emit(I.VOP("sub", dst, a=t1, b=t2, rows=nh, cols=h2, sa=d, sb=d, sd=d, bmode="full"),
                     f"RoPE {name}: первая половина = x₁cos − x₂sin")
                emit(I.VOP("mul", t3, a=src + h2, b=cos, **kw), f"RoPE {name}: x₂·cos")
                emit(I.VOP("mul", t4, a=src, b=sin, **kw), f"RoPE {name}: x₁·sin")
                emit(I.VOP("add", dst + h2, a=t3, b=t4, rows=nh, cols=h2, sa=d, sb=d, sd=d, bmode="full"),
                     f"RoPE {name}: вторая половина = x₂cos + x₁sin")
            cur["step"] = "запись KV"
            for h in range(sp.Hkv):
                emit(I.QST(kr + h * d, d, e[f"K{h}"] + pos * d, e[f"ks{h}"] + 4 * pos),
                     f"K головы {h}, позиция {pos}: INT8 + FP32-масштаб → HBM (строка {d} B)")
                emit(I.QST(v + h * d, d, e[f"Vt{h}"] + pos, e[f"vs{h}"] + 4 * pos, stride=self.cap),
                     f"V головы {h}, позиция {pos}: INT8 в столбец Vᵀ — {d} байт, каждый в своём beat (RMW)")
            att = T("att", sp.Hq * d)
            S, Pb = T("S", G * sp.block), T("P", G * sp.block)
            for h in range(sp.Hkv):
                cur["step"] = f"attention, KV-голова {h}"
                m_, mn, rm, al = T("m", G), T("mnew", G), T("rmax", G), T("alpha", G)
                l_, ps, acc, il = T("l", G), T("psum", G), T("acc", G * d), T("il", G)
                vsb = T("vs_blk", sp.block)
                emit(I.QACT(qr + h * G * d, G, d, d, imm=LOG2E / sqrt(d), ab=A(f"q{h}", d)),
                     f"q голов {G * h}..{G * h + G - 1} · log₂e/√d → INT8 в ACT RAM ({G} строки)")
                emit(I.VOP("fill", m_, rows=G, sd=1, imm=-1e30), "m = −∞ (максимум онлайн-softmax)")
                emit(I.VOP("fill", l_, rows=G, sd=1, imm=0.0), "l = 0 (сумма онлайн-softmax)")
                emit(I.VOP("fill", acc, rows=G, cols=d, sd=d, imm=0.0), "acc = 0 (накопитель P·V)")
                for b in range(ceil(T_ / sp.block)):
                    n = min(sp.block, T_ - b * sp.block)
                    kp = ceil(n / 128) * 128
                    t0 = b * sp.block
                    emit(I.MM(e[f"K{h}"] + t0 * d, e[f"ks{h}"] + 4 * t0, n, d, G, S, sp.block, rmax=rm,
                              ab=A(f"q{h}", d)),
                         f"скоры s = q·Kᵀ, блок {b} ({n} токенов): строки K-кэша стримятся из HBM "
                         f"как веса, масштабы K через порт A; + максимум строки (RMAX)")
                    emit(I.VOP("max", mn, a=m_, b=rm, rows=G, sa=1, sb=1, sd=1, bmode="full"),
                         "m' = max(m, max s)")
                    emit(I.VOP("exp2sub", Pb, a=S, b=mn, rows=G, cols=n, sa=sp.block, sb=1,
                               sd=sp.block, bmode="row"), "p = 2^(s − m') (VPU, составная)")
                    emit(I.VOP("exp2sub", al, a=m_, b=mn, rows=G, sa=1, sb=1, sd=1, bmode="full"),
                         "α = 2^(m − m') — поправка прежних сумм")
                    if kp > n:
                        emit(I.VOP("fill", Pb + n, rows=G, cols=kp - n, sd=sp.block, imm=0.0),
                             f"p дополняется нулями до {kp} (целые блоки по 128)")
                    emit(I.LD(e[f"vs{h}"] + 4 * t0, vsb, kp), "масштабы V токенов блока: HBM → TMEM")
                    emit(I.VOP("rsum", ps, a=Pb, rows=G, cols=n, sa=sp.block, sd=1), "Σp по блоку")
                    pab = A(f"P{b % 2}", sp.block)
                    emit(I.QACT(Pb, G, kp, sp.block, cscale=vsb, ab=pab),
                         "p·(масштаб V токена) → INT8 в ACT RAM: масштабы V свёрнуты в P")
                    emit(I.MM(e[f"Vt{h}"] + t0, 0, d, kp, G, acc, d, ascale=al, unit=True,
                              wrs=self.cap, ab=pab),
                         f"acc = acc·α + P·Vᵀ: {d} строк Vᵀ по {kp} токенов стримятся из HBM; "
                         "α применяется в эпилоге MXU (ASCALE)")
                    emit(I.VOP("mul", l_, a=l_, b=al, rows=G, sa=1, sb=1, sd=1, bmode="full"), "l = l·α")
                    emit(I.VOP("add", l_, a=l_, b=ps, rows=G, sa=1, sb=1, sd=1, bmode="full"), "l = l + Σp")
                    emit(I.VOP("copy", m_, a=mn, rows=G, sa=1, sd=1), "m = m'")
                emit(I.VOP("recip", il, a=l_, rows=G, sa=1, sd=1), "1/l")
                emit(I.VOP("mul", att + h * G * d, a=acc, b=il, rows=G, cols=d, sa=d, sb=1, sd=d,
                           bmode="row"), f"o = acc/l → выход голов {G * h}..{G * h + G - 1}")
            cur["step"] = "O-проекция"
            y = T("y", H)
            emit(I.QACT(att, 1, sp.Hq * d, sp.Hq * d, ab=A("att", sp.Hq * d)),
                 "выход attention → INT8 в ACT RAM")
            mm(e["o"], H, sp.Hq * d, 1, y, 0, "O-проекция", ab=A("att", sp.Hq * d))
            emit(I.VOP("add", x, a=x, b=y, cols=H, bmode="col"), "residual: x = x + attention")
            cur["step"] = "RMSNorm MLP"
            g_post = T(f"g_post{l}", H)
            emit(I.LD(e["g_post"], g_post, H), "γ RMSNorm перед MLP: HBM → TMEM")
            rms_stats(x, H, r)
            emit(I.QACT(x, 1, H, H, rscale=r, cscale=g_post, ab=A("x_mlp", H)), "x·r·γ → INT8 в ACT RAM")
            fc = sp.fchunk
            for f in range(sp.F // fc):
                cur["step"] = f"MLP, кусок {f}"
                g, u, hh = T(f"gate{f}", fc), T(f"up{f}", fc), T(f"h{f}", fc)
                s1 = T(f"silu{f}", fc)
                mm(e[f"gate{f}"], fc, H, 1, g, 0, f"gate, кусок {f}", ab=A("x_mlp", H))
                mm(e[f"up{f}"], fc, H, 1, u, 0, f"up, кусок {f}", ab=A("x_mlp", H))
                emit(I.VOP("mul", s1, a=g, cols=fc, imm=-LOG2E), "SiLU: t = −g·log₂e")
                emit(I.VOP("exp2", s1, a=s1, cols=fc), "SiLU: 2^t = e^(−g)")
                emit(I.VOP("add", s1, a=s1, cols=fc, imm=1.0), "SiLU: 1 + e^(−g)")
                emit(I.VOP("recip", s1, a=s1, cols=fc), "SiLU: σ(g) = 1/(1 + e^(−g))")
                emit(I.VOP("mul", s1, a=g, b=s1, cols=fc, bmode="col"), "SiLU: g·σ(g)")
                emit(I.VOP("mul", hh, a=s1, b=u, cols=fc, bmode="col"), "SwiGLU: h = SiLU(g)·up")
                emit(I.QACT(hh, 1, fc, fc, ab=A(f"h{f}", fc)), "h → INT8 в ACT RAM")
                mm(e[f"down{f}"], H, fc, 1, y, 0, f"down, кусок {f}" + (" (+ACC к y)" if f else ""),
                   acc=f > 0, ab=A(f"h{f}", fc))
            emit(I.VOP("add", x, a=x, b=y, cols=H, bmode="col"), "residual: x = x + MLP")
        cur.update(step="LM head", layer=-1)
        gf, r = T("g_final", H), T("r", 1)
        emit(I.LD(self.final, gf, H), "γ финальной нормы: HBM → TMEM")
        rms_stats(x, H, r)
        emit(I.QACT(x, 1, H, H, rscale=r, cscale=gf, ab=A("x_head", H)), "x·r·γ → INT8 в ACT RAM")
        lg = T("logits", sp.V)
        mm(self.head, sp.V, H, 1, lg, 0, "LM head (словарь)", ab=A("x_head", H))
        emit(I.ST(lg, self.io["logits"], sp.V), f"логиты ({sp.V} FP32): TMEM → HBM, их читает хост")
        emit(I.HALT(), "HALT: окно пусто → STATUS.HALTED")
        return P
