#!/usr/bin/env python3
"""Structure of one openTPU slice (otpu_slice, VCU128 configuration) as a hand-laid SVG.

Content: ../../slice_structure.dot and ../../../slice.md (the same blocks and links). Layout by
explicit coordinates on a 10 px grid, orthogonal links with rounded corners; a link is drawn over
a halo of the background colour, so a crossing reads as a gap in the earlier line. Line width
follows the bandwidth (128 B/cycle thickest). Colours are CSS variables with a dark variant.

    python3 gen_slice_svg.py            # slice_svg.svg, slice_svg.png (1800 px), slice_svg.pdf

PNG/PDF go through Inkscape from a copy with the light colours written out (Inkscape does not
resolve CSS variables).
"""
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
W, H = 2000, 1420

# light / dark palettes: name -> (light, dark)
PAL = {
    "bg": ("#ffffff", "#16191d"), "fg": ("#1d232b", "#e6e9ee"), "muted": ("#5b6672", "#9aa4af"),
    "frame": ("#396484", "#7fa7c6"), "slicebg": ("#f7f9fc", "#1b2026"),
    "seq": ("#7b55b8", "#b49ae6"), "seqbg": ("#f1eafc", "#2a2338"),
    "mxu": ("#c96d0c", "#f0a24a"), "mxubg": ("#fff2e2", "#352819"),
    "tmem": ("#1b6fb8", "#6fb1ec"), "tmembg": ("#e3f1ff", "#18293a"),
    "quant": ("#2b8a3e", "#69c27c"), "quantbg": ("#e8f6eb", "#1b2e20"),
    "act": ("#a07a12", "#e0bd55"), "actbg": ("#fff6d8", "#332c15"),
    "mem": ("#b8572e", "#ee9a74"), "membg": ("#ffe8dc", "#3a2219"),
    "ext": ("#3f7d5a", "#7cc29b"), "extbg": ("#e8f4ec", "#1c2c23"),
    "unit": ("#41566b", "#9fb4c8"), "unitbg": ("#eef3f8", "#1f262e"),
    "vpu": ("#2f6fd0", "#7aa9f0"), "vpubg": ("#e8f0ff", "#1c2436"),
    "data": ("#396484", "#8fb6d6"), "gray": ("#6f6f6f", "#a8a8a8"),
}

out = []
late = []                                           # frame labels: drawn over the links


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, cls="t", anchor="middle", rot=None):
    tr = f' transform="rotate({rot} {x} {y})"' if rot else ""
    out.append(f'<text x="{x}" y="{y}" class="{cls}" text-anchor="{anchor}"{tr}>{esc(s)}</text>')


def box(x0, y0, x1, y1, title, lines=(), c="unit", shape="rect"):
    if shape == "port":                              # pentagon pointing right (graphviz cds)
        t = 18
        pts = f"{x0},{y0} {x1 - t},{y0} {x1},{(y0 + y1) / 2} {x1 - t},{y1} {x0},{y1}"
        out.append(f'<polygon points="{pts}" class="box" style="fill:var(--{c}bg);stroke:var(--{c})"/>')
        cx = (x0 + x1 - t) / 2
    else:
        out.append(f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="7" '
                   f'class="box" style="fill:var(--{c}bg);stroke:var(--{c})"/>')
        cx = (x0 + x1) / 2
    n = 1 + len(lines)
    lh = 15.5
    y = (y0 + y1) / 2 - (n - 1) * lh / 2 + 5
    text(cx, y, title, "tb")
    for i, s in enumerate(lines):
        text(cx, y + (i + 1) * lh, s, "t")


def frame(x0, y0, x1, y1, label, c, fill="none"):
    f = f"var(--{fill})" if fill != "none" else "none"
    out.append(f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="12" '
               f'class="frame" style="fill:{f};stroke:var(--{c})"/>')
    late.append(f'<text x="{x0 + 14}" y="{y0 + 20}" class="fl" text-anchor="start" '
                f'style="fill:var(--{c})">{esc(label)}</text>')


