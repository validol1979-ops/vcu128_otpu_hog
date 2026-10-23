"""Pictures and text from a simulated token: matplotlib figures, the player's JSON, narration."""
import json
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

from .isa import PATHS

UNIT_ROWS = ["DMA", "MXU поток", "MXU счёт", "QUANT", "VPU"]
STEP_COLORS = {
    "входы": "#868e96", "RMSNorm": "#4dabf7", "QACT x": "#ffa94d", "Q/K/V": "#2f9e44",
    "q/k-norm + RoPE": "#74c0fc", "запись KV": "#e8590c", "attention": "#ae3ec9",
    "O-проекция": "#37b24d", "RMSNorm MLP": "#4dabf7", "MLP": "#099268", "LM head": "#c92a2a",
}
BLOCKS = {  # floorplan: name -> (x, y, w, h), y up
    "HBM": (0.2, 2.2, 2.2, 3.4), "PORTSW": (3.0, 5.7, 1.0, 0.6), "PORTB": (3.0, 4.3, 1.0, 0.6),
    "PORTA": (3.0, 3.2, 1.0, 0.6), "DMA": (4.6, 1.5, 1.6, 0.8), "MXU": (6.6, 3.0, 1.8, 1.4),
    "ACT": (6.6, 4.8, 1.8, 0.8), "QUANT": (9.2, 5.5, 1.6, 0.8), "TMEM": (9.2, 2.6, 1.6, 1.8),
    "VPU": (9.2, 0.4, 1.6, 0.9), "SEQ": (4.4, 0.2, 2.4, 0.9),
}
LABELS = {"HBM": "HBM\n2 канала", "PORTB": "порт B\n128 B/такт", "PORTA": "порт A\nмасштабы",
          "PORTSW": "порт SW\nQST", "DMA": "DMA", "MXU": "MXU\n4 колонки × 128\nFIFO 1024",
          "ACT": "ACT RAM\nINT8", "QUANT": "QUANT", "VPU": "VPU\n8 полос FP32",
          "TMEM": "TMEM\n64K FP32\n8 банков", "SEQ": "SEQ\nокно 16"}


def step_group(step: str) -> str:
    for k in STEP_COLORS:
        if step.startswith(k):
            return k
    return step


class Probe:
    """Observer: keeps attention probabilities and the first worked example of each op."""

    def __init__(self):
        self.att = defaultdict(list)       # (layer, kv head) -> [p rows per block]
        self.examples = {}

    def probs(self, key):
        """p of all blocks rescaled to the final running max (as the alphas do), normalized."""
        blocks = self.att[key]
        m_last = blocks[-1][1]
        p = np.concatenate([pb * np.exp2(mb - m_last)[:, None] for pb, mb in blocks], axis=1)
        return p / p.sum(axis=1, keepdims=True)

    def __call__(self, ins, info, m):
        if ins.op == "VOP" and ins.text.startswith("p = 2^"):
            a = ins.a
            t = m.tmem.mem
            rows = [t[a["dst"] + r * a["sd"]: a["dst"] + r * a["sd"] + a["cols"]].copy()
                    for r in range(a["rows"])]
            mx = np.array([t[a["b"] + r * a["sb"]] for r in range(a["rows"])])
            self.att[(ins.layer, ins.step)].append((np.stack(rows), mx))
        key = ins.name if ins.op != "MM" else ("MM K" if "q·Kᵀ" in ins.text else
                                               "MM V" if "P·Vᵀ" in ins.text else "MM")
        if "example" in info and key not in self.examples:
            self.examples[key] = dict(text=ins.text, layer=ins.layer, **info["example"])


