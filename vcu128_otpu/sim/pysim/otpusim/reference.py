"""Float64 reference of the same Qwen3 (no quantization): what the slice approximates."""
import numpy as np


def _rms(x, g, eps):
    return x / np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + eps) * g


def _rope(x, pos, d, theta):
    inv = theta ** (-np.arange(0, d, 2) / d)
    c, s = np.cos(pos * inv), np.sin(pos * inv)
    x1, x2 = x[..., : d // 2], x[..., d // 2:]
    return np.concatenate([x1 * c - x2 * s, x2 * c + x1 * s], axis=-1)


def logits(spec, W, tokens):
    """Logits after the last of `tokens` (positions 0..len-1), float64."""
    H, d, G = spec.H, spec.d, spec.Hq // spec.Hkv
    K = [[] for _ in range(spec.L)]
    V = [[] for _ in range(spec.L)]
    for pos, tok in enumerate(tokens):
        x = W["embed"][tok].astype(np.float64)
        for l in range(spec.L):
            w = lambda n: W[f"{l}.{n}"].astype(np.float64)   # noqa: E731
            z = _rms(x, w("g_in"), spec.eps)
            q = (w("q") @ z).reshape(spec.Hq, d)
            k = (w("k") @ z).reshape(spec.Hkv, d)
            v = (w("v") @ z).reshape(spec.Hkv, d)
            q = _rope(_rms(q, w("qn"), spec.eps), pos, d, spec.theta)
            k = _rope(_rms(k, w("kn"), spec.eps), pos, d, spec.theta)
            K[l].append(k)
            V[l].append(v)
            Ks, Vs = np.stack(K[l], 1), np.stack(V[l], 1)          # [Hkv, T, d]
            o = np.zeros((spec.Hq, d))
            for h in range(spec.Hq):
                kv = h // G
                s = Ks[kv] @ q[h] / np.sqrt(d)
                p = np.exp(s - s.max())
                o[h] = (p / p.sum()) @ Vs[kv]
            x = x + w("o") @ o.ravel()
            z = _rms(x, w("g_post"), spec.eps)
            g, u = w("gate") @ z, w("up") @ z
            x = x + w("down") @ (g / (1 + np.exp(-g)) * u)
    z = _rms(x, W["norm"].astype(np.float64), spec.eps)
    return W["embed"].astype(np.float64) @ z