def rounded(pts, r=9):
    d = f"M{pts[0][0]},{pts[0][1]}"
    for i in range(1, len(pts) - 1):
        (ax, ay), (bx, by), (cx_, cy_) = pts[i - 1], pts[i], pts[i + 1]
        l1 = math.hypot(bx - ax, by - ay)
        l2 = math.hypot(cx_ - bx, cy_ - by)
        rr = min(r, l1 / 2, l2 / 2)
        p1 = (bx - (bx - ax) / l1 * rr, by - (by - ay) / l1 * rr)
        p2 = (bx + (cx_ - bx) / l2 * rr, by + (cy_ - by) / l2 * rr)
        d += f" L{p1[0]:.1f},{p1[1]:.1f} Q{bx},{by} {p2[0]:.1f},{p2[1]:.1f}"
    d += f" L{pts[-1][0]},{pts[-1][1]}"
    return d


def head(p, q, w, c):
    """Arrowhead at q, coming from p."""
    ang = math.atan2(q[1] - p[1], q[0] - p[0])
    L, B = 8 + 1.6 * w, 4 + 1.2 * w
    a = (q[0] - L * math.cos(ang) + B * math.sin(ang), q[1] - L * math.sin(ang) - B * math.cos(ang))
    b = (q[0] - L * math.cos(ang) - B * math.sin(ang), q[1] - L * math.sin(ang) + B * math.cos(ang))
    out.append(f'<polygon points="{q[0]},{q[1]} {a[0]:.1f},{a[1]:.1f} {b[0]:.1f},{b[1]:.1f}" '
               f'style="fill:var(--{c})"/>')


def link(pts, c="data", w=1.4, style="solid", end=True, start=False, label=None, lab_at=None,
         lab_anchor="middle", lab_rot=None):
    """Orthogonal link through pts; label at lab_at (x, y)."""
    dash = {"solid": "", "dash": "7 5", "dot": "2 4"}[style]
    # shorten the drawn line under the arrowheads
    p = [list(x) for x in pts]
    L = 8 + 1.6 * w
    for flag, i, j in ((end, -1, -2), (start, 0, 1)):
        if flag:
            dx, dy = p[i][0] - p[j][0], p[i][1] - p[j][1]
            n = math.hypot(dx, dy)
            p[i] = [p[i][0] - dx / n * (L - 2), p[i][1] - dy / n * (L - 2)]
    d = rounded([tuple(x) for x in p])
    out.append(f'<path d="{d}" class="halo" style="stroke-width:{w + 7}"/>')
    da = f";stroke-dasharray:{dash}" if dash else ""
    out.append(f'<path d="{d}" class="ln" style="stroke:var(--{c});stroke-width:{w}{da}"/>')
    if end:
        head(pts[-2], pts[-1], w, c)
    if start:
        head(pts[1], pts[0], w, c)
    if label:
        for k, s in enumerate(label.split("\n")):
            text(lab_at[0], lab_at[1] + k * 14, s, "lb", lab_anchor, lab_rot)
            out[-1] = out[-1].replace('class="lb"', f'class="lb" style="fill:var(--{c})"')