def path_totals(prog, res):
    """Bytes moved on each floorplan edge during the token."""
    tot = Counter()
    for ins in prog:
        inf = res["info"].get(ins.id, {})
        a = ins.a
        if ins.op == "MM":
            b = {("HBM", "PORTB"): a["N"] * a["K"], ("PORTB", "MXU"): a["N"] * a["K"],
                 ("HBM", "PORTA"): 0 if a["unit"] else 4 * a["N"],
                 ("PORTA", "MXU"): 0 if a["unit"] else 4 * a["N"],
                 ("ACT", "MXU"): a["M"] * a["K"], ("MXU", "TMEM"): 4 * a["M"] * a["N"]}
        elif ins.op in ("LD", "ST"):
            b = {e: 4 * a["n"] for e in PATHS[ins.op]}
        elif ins.op == "QACT":
            b = {("TMEM", "QUANT"): 4 * a["M"] * a["K"], ("QUANT", "ACT"): a["M"] * a["K"]}
        elif ins.op == "QST":
            b = {("TMEM", "QUANT"): 4 * a["n"], ("QUANT", "PORTSW"): a["n"] + 4,
                 ("PORTSW", "HBM"): inf.get("hbm_write", a["n"])}
        elif ins.op == "VOP":
            e = a["rows"] * a["cols"]
            b = {("TMEM", "VPU"): 4 * e, ("VPU", "TMEM"): 4 * e}
        else:
            b = {}
        tot.update(b)
    return tot


def unit_intervals(prog, res):
    """(row, start, end, step, ins) bars for the Gantt chart."""
    out = []
    for ins in prog:
        r = res["rec"][ins.id]
        if r["start"] is None or ins.op == "HALT":
            continue
        g = step_group(ins.step)
        if ins.op == "MM":
            out.append(("MXU поток", r["start"], r["release"], g, ins))
            out.append(("MXU счёт", r["release"], r["end"], g, ins))
        else:
            out.append((ins.unit, r["start"], r["end"], g, ins))
    return out


def _fmt_bytes(b):
    return f"{b / 2**20:.2f} МиБ" if b >= 2**20 else f"{b / 1024:.1f} КиБ" if b >= 1024 else f"{b} B"


