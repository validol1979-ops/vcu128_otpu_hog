#!/usr/bin/env python3
"""Readable account of a Lens profile: every dynamic instruction with its unit, data path,
timing and source line, grouped by model step; plus the totals by data path.

    python3 explain.py run.otpuprof [-o run.md] [--csv run.csv] [--limit N]

Only the profile file is read (gzip JSON, upstream docs/lens.md); the upstream package is not
needed. Paths are named as on the VCU128: DRAM = the slice's two HBM channels.
"""
import argparse
import csv
import gzip
import json
from collections import Counter, defaultdict
from pathlib import Path

UNITS = ["DMA", "MXU", "QUANT", "VPU", "COLL"]
# data path of each opcode (upstream docs/isa.md, rtl/top/otpu_slice.sv)
PATHS = {
    "LD": "HBM → DMA → TMEM",
    "ST": "TMEM → DMA → HBM",
    "MM": "HBM (веса / K / Vᵀ) → MXU ← ACT RAM; MXU → TMEM",
    "QACT": "TMEM → QUANT → ACT RAM",
    "QST": "TMEM → QUANT → HBM (запись KV / состояния)",
    "VOP": "TMEM → VPU → TMEM",
    "DSTEP": "HBM → DMA → SE (VPU) → HBM",
    "STREAM": "HBM → DMA → SE (VPU) → HBM",
    "WAITW": "HBM → DMA → TMEM (опрос слова)",
    "RLD": "TMEM → COLL → регистр SEQ",
    "BAR": "барьер слайсов",
    "GATHER": "TMEM → COLL → TMEM",
}
# what a source function does in model terms
STEPS = {
    "_inputs": "входы токена (x, cos, sin)", "rmsnorm": "RMSNorm", "rope": "RoPE",
    "_attention": "attention: проекции Q/K/V/O", "_scores": "attention: q·Kᵀ",
    "_finish": "attention: softmax / P·V", "_attend_heads": "attention", "__init__": "attention",
    "_mlp": "MLP (gate/up/down)", "gate_up": "MLP gate/up", "swiglu_down": "MLP SiLU·up, down",
    "sigmoid": "SiLU (сигмоида)", "_conv": "LFM2 short-conv", "_head": "LM head",
    "_logits": "LM head", "lm_head": "LM head", "_lm_head": "LM head", "silu": "SiLU (сигмоида)",
    "emit": "запись KV в HBM (QST)", "_rope_padded": "RoPE", "_padded": "RoPE",
    "_load_opt": "загрузка норм / масштабов",
}


def step_of(s: dict) -> str:
    """The innermost source function of the call chain that names a model step."""
    funcs = [s.get("func", "")] + [c.split()[-1] for c in s.get("chain", [])]
    return next((STEPS[f] for f in funcs if f in STEPS), s.get("func", ""))


def path_of(name: str, detail: str) -> str:
    op = name.split(".")[0]
    p = PATHS.get(op, "")
    if op == "MM" and "+acc" in detail:
        p += " (+ чтение TMEM: ACC)"
    return p


def load(path):
    raw = Path(path).read_bytes()
    doc = json.loads(gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw)
    assert doc.get("format") == "openTPU-profile", "not a Lens profile"
    return doc["profiles"][0]


