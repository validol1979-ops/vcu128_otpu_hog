"""Number formats of the slice, simplified: INT8 codes with one FP32 scale per row.

Upstream adds 5-bit power-of-two offsets per 32-element group (MX numerics, docs/quant.md);
they are left out here so the algorithm stays readable. Everything else follows the RTL:
exact integer accumulation in the MXU, then one FP32 epilogue y = acc * Sw[n] * Sa[j]."""
import numpy as np

F32 = np.float32


def rne(x: np.ndarray) -> np.ndarray:
    """Round to nearest, ties to even (numpy's rint)."""
    return np.rint(x)


def quantize_rows(x: np.ndarray):
    """INT8 codes and per-row scales: scale = max|x| / 127, code = rne(x / scale)."""
    x = np.atleast_2d(np.asarray(x, F32))
    m = np.max(np.abs(x), axis=1)
    scale = np.where(m > 0, m / F32(127), F32(1)).astype(F32)
    codes = np.clip(rne(x / scale[:, None]), -127, 127).astype(np.int8)
    return codes, scale


def dequantize(codes, scale):
    return codes.astype(F32) * np.asarray(scale, F32)[:, None]


def mm_int8(a_codes, a_scale, w_codes, w_scale):
    """MXU: out[j, n] = (sum_k a[j,k] * w[n,k]) * Sw[n] * Sa[j]; the sum is an exact integer."""
    acc = a_codes.astype(np.int32) @ w_codes.astype(np.int32).T
    return (acc.astype(F32) * w_scale[None, :].astype(F32)) * a_scale[:, None].astype(F32), acc
