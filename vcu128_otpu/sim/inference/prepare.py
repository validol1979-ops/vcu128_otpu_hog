#!/usr/bin/env python3
"""Export the MATLAB/Octave tensor trace for Questa and an offline SVG player."""
import csv
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
NAMES = ['HBM: веса / KV', 'TMEM: FP32', 'QUANT: QACT / QST', 'ACT RAM: INT8', 'MXU: MM', 'VPU: VOP']


def route(op):
    """Same as ../matlab/+otpu/flow_route.m (0-based): upstream otpu_slice paths."""
    if op == 'embedding':
        return [0, 1]                       # LD: HBM -> DMA -> TMEM
    if op == 'logits_store':
        return [1, 0]                       # ST: TMEM -> DMA -> HBM
    if op == 'kv_write':
        return [1, 2, 0]                    # QST: TMEM -> QUANT -> HBM
    if op.endswith('_qact'):
        return [1, 2, 3]                    # QACT: TMEM -> QUANT -> ACT
    if op in ('q', 'k', 'v', 'o', 'gate', 'up', 'down', 'lm_head', 'attn_scores', 'attn_pv'):
        return [0, 4, 1]                    # MM: HBM -> MXU -> TMEM (+ ACT -> MXU)
    return [1, 5, 1]                        # VOP: TMEM -> VPU -> TMEM


def main():
    out = HERE / 'out'
    out.mkdir(exist_ok=True)
    with (HERE.parent / 'matlab/out/llm_trace.csv').open() as f:
        events = list(csv.DictReader(f))
    assert events, 'Empty numerical trace'
    previous = 0
    with (out / 'llm_events.txt').open('w') as f:
        for e in events:
            for key in ('token', 'layer', 'read_bytes', 'write_bytes'):
                e[key] = int(e[key])
            for key in ('start_s', 'finish_s', 'memory_s', 'compute_s', 'ops'):
                e[key] = float(e[key])
            assert e['start_s'] >= previous - 1e-12 and e['finish_s'] >= e['start_s']
            previous = e['finish_s']
            e['route'] = route(e['op'])
            f.write(f"{e['token']} {e['layer']} {e['op']} {e['route'][0]} {e['route'][-1]} "
                    f"{e['read_bytes']} {e['write_bytes']} {e['start_s']*1e9:.6f} {e['finish_s']*1e9:.6f}\n")
    template = (HERE / 'player.html').read_text()
    html = template.replace('/*EVENT_DATA*/[]', json.dumps(events)).replace('/*NODE_NAMES*/[]', json.dumps(NAMES))
    (out / 'llm_flow.html').write_text(html)
    print(f'{len(events)} events; {previous*1e6:.3f} us modeled; {out / "llm_flow.html"}')


if __name__ == '__main__':
    main()
