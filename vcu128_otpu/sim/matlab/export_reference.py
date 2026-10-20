"""Regenerate portable JSON vectors using the locally pinned upstream, without a board."""
import hashlib
import json
from pathlib import Path
import subprocess
import numpy as np
from opentpu import fp32 as F
from opentpu import quant as Q
from opentpu.isa import MX_W, W8

root = Path(__file__).resolve().parent
rng = np.random.default_rng(217)
cases = []
for name in ('normal', 'dynamic', 'zero', 'rounding_ftz'):
    a = rng.standard_normal((4, 256)).astype(np.float32)
    w = rng.standard_normal((7, 256)).astype(np.float32)
    if name == 'dynamic':
        a[:, 32:128] *= np.float32(2.0**-20)
        w[:, 128:] *= np.float32(2.0**-12)
    if name == 'zero':
        a[0] = 0
        w[0] = 0
    if name == 'rounding_ftz':
        edge = np.array([127, -127, .5, 1.5, 2.5, -.5, -1.5, -2.5], np.float32)
        a = np.tile(edge, (4, 32))
        w = np.tile(edge[::-1], (7, 32))
        a[1] *= np.float32(2.0**-120)
        a[2] *= np.float32(2.0**120)
        a[3] = np.nextafter(np.float32(0), np.float32(1))
    aq, sa, da = F.quantize_mx(a, 32)
    wq, sw, dw = F.quantize_mx(w, 128)
    # Same group equations as isasim.ISASim._mm (no PAIR, ACC, or RSC).
    acc = np.zeros((len(a), len(w)), np.int64)
    for g in range(8):
        c = aq[:, g*32:(g+1)*32].astype(np.int64) @ wq[:, g*32:(g+1)*32].astype(np.int64).T
        shift = MX_W[W8] - da[:, g].astype(np.int64)[:, None] - dw[:, g//4].astype(np.int64)[None, :]
        acc += c * np.where(shift >= 0, 1 << np.maximum(shift, 0), 0)
    out = F.mul(F.mul(F.i2f(acc), sw[None, :]), F.mul(sa[:, None], np.float32(2.0**-16)))
    # Also exercise upstream's public quantizer/storage path.
    wr, sr = Q.quantize_mxu(w, 'int8', 128)
    assert np.array_equal(Q.elements(wr, 'int8', 256), wq)
    cases.append(dict(name=name, a=a.tolist(), w=w.tolist(), aq=aq.tolist(), wq=wq.tolist(),
                      sa_bits=sa.view(np.uint32).tolist(), sw_bits=sw.view(np.uint32).tolist(),
                      da=da.tolist(), dw=dw.tolist(), acc=acc.tolist(), out_bits=out.view(np.uint32).tolist()))
source = Path(F.__file__).resolve().parents[1]
meta = dict(upstream_sha=subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip(),
            sources={str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in (Path(F.__file__), Path(Q.__file__), source/'opentpu/isasim.py')}, cases=cases)
(root/'fixtures/int8_mx.json').write_text(json.dumps(meta, separators=(',', ':'))+'\n')
print(f'Exported {len(cases)} upstream reference cases')
