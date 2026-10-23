#!/usr/bin/env python3
"""Учебная потактовая симуляция одного токена openTPU (конфигурация VCU128) на Python.

    python3 run.py                 # pos 8: рассказ, графики out/*.png, out/player.html
    python3 run.py --pos 300       # длинный контекст: два блока attention, онлайн-softmax
    python3 run.py --narrate 400   # подробный рассказ по каждой инструкции

Нужны только numpy и matplotlib. Токены 0..pos-1 исполняются функционально (без тактов),
токен pos — потактово; результат сверяется с эталоном float64 (reference.py).
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from otpusim import Config, Model, Spec          # noqa: E402
from otpusim import reference, report            # noqa: E402

LENS_QWEN_TINY_POS8 = 20135     # sim/lens: upstream RTL, VCU128 config, 20.10.2026


def simulate(pos: int, seed: int = 1):
    cfg, sp = Config(), Spec()
    cap = max(256, -(-(pos + 1) // 256) * 256)
    md = Model(cfg, sp, cap)
    md.pos = pos
    toks = [int(t) for t in np.random.default_rng(seed).integers(0, sp.V, pos + 1)]
    for p, t in enumerate(toks[:-1]):
        md.host_inputs(t, p)
        md.m.run_functional(md.compile_step(p))
    md.host_inputs(toks[-1], pos)
    prog = md.compile_step(pos)
    probe = report.Probe()
    res = md.m.run(prog, observer=probe)
    ref = reference.logits(sp, md.W, toks)
    return md, prog, res, probe, ref, toks


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pos", type=int, default=8, help="позиция токена (длина attention = pos+1)")
    ap.add_argument("--out", default=str(HERE / "out"))
    ap.add_argument("--narrate", type=int, default=40, help="сколько инструкций рассказать")
    ap.add_argument("--no-figures", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    t0 = time.time()
    md, prog, res, probe, ref, toks = simulate(a.pos)
    lg = md.logits()
    cos = float(lg @ ref / np.linalg.norm(lg) / np.linalg.norm(ref))
    top = len(set(np.argsort(-lg)[:5]) & set(np.argsort(-ref)[:5]))
    cyc = res["cycles"]
    print(f"Токен pos {a.pos} (id {toks[-1]}): {len(prog)} инструкций, {cyc:,} тактов = "
          f"{cyc / md.cfg.core_mhz:.1f} мкс при {md.cfg.core_mhz:g} МГц  [{time.time() - t0:.1f} с]")
    if a.pos == 8:
        print(f"RTL upstream (Lens, qwen-tiny pos 8): {LENS_QWEN_TINY_POS8:,} тактов → "
              f"расхождение {100 * (cyc / LENS_QWEN_TINY_POS8 - 1):+.1f} %")
    print(f"Логиты против float64: косинус {cos:.5f}, топ-5 совпало {top}/5, "
          f"argmax {int(np.argmax(lg))} / эталон {int(np.argmax(ref))}\n")
    print(report.narrate(prog, res, a.narrate))
    print("\nАлгоритмы на живых числах:\n" + report.explain_examples(probe))

    data = report.player_data(md, prog, res, probe, ref)
    data["check"] = dict(cos=cos, top5=top, lens=LENS_QWEN_TINY_POS8 if a.pos == 8 else None)
    (out / "trace.json").write_text(json.dumps(data, ensure_ascii=False))
    report.write_html(data, HERE / "player.html", out / "player.html")
    if not a.no_figures:
        files = report.figures(md, prog, res, probe, ref, out,
                               LENS_QWEN_TINY_POS8 if a.pos == 8 else None)
        print("\nГрафики: " + ", ".join(str(out / f) for f in files))
    print(f"Плеер: {out / 'player.html'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