def figures(md, prog, res, probe, ref_logits, outdir: Path, lens_cycles=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import FancyArrowPatch, FancyBboxPatch, Patch

    outdir.mkdir(parents=True, exist_ok=True)
    cfg, cyc, bk = md.cfg, res["cycles"], res["bucket"]
    files = []

    def save(fig, name):
        fig.savefig(outdir / name, dpi=110, bbox_inches="tight")
        plt.close(fig)
        files.append(name)

    # 1. floorplan with traffic
    tot = path_totals(prog, res)
    fig, ax = plt.subplots(figsize=(12, 6.6))
    ax.set_xlim(0, 11.2), ax.set_ylim(0, 6.6), ax.axis("off")
    colors = {"HBM": "#ffe3d6", "PORTB": "#ffe3d6", "PORTA": "#ffe3d6", "PORTSW": "#ffe3d6",
              "TMEM": "#dff0ff", "ACT": "#fff4d6", "SEQ": "#f0e6ff"}
    for n, (x, y, w, h) in BLOCKS.items():
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.05",
                                    fc=colors.get(n, "#eef3f8"), ec="#396484", lw=1.5))
        ax.text(x + w / 2, y + h / 2, LABELS[n], ha="center", va="center", fontsize=9)
    mx = max(tot.values())
    ecol = {"MXU": "#d77b12", "QUANT": "#2b8a3e", "VPU": "#1971c2", "DMA": "#555555"}
    for (s, t), b in tot.items():
        if b == 0:
            continue
        x0, y0, w0, h0 = BLOCKS[s]
        x1, y1, w1, h1 = BLOCKS[t]
        p0, p1 = np.array([x0 + w0 / 2, y0 + h0 / 2]), np.array([x1 + w1 / 2, y1 + h1 / 2])
        col = next((c for k, c in ecol.items() if k in (s, t)), "#396484")
        lw = 1 + 9 * (b / mx) ** 0.5
        rad = 0.15 if (t, s) in tot else 0.0
        ax.add_patch(FancyArrowPatch(p0, p1, arrowstyle="-|>", mutation_scale=14, lw=lw,
                                     color=col, alpha=0.75, shrinkA=28, shrinkB=28,
                                     connectionstyle=f"arc3,rad={rad}"))
        mid = (p0 + p1) / 2 + (np.array([0.0, 0.18]) if rad else 0)
        ax.text(*mid, _fmt_bytes(b), fontsize=7.5, ha="center",
                bbox=dict(fc="white", ec="none", alpha=0.8, pad=0.5))
    ax.set_title(f"Пути данных за один токен (pos {md.pos}): толщина ∝ √байт", fontsize=12)
    save(fig, "01_floorplan_traffic.png")

    # 2. Gantt
    bars = unit_intervals(prog, res)

    def gantt(ax, lo, hi, title):
        for row, s, e, g, ins in bars:
            if e is None or e < lo or s > hi:
                continue
            y = UNIT_ROWS.index(row)
            ax.barh(y, e - s, left=s, height=0.7, color=STEP_COLORS.get(g, "#adb5bd"),
                    edgecolor="white", linewidth=0.3)
        ax.set_yticks(range(len(UNIT_ROWS)), UNIT_ROWS)
        ax.invert_yaxis()
        ax.set_xlim(lo, hi)
        ax.set_xlabel("такт (100 МГц)")
        ax.set_title(title, fontsize=11)
        ax.grid(axis="x", alpha=0.3)

    fig, axs = plt.subplots(2, 1, figsize=(14, 7.5))
    gantt(axs[0], 0, cyc, f"Весь токен: {cyc:,} тактов = {cyc / cfg.core_mhz:.1f} мкс")
    l0 = [r for r in bars if r[4].layer == 0 and r[3] == "attention"]
    lo = min(r[1] for r in l0) - 200
    hi = max(r[2] for r in l0) + 200
    gantt(axs[1], lo, hi, "Крупно: attention слоя 0 (поток K/Vᵀ, softmax на VPU, QACT P)")
    axs[0].legend(handles=[Patch(color=c, label=k) for k, c in STEP_COLORS.items()],
                  ncol=6, fontsize=8, loc="upper center", bbox_to_anchor=(0.5, -0.18))
    fig.tight_layout()
    save(fig, "02_timeline_gantt.png")

    # 3. counters
    s = res["series"]
    t = np.arange(len(s["window"])) * bk
    fig, axs = plt.subplots(4, 1, figsize=(14, 9), sharex=True)
    pb_m = np.array(s.get("portb_mxu", [0] * len(t))) / bk * 100
    pb_d = np.array(s.get("portb_dma", [0] * len(t))) / bk * 100
    axs[0].stackplot(t, pb_m, pb_d, colors=["#d77b12", "#555555"], labels=["MXU (веса, K, Vᵀ)", "DMA (LD/ST)"])
    axs[0].set_ylabel("порт B, %"), axs[0].legend(loc="lower right", fontsize=8)
    axs[0].set_title(f"Порт B за токен: занят {100 * (pb_m.sum() + pb_d.sum()) / len(t) / 100:.1f} % — "
                     "декод упирается в поток из HBM", fontsize=11)
    axs[1].plot(t, s["fifo"], color="#d77b12")
    axs[1].set_ylabel("FIFO MXU,\nчанков"), axs[1].axhline(cfg.FIFO_DEPTH, ls="--", c="grey", lw=0.8)
    axs[2].fill_between(t, np.array(s.get("mxu_busy", [0] * len(t))) / bk * 100, color="#2f9e44",
                        alpha=0.7, label="считает")
    axs[2].fill_between(t, np.array(s.get("mxu_starve", [0] * len(t))) / bk * 100, color="#e03131",
                        alpha=0.6, label="ждёт чанков (starved)")
    axs[2].set_ylabel("MXU, %"), axs[2].legend(loc="lower right", fontsize=8)
    axs[3].step(t, s["window"], color="#7048e8", where="post")
    axs[3].set_ylabel("окно SEQ,\nинструкций"), axs[3].axhline(cfg.WIN, ls="--", c="grey", lw=0.8)
    axs[3].set_xlabel("такт")
    for a in axs:
        a.grid(alpha=0.3)
    save(fig, "03_counters.png")

    # 4. breakdown
    by_step_b, by_step_n, busy = Counter(), Counter(), Counter()
    for ins in prog:
        inf = res["info"].get(ins.id, {})
        g = step_group(ins.step)
        by_step_b[g] += inf.get("hbm_read", 0) + inf.get("hbm_write", 0)
        by_step_n[ins.name] += 1
    for k, v in s.items():
        if k.startswith("busy_"):
            busy[k[5:]] = 100 * sum(v) / cyc
    fig, axs = plt.subplots(1, 3, figsize=(15, 4.8))
    ks = [k for k, _ in by_step_b.most_common() if by_step_b[k]]
    axs[0].barh(ks, [by_step_b[k] / 1024 for k in ks], color=[STEP_COLORS.get(k, "#adb5bd") for k in ks])
    axs[0].invert_yaxis(), axs[0].set_xlabel("КиБ из/в HBM"), axs[0].set_title("Трафик HBM по шагам модели")
    us = ["DMA", "MXU", "QUANT", "VPU"]
    axs[1].bar(us, [busy[u] for u in us], color=["#555555", "#d77b12", "#2b8a3e", "#1971c2"])
    axs[1].set_ylim(0, 105), axs[1].set_ylabel("% тактов с инструкцией"), axs[1].set_title("Загрузка блоков")
    for i, u in enumerate(us):
        axs[1].text(i, busy[u] + 2, f"{busy[u]:.0f} %", ha="center")
    ops = [k for k, _ in by_step_n.most_common()]
    axs[2].barh(ops, [by_step_n[k] for k in ops], color="#748ffc")
    axs[2].invert_yaxis(), axs[2].set_title(f"Инструкции: {len(prog)} за токен")
    fig.tight_layout()
    save(fig, "04_breakdown.png")

    # 5. memory maps
    fig, axs = plt.subplots(3, 1, figsize=(14, 6.5))
    kc = {"weights": "#2f9e44", "scales": "#94d82d", "kv": "#e8590c", "io": "#868e96", "norms": "#4dabf7"}
    hb = md.m.hbm
    for r in hb.regions:
        axs[0].barh(0, r.nbytes, left=r.addr, color=kc.get(r.kind, "#ccc"), edgecolor="white", lw=0.2)
    axs[0].set_xlim(0, hb.top), axs[0].set_yticks([])
    axs[0].xaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v / 2**20:.2f} МиБ"))
    axs[0].set_title(f"HBM (образ, {hb.top / 2**20:.2f} МиБ): веса INT8, масштабы, KV-кэш, I/O", fontsize=11)
    axs[0].legend(handles=[Patch(color=c, label=k) for k, c in kc.items()], ncol=5, fontsize=8,
                  loc="upper right")
    tm = md.m.tmem
    cmap = plt.get_cmap("tab20")
    for i, a in enumerate(tm.allocs):
        axs[1].barh(0, a.words, left=a.addr, color=cmap(i % 20), edgecolor="white", lw=0.3)
        if a.words > tm.top / 40:
            axs[1].text(a.addr + a.words / 2, 0, a.name, ha="center", va="center", fontsize=7, rotation=90)
    axs[1].set_xlim(0, tm.top), axs[1].set_yticks([])
    axs[1].set_title(f"TMEM: {tm.top:,} из {cfg.TMEM_WORDS:,} слов FP32 заняты буферами программы", fontsize=11)
    rows_of = {}
    for ins in prog:
        if ins.op == "QACT":
            rows_of[ins.a["ab"]] = max(rows_of.get(ins.a["ab"], 0), ins.a["M"])
    names = {"x_attn": "x → Q/K/V", "att": "выход attention", "x_mlp": "x → MLP",
             "x_head": "x → LM head"}
    for i, (nm, (b0, kb)) in enumerate(md.act_map.items()):
        axs[2].barh(range(rows_of.get(b0, 1)), kb, left=b0, color=cmap(i % 20), edgecolor="white")
        axs[2].text(b0 + kb / 2, -0.9, names.get(nm, nm), ha="center", fontsize=8)
    seen = {(b0, kb): 1 for b0, kb in md.act_map.values()}
    axs[2].set_ylabel("строка"), axs[2].set_xlabel("блок ACT RAM (по 128 B)")
    axs[2].set_title("ACT RAM: операнды MM в своих диапазонах блоков (поле ab)", fontsize=11)
    fig.tight_layout()
    save(fig, "05_memory_maps.png")

    # 6. attention
    if probe.att:
        keys = sorted(probe.att)
        rows, labels = [], []
        for k in keys:
            p = probe.probs(k)
            for g in range(p.shape[0]):
                rows.append(p[g])
                labels.append(f"слой {k[0]}, {k[1].split(', ')[-1]}, q{g}")
        A = np.stack(rows)
        fig, ax = plt.subplots(figsize=(14, 0.45 * len(rows) + 1.6))
        im = ax.imshow(A, aspect="auto", cmap="magma", interpolation="nearest")
        ax.set_yticks(range(len(labels)), labels, fontsize=8)
        ax.set_xlabel("позиция в контексте (токен KV-кэша)")
        ax.set_title(f"Веса внимания текущего токена (pos {md.pos}): softmax, посчитанный на MXU+VPU", fontsize=11)
        fig.colorbar(im, ax=ax, fraction=0.02)
        save(fig, "06_attention.png")

    # 7. numerics
    fig, axs = plt.subplots(1, 3, figsize=(15, 4.6))
    lg = md.logits()
    axs[0].scatter(ref_logits, lg, s=6, alpha=0.6)
    lim = [min(ref_logits.min(), lg.min()), max(ref_logits.max(), lg.max())]
    axs[0].plot(lim, lim, "k--", lw=0.8)
    cos = float(lg @ ref_logits / np.linalg.norm(lg) / np.linalg.norm(ref_logits))
    axs[0].set_xlabel("эталон float64"), axs[0].set_ylabel("симулятор (INT8 MXU)")
    axs[0].set_title(f"Логиты: косинус {cos:.4f}")
    x = md.m.tmem.mem[md.m.tmem.by_name["x"].addr: md.m.tmem.by_name["x"].addr + md.spec.H]
    from .numerics import dequantize, quantize_rows
    c, sc = quantize_rows(x)
    axs[1].plot(x[:64], "o-", ms=3, label="x (FP32)")
    axs[1].plot(dequantize(c, sc)[0][:64], "x", ms=4, label="код·Sa (INT8)")
    axs[1].set_title(f"QACT: Sa = max|x|/127 = {sc[0]:.4f}"), axs[1].legend(fontsize=8)
    axs[1].set_xlabel("элемент")
    axs[2].hist(c[0], bins=50, color="#ffa94d")
    axs[2].set_title("коды INT8 после квантования"), axs[2].set_xlabel("код")
    fig.tight_layout()
    save(fig, "07_numerics.png")

    # 8. calibration
    fig, ax = plt.subplots(figsize=(7, 3.6))
    names, vals = ["симулятор\n(этот)"], [cyc]
    if lens_cycles:
        names.append("RTL upstream\n(Lens)")
        vals.append(lens_cycles)
    roof = sum(ins.a["N"] * ins.a["K"] // 128 for ins in prog if ins.op == "MM")
    names.append("предел порта B\n(чанков MM)")
    vals.append(roof)
    ax.bar(names, vals, color=["#7048e8", "#2f9e44", "#adb5bd"][:len(vals)])
    for i, v in enumerate(vals):
        ax.text(i, v, f"{v:,}", ha="center", va="bottom")
    ax.set_ylabel("тактов на токен"), ax.set_title("Сверка с настоящим RTL (qwen-tiny, pos 8)")
    save(fig, "08_calibration.png")
    return files


def player_data(md, prog, res, probe, ref_logits):
    cfg = md.cfg
    out = []
    for ins in prog:
        r, inf = res["rec"][ins.id], res["info"].get(ins.id, {})
        out.append(dict(id=ins.id, op=ins.name, unit=ins.unit, step=ins.step,
                        group=step_group(ins.step), layer=ins.layer, text=ins.text,
                        d=r["dispatch"], s=r["start"], r=r["release"], e=r["end"],
                        paths=[f"{a}-{b}" for a, b in PATHS[ins.op]],
                        rd=inf.get("hbm_read", 0), wr=inf.get("hbm_write", 0),
                        pv=inf.get("preview", ""), ex=inf.get("example")))
    att = {f"{k[0]}|{k[1]}": probe.probs(k).round(6).tolist() for k in probe.att}
    lg = md.logits()
    return dict(cycles=res["cycles"], bucket=res["bucket"], series=res["series"], instrs=out,
                config=dict(D=cfg.D, MCOLS=cfg.MCOLS, LANES=cfg.LANES, WIN=cfg.WIN,
                            FIFO=cfg.FIFO_DEPTH, MHz=cfg.core_mhz),
                pos=md.pos, colors=STEP_COLORS, blocks=BLOCKS,
                labels={k: v.replace("\n", " · ") for k, v in LABELS.items()},
                hbm=[dict(name=r.name, addr=r.addr, n=r.nbytes, kind=r.kind) for r in md.m.hbm.regions],
                tmem=[dict(name=a.name, addr=a.addr, n=a.words) for a in md.m.tmem.allocs],
                examples=probe.examples, attention=att,
                logits=dict(sim=lg.round(5).tolist(), ref=np.round(ref_logits, 5).tolist()),
                traffic={f"{a}-{b}": v for (a, b), v in path_totals(prog, res).items()})


def narrate(prog, res, limit=40):
    lines = []
    for ins in prog[:limit]:
        r, inf = res["rec"][ins.id], res["info"].get(ins.id, {})
        when = f"{r['start']:>6}…{r['end']:<6}" if r["end"] is not None else ""
        rel = f" (счёт с {r['release']})" if r.get("release") else ""
        lines.append(f"[{ins.id:3}] {when} {ins.unit:5} {ins.name:12} {ins.text}{rel}")
        if inf.get("preview"):
            lines.append(f"{'':28}{inf['preview']}")
    if len(prog) > limit:
        lines.append(f"… ещё {len(prog) - limit} инструкций (всё — в trace.json / player.html)")
    return "\n".join(lines)


def explain_examples(probe):
    ex = probe.examples
    out = []
    if "QACT" in ex:
        e = ex["QACT"]
        out.append(f"QACT (квантование активаций): x = [{e['x']} …], max|x| = {e['maxabs']:.4g} → "
                   f"Sa = max/127 = {e['scale']:.4g}; коды = round(x/Sa) = [{e['codes']} …]; "
                   f"макс. ошибка восстановления {e['err']:.3g}")
    for k, name in (("MM", "проекция"), ("MM K", "скоры q·Kᵀ"), ("MM V", "P·Vᵀ")):
        if k in ex:
            e = ex[k]
            out.append(f"{k} ({name}): строка ACT = [{e['act']} …]·Sa={e['sa']:.4g}, строка весов = "
                       f"[{e['w']} …]·Sw={e['sw']:.4g}; целая сумма acc = {e['acc']}; "
                       f"y = acc·Sw·Sa = {e['y']:.5g}")
    if "QST" in ex:
        e = ex["QST"]
        out.append(f"QST (запись KV): k = [{e['x']} …] → масштаб {e['scale']:.4g}, INT8 [{e['codes']} …] в HBM")
    return "\n".join(out)


def write_html(data, template: Path, out: Path):
    html = template.read_text().replace("/*DATA*/null", json.dumps(data, ensure_ascii=False))
    out.write_text(html)