def build():
    out.clear()
    late.clear()
    text(W / 2, 34, "Слайс openTPU (otpu_slice) на VCU128: S = 1, D = 128, MCOLS = 4, LANES = 8, "
         "WIN = 16, core_clk 100 МГц", "title")

    # ---------------------------------------------------------------- frames
    frame(20, 175, 1600, 1405, "otpu_slice", "frame", "slicebg")
    frame(40, 200, 1585, 322, "SEQ — otpu_seq", "seq")
    frame(470, 385, 1000, 972, "MXU — otpu_mxu (2 команды в работе)", "mxu")
    frame(40, 1030, 1585, 1390, "TMEM — otpu_tmem", "tmem")

    # ---------------------------------------------------------------- outside the slice
    box(780, 64, 1180, 138, "otpu_ctrl (s_ctl 0x00000)",
        ["CTRL: RUN / LOAD / CLEAR · ARG0..7", "STATUS · счётчики · буфер трассы"], "ext")
    box(1660, 215, 1975, 295, "otpu_coll (общий на S слайсов)",
        ["BAR · GATHER: сегменты слайсов", "→ TMEM всех слайсов"], "ext")
    box(1690, 420, 1950, 740, "память слайса",
        ["otpu_native_dram", "", "2 канала, beat 64 B,", "чередование + CHASH", "",
         "→ otpu_mem_ch ×2", "→ otpu_hbm_port ×2 → HBM"], "mem")

    # ---------------------------------------------------------------- SEQ
    box(60, 228, 420, 308, "загрузчик программы",
        ["HBM → IMEM, 1 чанк = 4 инстр./такт", "(старт и HALT CHAIN)"], "seq")
    box(470, 228, 780, 308, "IMEM", ["4096 инструкций × 256 бит", "чтение на такт вперёд"], "seq")
    box(830, 228, 1190, 308, "выборка + декод: 1 инстр./такт",
        ["R0..R15, LI / ADDI / LOOP (до 4 уровней)", "w1..w3 += R[ra..rc]"], "seq")
    box(1240, 228, 1570, 308, "окно WIN = 16 + табло",
        ["отпечатки диапазонов TMEM / HBM / ACT", "RAW / WAR / WAW → старт старшей готовой"], "seq")

    # ---------------------------------------------------------------- units
    box(95, 400, 380, 482, "QUANT — otpu_quant",
        ["8 FP32/такт, 2 прохода (max → коды)", "буфер строки 1024 чанка", "CSCALE / RSCALE"],
        "quant")
    box(95, 712, 380, 794, "ACT RAM — otpu_actram",
        ["4 строки × 128 блоков × 128 B INT8", "+ {da, Sa} на (строку, блок)"], "act")
    box(620, 415, 985, 465, "issuer (ustart)", ["запросы N×KB чанков + строк масштабов"], "mxu")
    box(620, 478, 985, 528, "FIFO чанков", ["1024 × 128 B"], "mxu")
    box(830, 556, 985, 606, "FIFO масштабов", ["Sw, dw по блокам"], "mxu")
    box(490, 712, 800, 794, "систолический массив (urel)",
        ["4 колонки × 128 INT8·INT8", "цепочки DSP48E2 по 16 · точная сумма"], "mxu")
    box(490, 868, 985, 944, "FIFO результатов → эпилог, 2 полосы",
        ["i2f · ×Sw · ×Sa·2⁻¹⁶ · ACC / ASCALE / RMAX"], "mxu")
    box(1040, 418, 1262, 520, "порт B", ["128 B/такт (1024 бит)", "DMA, затем поток MXU,",
                                         "загрузчик"], "mem", "port")
    box(1040, 538, 1262, 596, "порт A", ["строки 32 B: масштабы MXU"], "mem", "port")
    box(1040, 664, 1262, 724, "порт SW", ["32 бит/такт + маска байт", "QST (KV-кэш)"], "mem",
        "port")
    box(1300, 780, 1570, 856, "DMA — otpu_dma",
        ["LD / ST: чанк 128 B ↔ 8 слов FP32", "буфер LD 128 · WAITW · DSTEP/STREAM"])
    box(1300, 890, 1570, 986, "VPU — otpu_vpu",
        ["8 полос FP32 + составные", "exp2, recip, rsqrt, log2 · редукция",
         "SE: хвост stream engine (DeltaNet)"], "vpu")

    # ---------------------------------------------------------------- TMEM
    box(60, 1056, 1565, 1110, "арбитр банков: каждый такт, всё-или-ничего",
        ["приоритет DMA > COLL > VPU > выгрузка MXU > QUANT"], "tmem")
    box(470, 1196, 1180, 1374, "65536 × FP32 = 256 KiB, 8 банков (адрес mod 8)",
        ["на FPGA — копия памяти на каждый порт чтения", "",
         "8 портов чтения: MXU, DMA, Q, VA, VB, Q2, Q3, COLL",
         "4 порта записи: DMA, MXU, COLL, VPU"], "tmem")

    # ---------------------------------------------------------------- SEQ, control (dashed)
    for a, b in (((420, 268), (470, 268)), ((780, 268), (830, 268)), ((1190, 268), (1240, 268))):
        link([a, b], "seq", 1.6)
    link([(780, 101), (240, 101), (240, 228)], "ext", 1.3, "dash",
         label="LOAD: PROG_ADDR, PROG_N", lab_at=(510, 94))
    link([(1010, 138), (1010, 228)], "ext", 1.3, "dash",
         label="RUN · ARG0..7 → R8..R15", lab_at=(1020, 186), lab_anchor="start")
    link([(1405, 228), (1405, 101), (1180, 101)], "ext", 1.3, "dash",
         label="HALTED / ERROR / icount", lab_at=(1415, 160), lab_anchor="start")
    link([(1570, 255), (1660, 255)], "seq", 1.3, "dash",
         label="BAR / GATHER", lab_at=(1615, 246))
    bus_y = 360                                     # the window starts the units' instructions
    link([(1405, 308), (1405, bus_y), (240, bus_y), (240, 400)], "seq", 1.3, "dash")
    text(830, bus_y - 6, "старт команд (конфликты в окне сняты)", "lb", "start")
    out[-1] = out[-1].replace('class="lb"', 'class="lb" style="fill:var(--seq)"')
    link([(815, bus_y), (815, 415)], "seq", 1.3, "dash")
    link([(540, bus_y), (540, 712)], "seq", 1.3, "dash",
         label="urel", lab_at=(548, 690), lab_anchor="start")
    link([(1570, 290), (1588, 290), (1588, 818), (1570, 818)], "seq", 1.3, "dash")
    link([(1588, 818), (1588, 938), (1570, 938)], "seq", 1.3, "dash")
    # issuer requests to ports B and A
    link([(985, 440), (1040, 440)], "mxu", 1.2, "dash")
    link([(985, 455), (1015, 455), (1015, 552), (1040, 552)], "mxu", 1.2, "dash")
    text(1012, 432, "запросы", "lb")
    out[-1] = out[-1].replace('class="lb"', 'class="lb" style="fill:var(--mxu)"')

    # ---------------------------------------------------------------- memory
    link([(1262, 469), (1690, 469)], "mem", 3.2, start=True,
         label="чтение / запись чанков", lab_at=(1476, 460))
    link([(1690, 567), (1262, 567)], "mem", 1.8, label="чтение строк", lab_at=(1476, 558))
    link([(1262, 694), (1690, 694)], "mem", 1.4, label="запись слов", lab_at=(1476, 685))
    link([(1200, 418), (1200, 340), (150, 340), (150, 308)], "data", 1.6,
         label="программа: HBM → загрузчик (порт B)", lab_at=(700, 333))
    link([(1150, 520), (1150, 532), (1350, 532), (1350, 780)], "data", 3.2,
         start=True, label="LD / ST", lab_at=(1358, 760), lab_anchor="start")
    link([(1040, 503), (985, 503)], "mxu", 3.2)
    text(1012, 520, "веса", "lb")
    out[-1] = out[-1].replace('class="lb"', 'class="lb" style="fill:var(--mxu)"')
    link([(1040, 581), (985, 581)], "mxu", 1.8)

    # ---------------------------------------------------------------- MXU inside
    link([(700, 528), (700, 712)], "mxu", 3.2, label="1 чанк/такт: веса, K-строки, Vᵀ",
         lab_at=(708, 640), lab_anchor="start")
    link([(380, 753), (490, 753)], "act", 3.2, label="4 строки ×\nблок + Sa", lab_at=(413, 730))
    link([(640, 794), (640, 868)], "mxu", 2.2)
    link([(910, 606), (910, 868)], "mxu", 1.4, label="Sw, dw", lab_at=(918, 740), lab_anchor="start")
    link([(600, 944), (600, 1056)], "mxu", 2.2, label="≤ 2 FP32/такт", lab_at=(592, 962),
         lab_anchor="end")
    link([(880, 1056), (880, 944)], "mxu", 1.3, "dot",
         label="ACC / ASCALE: старое значение", lab_at=(872, 962), lab_anchor="end")

    # ---------------------------------------------------------------- QUANT, DMA, VPU, COLL ↔ TMEM
    link([(240, 482), (240, 712)], "quant", 3.2, label="QACT: 8 B/такт + {da, Sa}",
         lab_at=(248, 600), lab_anchor="start")
    link([(75, 1056), (75, 441), (95, 441)], "quant", 2.2, label="чтение 8 FP32/такт (Q, Q2, Q3)",
         lab_at=(67, 900), lab_rot=-90)
    link([(380, 455), (455, 455), (455, 1005), (1020, 1005), (1020, 694), (1040, 694)], "quant",
         2.2, label="QST: K-строки и столбцы Vᵀ", lab_at=(1012, 860), lab_rot=-90)
    link([(1300, 830), (1280, 830), (1280, 1056)], "data", 2.2, start=True,
         label="8 слов/такт", lab_at=(1272, 960), lab_rot=-90)
    link([(1435, 856), (1435, 890)], "data", 1.3, "dot",
         label="DSTEP / STREAM (минуя TMEM)", lab_at=(1443, 877), lab_anchor="start")
    link([(1435, 986), (1435, 1056)], "vpu", 2.2, start=True,
         label="VA, VB; запись 8 слов/такт", lab_at=(1443, 1016), lab_anchor="start")
    link([(1975, 270), (1990, 270), (1990, 1083), (1565, 1083)], "gray", 1.6, start=True,
         label="GATHER; RLD → R[rd]", lab_at=(1780, 1075))
    link([(825, 1110), (825, 1196)], "tmem", 2.6, start=True,
         label="гранты банков", lab_at=(835, 1158), lab_anchor="start")

    # ---------------------------------------------------------------- legend
    lx, ly = 1625, 1130
    text(lx, ly, "Обозначения", "tb", "start")
    items = [("data", 3.2, "solid", "128 B/такт (порт B, поток весов)"),
             ("data", 2.2, "solid", "8 слов FP32/такт (TMEM)"),
             ("data", 1.4, "solid", "≤ 32 B/такт, слова"),
             ("seq", 1.3, "dash", "управление"),
             ("data", 1.3, "dot", "обход / старое значение")]
    for i, (c, w, st, sx) in enumerate(items):
        y = ly + 26 + i * 24
        link([(lx, y), (lx + 50, y)], c, w, st)
        text(lx + 60, y + 4, sx, "lb", "start")
    text(lx, ly + 26 + 5 * 24 + 6, "пересечение — разрыв в нижней линии", "lb", "start")
    out.extend(late)