def rows(p):
    src = p["sources"]
    seen = Counter()
    for ins in p["instrs"]:
        sl, idx, pc, unit, name, detail, disp, ready, rel, start, end, si = ins[:12]
        port_b, port_a = ins[14], ins[15]
        seen[pc] += 1
        s = src[si] if isinstance(si, int) and 0 <= si < len(src) else {}
        yield dict(n=idx, pc=pc, rep=seen[pc], unit=UNITS[unit] if unit < len(UNITS) else unit,
                   op=name, detail=detail, dispatch=disp, start=start, end=end,
                   busy=end - start, wait=start - disp, port_b=port_b, port_a=port_a,
                   path=path_of(name, detail), step=step_of(s),
                   source=f"{Path(s.get('file', '')).name}:{s.get('line', '')}",
                   text=s.get("text", "").strip())


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("profile")
    ap.add_argument("-o", "--out", help="Markdown output (default: stdout)")
    ap.add_argument("--csv", help="one CSV row per dynamic instruction")
    ap.add_argument("--limit", type=int, default=0, help="list only the first N instructions")
    a = ap.parse_args()
    p = load(a.profile)
    rs = list(rows(p))
    mhz = p.get("clock_mhz", 100)
    out = [f"# {p['name']}", "",
           f"RTL-профиль Lens: {p['cycles']:,} тактов = {p['cycles'] / mhz:.1f} мкс при "
           f"{mhz:g} МГц, {len(rs)} инструкций. Конфигурация: "
           + ", ".join(f"{k}={v}" for k, v in p["config"].items()) + ".", ""]
    eff = p.get("roofline", {}).get("efficiency")
    if eff is not None:
        out += [f"Доля от предела по памяти (roofline): {100 * eff:.1f} %.", ""]
    # totals by data path
    by = defaultdict(lambda: [0, 0, 0])
    for r in rs:
        t = by[r["path"] or r["op"]]
        t[0] += 1
        t[1] += r["busy"]
        t[2] += r["port_b"]
    out += ["## Пути данных", "", "| Путь | Инструкций | Занято тактов (сумма) | Порт B, чанков 128 B |",
            "|---|---:|---:|---:|"]
    for k, (n, busy, pb) in sorted(by.items(), key=lambda kv: -kv[1][1]):
        out.append(f"| {k} | {n} | {busy:,} | {pb:,} |")
    # totals by model step: what the DRAM stream is spent on
    st = defaultdict(lambda: [0, 0, 0])
    for r in rs:
        t = st[r["step"]]
        t[0] += 1
        t[1] += r["busy"] if r["unit"] == "MXU" else 0
        t[2] += r["port_b"]
    total_b = sum(t[2] for t in st.values()) or 1
    out += ["", "## Шаги модели: итоги", "",
            "| Шаг | Инструкций | MXU занят, тактов | Прочитано портом B | Доля потока |",
            "|---|---:|---:|---:|---:|"]
    for k, (n, mxu, pb) in sorted(st.items(), key=lambda kv: -kv[1][2]):
        out.append(f"| {k} | {n} | {mxu:,} | {pb * 128 / 2**20:.2f} МиБ | "
                   f"{100 * pb / total_b:.1f} % |")
    # steps in program order (consecutive instructions of one step collapsed)
    out += ["", "## Шаги модели по порядку диспетчеризации", "",
            "| # | Шаг | Инструкции | Начало | Конец |", "|---:|---|---|---:|---:|"]
    groups = []
    for r in rs:
        if groups and groups[-1]["step"] == r["step"]:
            g = groups[-1]
        else:
            g = dict(step=r["step"], ops=Counter(), start=r["start"], end=r["end"])
            groups.append(g)
        g["ops"][r["op"]] += 1
        g["start"], g["end"] = min(g["start"], r["start"]), max(g["end"], r["end"])
    for i, g in enumerate(groups, 1):
        ops = ", ".join(f"{k}×{v}" if v > 1 else k for k, v in g["ops"].items())
        out.append(f"| {i} | {g['step']} | {ops} | {g['start']:,} | {g['end']:,} |")
    lim = rs[:a.limit] if a.limit else rs
    out += ["", "## Инструкции", "",
            "Ожидание = старт − диспетчеризация (зависимости по табло или занятый блок).", "",
            "| # | Блок | Операция | Размер | Старт | Тактов | Ожидание | Путь | Исходник |",
            "|---:|---|---|---|---:|---:|---:|---|---|"]
    for r in lim:
        out.append(f"| {r['n']} | {r['unit']} | {r['op']} | {r['detail']} | {r['start']:,} | "
                   f"{r['busy']:,} | {r['wait']:,} | {r['path']} | `{r['source']}` {r['step']} |")
    if a.limit and len(rs) > a.limit:
        out.append(f"\n… ещё {len(rs) - a.limit} инструкций (полный список — `--csv`).")
    text = "\n".join(out) + "\n"
    if a.out:
        Path(a.out).write_text(text)
    else:
        print(text, end="")
    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rs[0]))
            w.writeheader()
            w.writerows(rs)


if __name__ == "__main__":
    main()