def css(dark: bool):
    def vars_(i):
        return ";".join(f"--{k}:{v[i]}" for k, v in PAL.items())
    s = (":root{" + vars_(0) + "}" +
         ("@media (prefers-color-scheme: dark){:root{" + vars_(1) + "}}" if dark else "") +
         "svg{background:var(--bg)}"
         "text{font-family:system-ui,'Noto Sans','DejaVu Sans',Arial,sans-serif;fill:var(--fg)}"
         ".t{font-size:12.5px}.tb{font-size:13px;font-weight:600}"
         ".title{font-size:20px;font-weight:600}.fl{font-size:14px;font-weight:600;paint-order:stroke;stroke:var(--slicebg);stroke-width:6px;stroke-linejoin:round}"
         ".lb{font-size:11.5px;paint-order:stroke;stroke:var(--slicebg);stroke-width:4px;"
         "stroke-linejoin:round}"
         ".box{stroke-width:1.3}.frame{stroke-width:1.5}"
         ".ln{fill:none;stroke-linecap:round;stroke-linejoin:round}"
         ".halo{fill:none;stroke:var(--slicebg);stroke-linecap:butt}")
    return s


def svg(dark=True):
    build()
    body = "\n".join(out)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" '
            f'height="{H}">\n<style>{css(dark)}</style>\n'
            f'<rect x="0" y="0" width="{W}" height="{H}" style="fill:var(--bg)"/>\n{body}\n</svg>\n')


def resolve(s: str) -> str:
    """Light colours written out (for Inkscape)."""
    light = {k: v[0] for k, v in PAL.items()}
    s = re.sub(r"var\(--(\w+)\)", lambda m: light[m.group(1)], s)
    return re.sub(r":root\{[^}]*\}", "", s)


def main():
    (HERE / "slice_svg.svg").write_text(svg(True))
    if not shutil.which("inkscape"):
        print("inkscape not found: SVG only")
        return 0
    tmp = HERE / ".slice_svg_light.svg"
    tmp.write_text(resolve(svg(False)))
    try:
        for args in (["--export-type=png", "--export-width=1800",
                      f"--export-filename={HERE / 'slice_svg.png'}"],
                     ["--export-type=pdf", "--export-text-to-path",
                      f"--export-filename={HERE / 'slice_svg.pdf'}"]):
            subprocess.run(["inkscape", str(tmp), *args], check=True, capture_output=True)
    finally:
        tmp.unlink()
    print("wrote slice_svg.svg, slice_svg.png, slice_svg.pdf")
    return 0


if __name__ == "__main__":
    sys.exit(main())
