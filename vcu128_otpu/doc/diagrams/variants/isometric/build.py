#!/usr/bin/env python3
"""Изометрическая фигура слайса openTPU (otpu_slice, VCU128 S = 1) в манере скилла anatomy.

Ядро kit (iso-kit.mjs: камера 45°/30°, extrude с четырьмя тонами боков и светлым верхом,
рёбра, складки, проводники с концевыми точками, табличка-карточка) перенесено на Python,
потому что node на машине нет. Содержание — только из ../../slice_structure.dot и
../../../slice.md.

    python3 build.py            -> slice_isometric.html (тёмная тема, T — светлая),
                                   slice_isometric.svg (светлая, стили встроены)
Затем PNG: inkscape slice_isometric.svg -w 1800 -o slice_isometric.png
"""
import html
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent

# ---------------------------------------------------------------- камера (iso-kit.mjs)
AZ, EL, SHADES = math.radians(45), math.radians(30), 4
UNIT = math.sqrt(1.6)
SA, CA, SE, CE = math.sin(AZ), math.cos(AZ), math.sin(EL), math.cos(EL)


class Cam:
    def __init__(self, origin=(0.0, 0.0), scale=1.0):
        self.ox, self.oy = origin
        self.k = scale * UNIT

    def p(self, x, y, z=0.0):
        return (self.ox + (x * SA - y * CA) * self.k, self.oy + ((x * CA + y * SA) * SE - z * CE) * self.k)


def fit(points, width, height, pad):
    u = Cam()
    flat = [u.p(*q) for q in points]
    xs, ys = [a for a, _ in flat], [b for _, b in flat]
    l, r, t, b = min(xs), max(xs), min(ys), max(ys)
    s = min((width - 2 * pad) / (r - l), (height - 2 * pad) / (b - t))
    return Cam((width / 2 - (l + r) / 2 * s, height / 2 - (t + b) / 2 * s), s)


def f1(v):
    t = f"{round(v * 10) / 10:.1f}".rstrip("0").rstrip(".")
    return "0" if t == "-0" else t


def path(pts, closed=False):
    if not pts:
        return ""
    return "".join(f"{'L' if i else 'M'}{f1(x)} {f1(y)}" for i, (x, y) in enumerate(pts)) + ("Z" if closed else "")


def rounded(x, y, w, d, r, steps=6):
    r = max(0.0, min(r, w / 2, d / 2))
    out = []
    for cx, cy, st in ((x + w - r, y + r, -90), (x + w - r, y + d - r, 0), (x + r, y + d - r, 90), (x + r, y + r, 180)):
        n = steps if r > 0 else 0
        for i in range(n + 1):
            a = math.radians(st + (90 * i / n if n else 45))
            out.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return out


def area(p):
    return sum(p[i][0] * p[(i + 1) % len(p)][1] - p[(i + 1) % len(p)][0] * p[i][1] for i in range(len(p))) / 2


def oriented(p):
    return list(reversed(p)) if area(p) < 0 else p


def hull(pts):
    s = sorted(set(pts))
    if len(s) < 3:
        return s

    def cr(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, up = [], []
    for q in s:
        while len(lo) >= 2 and cr(lo[-2], lo[-1], q) <= 0:
            lo.pop()
        lo.append(q)
    for q in reversed(s):
        while len(up) >= 2 and cr(up[-2], up[-1], q) <= 0:
            up.pop()
        up.append(q)
    return lo[:-1] + up[:-1]


def runs(flags, want):
    n = len(flags)
    start = next((i for i in range(n) if flags[i] != flags[i - 1]), -1)
    if start < 0:
        return [[i % n for i in range(n + 1)]] if flags[0] == want else []
    out, run = [], None
    for s in range(n):
        i = (start + s) % n
        if flags[i] == want:
            if run is None:
                run = [i]
            run.append((i + 1) % n)
        elif run is not None:
            out.append(run)
            run = None
    if run is not None:
        out.append(run)
    return out


def extrude(ring, z, h, cam, bevel=0.0):
    n = len(ring)
    ccw = area(ring) > 0
    vx, vy = CA, SA
    normals = []
    for i, (ax, ay) in enumerate(ring):
        bx, by = ring[(i + 1) % n]
        dx, dy = bx - ax, by - ay
        L = math.hypot(dx, dy) or 1
        normals.append((dy / L, -dx / L) if ccw else (-dy / L, dx / L))
    facing = [nx * vx + ny * vy > 1e-9 for nx, ny in normals]
    top = [cam.p(x, y, z + h) for x, y in ring]
    bot = [cam.p(x, y, z) for x, y in ring]
    outline, crease = [], []
    for r in runs(facing, False):
        outline.append(path([top[i] for i in r]))
    for r in runs(facing, True):
        crease.append(path([top[i] for i in r]))
        if h > 0:
            outline.append(path([bot[i] for i in r]))
    if h > 0:
        for i in range(n):
            if facing[i - 1] != facing[i]:
                outline.append(path([top[i], bot[i]]))
    shades = [[] for _ in range(SHADES)]
    if h > 0:
        lx, ly = -SA, CA
        for i in range(n):
            if not facing[i]:
                continue
            nx, ny = normals[i]
            s = min(SHADES - 1, max(0, int((nx * lx + ny * ly + 1) / 2 * SHADES)))
            j = (i + 1) % n
            shades[s].append(path(oriented([top[i], top[j], bot[j], bot[i]]), True))
    bev = ""
    if bevel > 0:
        ins = []
        for i, (x, y) in enumerate(ring):
            ax, ay = normals[i - 1]
            bx, by = normals[i]
            mx, my = ax + bx, ay + by
            L = math.hypot(mx, my) or 1
            ins.append(cam.p(x - mx / L * bevel, y - my / L * bevel, z + h))
        bev = "".join(path([top[r[0]]] + [ins[i] for i in r[1:-1]] + [top[r[-1]]]) for r in runs(facing, True))
    return {"fill": path(hull(top + bot), True), "outline": "".join(outline), "crease": "".join(crease),
            "top": path(oriented(top), True), "shades": ["".join(s) for s in shades], "bevel": bev}


def matrix_top(cam, x, y, z, along="x"):
    o = cam.p(x, y, z)
    ex = [a - b for a, b in zip(cam.p(x + 1, y, z), o)]
    ey = [a - b for a, b in zip(cam.p(x, y + 1, z), o)]
    u, v = (ex, ey) if along == "x" else ([-ey[0], -ey[1]], ex)
    return "matrix(%.3f %.3f %.3f %.3f %.2f %.2f)" % (u[0], u[1], v[0], v[1], o[0], o[1])


def matrix_side(cam, x, y, z, face):
    """Текст на вертикальной грани: face 'y' — грань, обращённая к +y (идёт вдоль x),
    face 'x' — грань к +x (идёт вдоль −y... читаем вдоль +y)."""
    o = cam.p(x, y, z)
    ex = [a - b for a, b in zip(cam.p(x + 1, y, z), o)]
    ey = [a - b for a, b in zip(cam.p(x, y + 1, z), o)]
    ez = [a - b for a, b in zip(cam.p(x, y, z + 1), o)]
    down = [-ez[0], -ez[1]]
    u = ex if face == "y" else [-ey[0], -ey[1]]
    return "matrix(%.3f %.3f %.3f %.3f %.2f %.2f)" % (u[0], u[1], down[0], down[1], o[0], o[1])


# ---------------------------------------------------------------- сцена
ITEMS = []          # {box, draw(cam)->svg, block}


def esc(s):
    return html.escape(s, quote=True)


def solid_svg(p, tone="hi", crease="faint", lit=False, halo=False, inner=""):
    parts = []
    if halo:
        parts.append(f'<path class="r-halo" d="{p["fill"]}"/>')
    parts.append(f'<path class="r-fill" d="{p["fill"]}"/>')
    for i, d in enumerate(p["shades"]):
        if d:
            parts.append(f'<path class="r-shade{"-lit" if lit else i}" d="{d}"/>')
    parts.append(f'<path class="r-top{"-lit" if lit else ""}" d="{p["top"]}"/>')
    if crease != "none" and p["crease"]:
        parts.append(f'<path class="r-line t-{crease}" d="{p["crease"]}"/>')
    if crease != "none" and p["bevel"]:
        parts.append(f'<path class="r-line t-{crease}" d="{p["bevel"]}"/>')
    parts.append(inner)
    parts.append(f'<path class="r-line r-edge t-{"lit" if lit else tone}" d="{p["outline"]}"/>')
    return "".join(parts)


def box(block, x, y, w, d, z, h, tone="hi", r=1.0, bevel=0.0, lit=False, halo=False, inner=None, cls=""):
    """Сплошное тело на скруглённом плане; inner(cam) — детали поверх (текст, точки, риски)."""
    def draw(cam):
        p = extrude(rounded(x, y, w, d, r), z, h, cam, bevel)
        extra = inner(cam) if inner else ""
        return solid_svg(p, tone, lit=lit, halo=halo, inner=extra)
    ITEMS.append({"box": (x, y, z, x + w, y + d, z + h), "draw": draw, "block": block, "cls": cls})


def text(cam, x, y, z, s, size=3.4, tone="mid", along="x", anchor="start", side=None):
    m = matrix_side(cam, x, y, z, side) if side else matrix_top(cam, x, y, z, along)
    return (f'<text class="r-text t-{tone}" transform="{m}" font-size="{size}" '
            f'text-anchor="{anchor}">{esc(s)}</text>')


def dots(cam, pts, r=0.5, tone="mid"):
    return "".join(f'<circle class="r-dot t-{tone}" cx="{f1(a)}" cy="{f1(b)}" r="{r}"/>' for a, b in (cam.p(*q) for q in pts))


def line(cam, pts, tone="lo", extra=""):
    return f'<path class="r-line t-{tone}"{extra} d="{path([cam.p(*q) for q in pts])}"/>'


def screws(cam, x, y, w, d, z, inset=3.0):
    pts = [(x + inset, y + inset, z), (x + w - inset, y + inset, z), (x + inset, y + d - inset, z), (x + w - inset, y + d - inset, z)]
    rings = "".join(f'<circle class="r-ring t-lo" cx="{f1(a)}" cy="{f1(b)}" r="1.1"/>' for a, b in (cam.p(*q) for q in pts))
    return rings + dots(cam, pts, 0.45, "mid")


def rail(block, pts, width, z=0.0, h=0.8, tone="mid", lit=False, cls="", flow=False):
    """Путь данных: отрезки вдоль осей (полосы на плите или на мостике)."""
    hw = width / 2
    segs = list(zip(pts, pts[1:]))
    for k, ((ax, ay), (bx, by)) in enumerate(segs):
        # концы — ровно на гранях; угол целиком в предыдущем отрезке
        ext_b = hw if k < len(segs) - 1 else 0.0
        cut_a = hw if k > 0 else 0.0
        if ay == by:
            sgn = 1 if bx > ax else -1
            xa, xb = ax + sgn * cut_a, bx + sgn * ext_b
            x0, x1, y0, y1 = min(xa, xb), max(xa, xb), ay - hw, ay + hw
        else:
            sgn = 1 if by > ay else -1
            ya, yb = ay + sgn * cut_a, by + sgn * ext_b
            x0, x1, y0, y1 = ax - hw, ax + hw, min(ya, yb), max(ya, yb)
        inner = None
        if flow:                                       # осевой штрих: направление потока
            if ay == by:
                seg_pts = [(x0 + 1, ay, z + h), (x1 - 1, ay, z + h)]
            else:
                seg_pts = [(ax, y0 + 1, z + h), (ax, y1 - 1, z + h)]
            if (bx < ax) or (by < ay):
                seg_pts.reverse()
            inner = (lambda c, q=seg_pts: line(c, q, "mid", ' stroke-dasharray="3 4"'))
        box(block, x0, y0, x1 - x0, y1 - y0, z, h, tone=tone, r=0.3, lit=lit, cls=cls, inner=inner)


def posts(block, pts, z1, size=3.0):
    for x, y in pts:
        box(block, x - size / 2, y - size / 2, size, size, 0, z1, tone="lo", r=0.4)


# ---------------------------------------------------------------- блоки (источник: slice_structure.dot, slice.md)
INFO = {
    "base": ("otpu_slice", "Одна полная копия вычислительного ядра openTPU: своя память программы, свои блоки и свои "
             "каналы памяти. Параметр S в target/vcu128.toml; на VCU128 S = 1, D = 128, MCOLS = 4, LANES = 8, "
             "WIN = 16, core_clk 100 МГц."),
    "ctrl": ("otpu_ctrl (s_ctl 0x00000)", "CTRL: RUN / LOAD / CLEAR · ARG0..7 → R8..R15 · STATUS · счётчики · "
             "буфер трассы. LOAD: PROG_ADDR, PROG_N; обратно HALTED / ERROR / icount."),
    "seq": ("SEQ — otpu_seq (1481 строка)", "Выборка + декод: 1 инструкция/такт; R0..R15, LI / ADDI / LOOP (до 4 "
            "уровней); поля адресов += R[ra..rc]. Раздаёт команды блокам с табло зависимостей."),
    "imem": ("IMEM и загрузчик", "IMEM 4096 инструкций × 256 бит, читается на такт вперёд. Загрузчик: HBM → IMEM, "
             "1 чанк = 4 инструкции/такт — при старте и по HALT CHAIN (через порт B)."),
    "win": ("Окно WIN = 16 + табло", "Отпечатки диапазонов TMEM / HBM / ACT, конфликты RAW / WAR / WAW со всеми "
            "старшими. DMA, QUANT, COLL стартуют по порядку; VPU — самую старую готовую; MXU — две фазы: "
            "ACCEPT (ustart) и RELEASE (urel)."),
    "hbm": ("Память слайса", "otpu_native_dram: 2 канала (beat 64 B, чередование + CHASH) → otpu_mem_ch ×2 → "
            "otpu_hbm_port ×2 → HBM. Вынесена из слайса наружу (otpu_top / otpu_board); слайсу видны три порта."),
    "portB": ("Порт B — 128 B/такт (1024 бит)", "Первым обслуживается DMA, затем поток весов MXU (веса, K-строки, "
              "Vᵀ); через него же загрузчик читает программу. Ответы на чтение возвращаются по тегу владельцу."),
    "portA": ("Порт A — 256 бит", "Строки масштабов MXU, 32 B: в FIFO масштабов (Sw, dw по блокам)."),
    "portSW": ("Порт SW — 32 бит/такт + маска байт", "Запись одного 32-битного слова за такт для QST: дописывание "
               "K-строки и столбца Vᵀ (KV-кэш) с чтением-модификацией beat."),
    "dma": ("DMA — otpu_dma (949 строк)", "LD / ST: чанк 128 B ↔ 8 слов FP32/такт; буфер LD 128 чанков; WAITW; "
            "DSTEP / STREAM — из HBM прямо в хвост VPU, минуя TMEM."),
    "mxu": ("MXU — otpu_mxu (1669 строк)", "INT8 (и 4 бит) × INT8, точная сумма, FP32-эпилог; 2 команды в работе. "
            "Issuer (ustart) запрашивает N×KB чанков и строки масштабов."),
    "fifo": ("FIFO чанков 1024 × 128 B", "Поток весов из порта B. Строка весов n начинает считаться, только когда "
             "все её KB чанков и масштабы уже в FIFO."),
    "fsc": ("FIFO масштабов", "Sw, dw по блокам — из порта A."),
    "arr": ("Систолический массив (urel)", "4 колонки × 128 INT8·INT8, цепочки DSP48E2 по 16, точная целая сумма: "
            "колонка j суммирует 128 произведений ACT[j][блок] × W[n][блок]."),
    "epi": ("Эпилог, 2 полосы", "FIFO результатов → i2f · ×Sw · ×Sa·2⁻¹⁶ · ACC / ASCALE / RMAX → ≤ 2 FP32 за такт "
            "в TMEM при гранте банков (ACC / ASCALE читают старое значение)."),
    "act": ("ACT RAM — otpu_actram (196 строк)", "4 строки × 128 блоков × 128 B INT8 + {da, Sa} на (строку, блок): "
            "стационарные операнды MM по диапазонам блоков (ab)."),
    "quant": ("QUANT — otpu_quant (874 строки)", "8 FP32/такт, 2 прохода (max → коды), буфер строки 1024 чанка, "
              "CSCALE / RSCALE. QACT → ACT RAM, QST → HBM через порт SW (KV-кэш)."),
    "vpu": ("VPU — otpu_vpu (1568 строк)", "8 полос FP32: поэлементные, составные (exp2, recip, rsqrt, log2), "
            "дерево редукции; SE — хвост stream engine (DeltaNet)."),
    "tmem": ("TMEM — otpu_tmem (1047 строк)", "65536 × FP32 = 256 KiB, 8 банков (адрес mod 8). На FPGA — копия на "
             "каждый порт чтения: 8 портов чтения (MXU, DMA, Q, VA, VB, Q2, Q3, COLL), 4 записи (DMA, MXU, COLL, "
             "VPU); запись — одна на банк за такт."),
    "arb": ("Арбитр банков TMEM", "Каждый такт, всё-или-ничего: грант блоку целиком или никак. Приоритет "
            "DMA > COLL > VPU > выгрузка MXU > QUANT; не получивший грант блок держит состояние."),
    "w_qact": ("QACT: QUANT → ACT RAM", "8 B/такт + {da, Sa}."),
    "w_act": ("ACT RAM → MXU", "4 строки × блок + Sa."),
    "w_drain": ("Выгрузка MXU → TMEM", "≤ 2 FP32 за такт."),
    "w_dma": ("DMA ↔ TMEM", "LD / ST: 8 слов за такт."),
    "w_vpu": ("VPU ↔ TMEM", "VA, VB → VPU, запись: 8 слов за такт."),
    "w_q": ("TMEM → QUANT", "8 FP32 за такт (порты Q, Q2, Q3)."),
    "w_dstep": ("DSTEP / STREAM", "HBM → DMA → хвост VPU, минуя TMEM."),
    "w_ctl": ("otpu_ctrl → SEQ", "LOAD: PROG_ADDR, PROG_N; RUN: ARG0..7 → R8..R15; обратно HALTED / ERROR / icount."),
}

# плита
box("base", -14, -12, 404, 366, -8, 8, tone="mid", r=4, bevel=1.2, halo=True,
    inner=lambda c: screws(c, -14, -12, 404, 366, 0, 5) +
    "".join(line(c, [(x, 352, 0), (x, 349 - (3 if i % 5 == 0 else 1.6), 0)], "mid" if i % 5 == 0 else "lo")
            for i, x in enumerate(range(10, 381, 5))) +
    line(c, [(6, 349, 0), (384, 349, 0)], "lo") +
    text(c, -4, 337, 0, "otpu_slice · VCU128 · S = 1 · 100 МГц", 4.2, "mid"))
for fx, fy in ((-8, -6), (382, -6), (-8, 346), (382, 346)):
    box("base", fx - 4, fy - 4, 8, 8, -12, 4, tone="lo", r=2)

# otpu_ctrl
box("ctrl", 150, 14, 52, 44, 0, 9, r=1.5, bevel=0.6,
    inner=lambda c: dots(c, [(158 + i * 5, 24, 9) for i in range(8)], 0.6, "hi") +
    dots(c, [(158 + i * 5, 31, 9) for i in range(8)], 0.35, "lo") +
    text(c, 156, 46, 9, "otpu_ctrl", 4.4, "hi") + text(c, 156, 53, 9, "RUN · LOAD · ARG0..7", 3.0, "mid"))
rail("w_ctl", [(150, 40), (136, 40)], 2, tone="lo")

# SEQ
box("seq", 14, 14, 122, 96, 0, 7, r=2, bevel=0.8, inner=lambda c: screws(c, 14, 14, 122, 96, 7) +
    text(c, 20, 106, 7, "SEQ · otpu_seq", 4.4, "hi"))
for i in range(8):                                     # IMEM: пачка карт
    box("imem", 24, 24, 34, 30, 7 + i * 1.8, 1.3, tone="mid" if i < 7 else "hi", r=0.6,
        inner=(lambda c: text(c, 27, 33, 7 + 7 * 1.8 + 1.3, "IMEM", 4.2, "hi") +
               text(c, 27, 39, 7 + 7 * 1.8 + 1.3, "4096 × 256 бит", 3.0, "mid")) if i == 7 else None)
box("seq", 66, 24, 32, 30, 7, 7, r=1, inner=lambda c: dots(c, [(71 + (i % 4) * 7, 29 + (i // 4) * 6.5, 14) for i in range(16)], 0.55, "mid") +
    text(c, 69, 52, 14, "R0..R15", 3.0, "mid"))
box("imem", 106, 24, 22, 30, 7, 5, r=1, inner=lambda c: text(c, 108, 34, 12, "загр.", 3.2, "mid"))
box("win", 22, 62, 108, 40, 7, 2.5, tone="mid", r=1)
for i in range(16):                                    # окно WIN = 16
    box("win", 26 + i * 6.4, 67, 4, 26, 9.5, 9, r=0.4, cls=f"slot slot{i}")
box("win", 26, 95, 100, 5, 9.5, 1, tone="lo", r=0.3, inner=lambda c: text(c, 28, 99.6, 10.5, "окно WIN = 16 · табло RAW / WAR / WAW", 2.9, "mid"))

# память слайса: native_dram + 2 канала HBM
box("hbm", 262, 12, 116, 98, 0, 6, tone="mid", r=2, bevel=0.8, inner=lambda c: screws(c, 262, 12, 116, 98, 6) +
    text(c, 266, 106.5, 6, "otpu_native_dram · 2 канала → HBM", 3.4, "mid"))
for ch, x0 in ((0, 274), (1, 322)):
    for i in range(8):
        box("hbm", x0, 24, 44, 64, 6 + i * 2.8, 2.2, tone="mid", r=1.5)
    box("hbm", x0 - 1, 23, 46, 66, 6 + 8 * 2.8, 2.5, r=2, bevel=0.6,
        inner=(lambda c, x0=x0, ch=ch: text(c, x0 + 5, 41, 6 + 8 * 2.8 + 2.5, f"HBM · канал {ch}", 4.4, "hi") +
               text(c, x0 + 5, 48, 6 + 8 * 2.8 + 2.5, "beat 64 B", 3.2, "mid")))
box("portSW", 266, 110, 12, 4, 0, 5, r=0.6, inner=lambda c: text(c, 267.5, 113.4, 5, "SW", 2.8, "hi"))
box("portB", 290, 110, 22, 6, 0, 8.6, r=0.8, inner=lambda c: text(c, 292, 114.8, 8.6, "порт B", 3.4, "hi"))
box("portA", 340, 110, 12, 4, 0, 5, r=0.6, inner=lambda c: text(c, 344, 113.4, 5, "A", 2.8, "hi"))

# порт B — мостик (1024 бит) от HBM к FIFO MXU, ветви к DMA и к загрузчику SEQ
DECK = 7.0
B_MAIN = [(301, 116), (301, 124), (164, 124), (164, 146)]
rail("portB", B_MAIN, 8, z=DECK, h=1.6, tone="hi", flow=True)
rail("portB", [(256, 128), (256, 146)], 6, z=DECK, h=1.6, tone="hi")
rail("portB", [(160, 124), (117, 124), (117, 110)], 6, z=DECK, h=1.6, tone="hi")
posts("portB", [(301, 124), (210, 124), (256, 140), (135, 124)], DECK)
# порт A (32 B) — по плите к FIFO масштабов
rail("portA", [(346, 114), (346, 134.5), (215.5, 134.5), (215.5, 146)], 3, tone="hi")
# порт SW (32 бит) — от QUANT к HBM
rail("portSW", [(57, 140), (57, 118), (272, 118), (272, 114)], 2.4, tone="hi")

# MXU
box("mxu", 120, 146, 110, 136, 0, 3, tone="mid", r=2, bevel=0.6, inner=lambda c: screws(c, 120, 146, 110, 136, 3) +
    text(c, 124, 280.5, 3, "MXU · otpu_mxu · 2 команды", 3.8, "hi"))
box("fifo", 124, 150, 78, 24, 3, 2, tone="mid", r=0.8)
for i in range(16):
    box("fifo", 127 + i * 4.7, 153, 2.6, 18, 5, 10, r=0.3, cls=f"chunk chunk{i}")
box("fsc", 206, 150, 20, 24, 3, 2, tone="mid", r=0.8)
for i in range(6):
    box("fsc", 209, 153, 14, 18, 5 + i * 1.7, 1.2, tone="mid" if i < 5 else "hi", r=0.4)
box("arr", 124, 180, 86, 60, 3, 1.5, tone="lo", r=1)
for col in range(4):                                   # 4 колонки × 128 (показано 8 строк)
    for row in range(8):
        box("arr", 128 + col * 20.5, 183 + row * 7.0, 16, 5.0, 4.5, 4, r=0.5, cls=f"cell row{row}")
box("epi", 124, 246, 86, 30, 3, 9, r=1.2, bevel=0.6,
    inner=lambda c: line(c, [(140, 262, 12), (194, 262, 12)], "lo") + line(c, [(140, 268, 12), (194, 268, 12)], "lo") +
    dots(c, [(140, 262, 12), (194, 262, 12), (140, 268, 12), (194, 268, 12)], 0.45, "mid") +
    text(c, 128, 256, 12, "эпилог · 2 полосы → TMEM", 3.6, "hi"))
box("mxu", 214, 182, 12, 56, 3, 6, r=0.8, inner=lambda c: text(c, 217, 234, 9, "issuer", 3.0, "mid", along="y"))

# ACT RAM — шкаф из 4 строк
box("act", 18, 222, 78, 76, 0, 24, r=1.5, bevel=0.6, inner=lambda c: text(c, 22, 234, 24, "ACT RAM", 4.6, "hi") +
    text(c, 22, 241, 24, "4 строки × 128 блоков × 128 B", 3.0, "mid"))
for i in range(4):
    zz = 2 + i * 5.4
    box("act", 96, 228, 2.4, 64, zz, 4.2, tone="mid", r=0.3)
    box("act", 98.4, 256, 1.6, 8, zz + 1.4, 1.4, tone="hi", r=0.3)
rail("w_qact", [(57, 200), (57, 222)], 4, tone="hi")
rail("w_act", [(100, 258), (120, 258)], 4, tone="hi")

# QUANT
box("quant", 18, 140, 78, 60, 0, 14, r=1.5, bevel=0.6,
    inner=lambda c: "".join(line(c, [(26 + i * 6, 150, 14), (26 + i * 6, 176, 14)], "lo") for i in range(8)) +
    dots(c, [(26 + i * 6, 150, 14) for i in range(8)] + [(26 + i * 6, 176, 14) for i in range(8)], 0.4, "mid") +
    text(c, 24, 187, 14, "QUANT", 4.6, "hi") + text(c, 24, 194, 14, "8 FP32/такт · 2 прохода", 3.0, "mid"))

# DMA — каретка на направляющих
box("dma", 238, 146, 4, 58, 0, 3, tone="lo", r=0.6)
box("dma", 270, 146, 4, 58, 0, 3, tone="lo", r=0.6)
box("dma", 236, 156, 40, 34, 3, 11, r=1.5, bevel=0.6, inner=lambda c: text(c, 240, 169, 14, "DMA", 4.6, "hi") +
    text(c, 240, 176, 14, "128 B ↔ 8 сл./такт", 2.9, "mid") + screws(c, 236, 156, 40, 34, 14, 2.5))
rail("w_dma", [(254, 204), (254, 287)], 4, tone="hi")
rail("w_dstep", [(276, 175), (283, 175), (283, 212)], 2, tone="lo")

# VPU — 8 полос + дерево редукции
box("vpu", 288, 212, 86, 62, 0, 4, tone="mid", r=1.5, bevel=0.6, inner=lambda c: text(c, 292, 271.5, 4, "VPU · 8 полос FP32", 3.8, "hi"))
for i in range(8):
    box("vpu", 294, 217 + i * 6.2, 52, 3.6, 4, 4, r=1.6, cls=f"lane lane{i}")
box("vpu", 350, 216, 20, 50, 4, 11, r=1.2, inner=lambda c: text(c, 354, 262, 15, "SE · редукция", 3.2, "mid", along="y"))
rail("w_vpu", [(320, 274), (320, 287)], 4, tone="hi")

# TMEM — 8 банков и арбитр
box("arb", 128, 287, 236, 7, 0, 26, r=1, bevel=0.5,
    inner=lambda c: "".join(dots(c, [(138 + i * 16, 290.5, 26)], 0.6, "hi" if i == 0 else "mid") for i in range(5)) +
    text(c, 222, 292.6, 26, "арбитр банков · DMA > COLL > VPU > MXU > QUANT", 3.0, "mid"))
box("tmem", 128, 294, 236, 46, 0, 20, r=1.5, bevel=0.6, inner=lambda c: text(c, 136, 306, 20, "TMEM · 65536 × FP32 = 256 KiB", 4.6, "hi") +
    text(c, 136, 313, 20, "8 банков · адрес mod 8 · копия на порт чтения", 3.2, "mid"))
for b in range(8):
    x0 = 133 + b * 28.6
    box("tmem", x0, 340, 25, 2.4, 3, 13, tone="mid", r=0.4,
        inner=(lambda c, x0=x0, b=b: text(c, x0 + 12.5, 342.4, 14.6, f"банк {b}", 3.0, "mid", anchor="middle", side="y")))
    box("tmem", x0 + 8.5, 342.4, 8, 1.6, 6, 2, tone="hi", r=0.4)
rail("w_drain", [(167, 276), (167, 282)], 3, z=3, tone="hi")
rail("w_drain", [(167, 282), (167, 287)], 3, tone="hi")
rail("w_q", [(128, 291), (106, 291), (106, 171), (96, 171)], 3, z=5, h=1.2, tone="hi")
posts("w_q", [(106, 280), (106, 215)], 5, 2.4)

# порции 128 B на порту B (живые)
CHUNK = 5.0


def chunk_draw(cam):
    p = extrude(rounded(-CHUNK / 2, -CHUNK / 2, CHUNK, CHUNK, 0.4), 0, 2.4, cam)
    return solid_svg(p, lit=True)


def along(pts, f):
    L = [math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:])]
    s = f * sum(L)
    for (a, b), l in zip(zip(pts, pts[1:]), L):
        if s <= l:
            return (a[0] + (b[0] - a[0]) * s / l, a[1] + (b[1] - a[1]) * s / l)
        s -= l
    return pts[-1]


# ---------------------------------------------------------------- порядок отрисовки
def behind(a, b):
    """True, если a целиком позади b (зритель со стороны +x, +y, сверху)."""
    ax0, ay0, az0, ax1, ay1, az1 = a
    bx0, by0, bz0, bx1, by1, bz1 = b
    e = 1e-6
    if ax1 <= bx0 + e and not (bx1 <= ax0 + e):
        return True
    if ay1 <= by0 + e and not (by1 <= ay0 + e):
        return True
    if az1 <= bz0 + e and not (bz1 <= az0 + e):
        return True
    return False


VIEW = (CA * CE, SA * CE, SE)                          # к зрителю


def ray_exit(bx, sx, sy, cam):
    """Глубина ближней к зрителю точки тела bx на луче экранной точки (None — мимо)."""
    u = (sx - cam.ox) / cam.k
    w = (sy - cam.oy) / (cam.k * SE)
    p0 = (u * SA + w * CA, -u * CA + w * SA, 0.0)
    t0, t1 = -1e9, 1e9
    for ax in range(3):
        lo, hi, o, d = bx[ax], bx[ax + 3], p0[ax], VIEW[ax]
        if abs(d) < 1e-12:
            if o < lo or o > hi:
                return None
            continue
        a, b = (lo - o) / d, (hi - o) / d
        t0, t1 = max(t0, min(a, b)), min(t1, max(a, b))
    return t1 if t1 > t0 + 1e-9 else None


def ray_order(a, b, ra, rb, cam, n=7):
    """−1: a дальше (рисовать раньше), +1: b дальше, 0: на экране не перекрываются."""
    x0, y0, x1, y1 = max(ra[0], rb[0]), max(ra[1], rb[1]), min(ra[2], rb[2]), min(ra[3], rb[3])
    vote = 0
    for i in range(n):
        for j in range(n):
            sx, sy = x0 + (x1 - x0) * (i + .5) / n, y0 + (y1 - y0) * (j + .5) / n
            ta, tb = ray_exit(a, sx, sy, cam), ray_exit(b, sx, sy, cam)
            if ta is None or tb is None:
                continue
            vote += -1 if ta < tb - 1e-6 else (1 if tb < ta - 1e-6 else 0)
    return (vote > 0) - (vote < 0)


def order(items, cam):
    n = len(items)
    rects = []
    for it in items:
        x0, y0, z0, x1, y1, z1 = it["box"]
        pts = [cam.p(x, y, z) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        rects.append((min(xs), min(ys), max(xs), max(ys)))
    depth = [((it["box"][0] + it["box"][3]) / 2 + (it["box"][1] + it["box"][4]) / 2) * CE + (it["box"][2] + it["box"][5]) / 2 * SE
             for it in items]
    succ = [[] for _ in range(n)]
    indeg = [0] * n
    for i in range(n):
        for j in range(i + 1, n):
            ri, rj = rects[i], rects[j]
            if ri[2] <= rj[0] or rj[2] <= ri[0] or ri[3] <= rj[1] or rj[3] <= ri[1]:
                continue
            v = ray_order(items[i]["box"], items[j]["box"], ri, rj, cam)
            if v == 0:
                continue
            a, b = (i, j) if v < 0 else (j, i)
            succ[a].append(b)
            indeg[b] += 1
    import heapq
    heap = [(depth[i], i) for i in range(n) if indeg[i] == 0]
    heapq.heapify(heap)
    out = []
    while heap:
        _, i = heapq.heappop(heap)
        out.append(i)
        for j in succ[i]:
            indeg[j] -= 1
            if indeg[j] == 0:
                heapq.heappush(heap, (depth[j], j))
    if len(out) < n:                                   # цикл: остаток по глубине
        rest = sorted(set(range(n)) - set(out), key=lambda i: depth[i])
        print(f"warning: {len(rest)} items in a cycle, ordered by depth")
        out += rest
    return out


# ---------------------------------------------------------------- сборка
W, H = 1200, 860


def build():
    corners = []
    for it in ITEMS:
        x0, y0, z0, x1, y1, z1 = it["box"]
        corners += [(x, y, z) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]
    cam = fit(corners, W, H, 20)
    idx = order(ITEMS, cam)
    body = []
    last_b = max(k for k, i in enumerate(idx) if ITEMS[i]["block"] == "portB")
    for k, i in enumerate(idx):
        it = ITEMS[i]
        cls = f' class="part {it["cls"]}"' if it["cls"] else ' class="part"'
        body.append(f'<g{cls} data-block="{it["block"]}">{it["draw"](cam)}</g>')
        if k == last_b:
            body.append('<g id="chunks">' + "".join(f'<g class="ck" data-i="{n}" style="opacity:0">{chunk_draw(cam)}</g>'
                                                   for n in range(6)) + "</g>")
            still = []
            for f in (0.12, 0.45, 0.7, 0.93):              # для статичного SVG / PNG
                x, y = along(B_MAIN, f)
                a, b = cam.p(x, y, DECK + 1.6)
                a, b = a - cam.ox, b - cam.oy
                still.append(f'<g transform="translate({f1(a)} {f1(b)})">{chunk_draw(cam)}</g>')
            body.append('<g id="still">' + "".join(still) + "</g>")
    route = [(a - cam.ox, b - cam.oy) for a, b in (cam.p(x, y, DECK + 1.6) for x, y in B_MAIN)]
    return "".join(body), cam, route


THEMES = {
    "dark": {"page": "#0b0b0b", "card": "#131313", "text": "#a3a3a3", "muted": "#6e6e6e", "paper": "#131313",
             "top": "#1c1c1c", "s0": "#0f0f0f", "s1": "#121212", "s2": "#151515", "s3": "#181818",
             "littop": "#262626", "litshade": "#1d1d1d", "hi": "#d4d4d4", "mid": "#6a6a6a", "lo": "#3e3e3e",
             "faint": "#2a2a2a", "lit": "#ffffff", "halo": "#050505", "haloop": ".9", "dot": "#e6e6e6"},
    "light": {"page": "#f2f2ef", "card": "#fbfbfa", "text": "#57575a", "muted": "#8c8c90", "paper": "#fbfbfa",
              "top": "#ffffff", "s0": "#dcdcd9", "s1": "#e5e5e2", "s2": "#ededea", "s3": "#f4f4f1",
              "littop": "#ffffff", "litshade": "#eeeeeb", "hi": "#26262a", "mid": "#8a8a8f", "lo": "#b4b4b8",
              "faint": "#d4d4d6", "lit": "#000000", "halo": "#8a8a80", "haloop": ".32", "dot": "#3a3a3e"},
}


def css_vars(t):
    return ";".join(f"--{k}:{v}" for k, v in t.items())


FIG_CSS = """
.r-fill{fill:var(--paper)}.r-top{fill:var(--top)}.r-top-lit{fill:var(--littop)}
.r-shade0{fill:var(--s0)}.r-shade1{fill:var(--s1)}.r-shade2{fill:var(--s2)}.r-shade3{fill:var(--s3)}.r-shade-lit{fill:var(--litshade)}
.r-halo{fill:var(--halo);opacity:var(--haloop);filter:url(#halo)}
.r-line{fill:none;stroke-width:.6;stroke-linecap:round;stroke-linejoin:round;vector-effect:non-scaling-stroke}
.r-ring{fill:none;stroke-width:.5;vector-effect:non-scaling-stroke}
.t-hi{stroke:var(--hi)}.t-mid{stroke:var(--mid)}.t-lo{stroke:var(--lo)}.t-faint{stroke:var(--faint)}.t-lit{stroke:var(--lit)}
.r-ring.t-lo{stroke:var(--lo)}
.r-dot{fill:var(--dot);stroke:none;opacity:.45}.r-dot.t-hi{opacity:.85}.r-dot.t-lo{opacity:.22}
.r-text{stroke:none;font-family:ui-monospace,"SF Mono",Menlo,Consolas,"DejaVu Sans Mono",monospace;letter-spacing:.03em}
.r-text.t-hi{fill:var(--hi)}.r-text.t-mid{fill:var(--mid)}.r-text.t-lo{fill:var(--mid);opacity:.8}
"""

LIVE_CSS = """
#still{display:none}
.part.on .r-edge{stroke:var(--lit)}.part.on .r-top{fill:var(--littop)}
[data-block].hot .r-edge{stroke:var(--lit)}[data-block].hot .r-top{fill:var(--littop)}
.part{cursor:default}
"""

PAGE = """<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Слайс openTPU — изометрия</title>
<style>
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--text);font:14px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}
body[data-theme=dark]{__DARK__;color-scheme:dark}
body[data-theme=light]{__LIGHT__;color-scheme:light}
main{width:min(1180px,100% - 32px);margin:40px auto 64px}
.plate{position:relative;padding:52px 24px;background:var(--card);box-shadow:0 0 0 1px var(--mid)}
.corner{position:absolute;color:var(--muted);font:10.5px/1 ui-monospace,Menlo,Consolas,monospace;letter-spacing:.04em;white-space:nowrap}
.c-fig{top:18px;left:20px;color:var(--text)}.c-title{top:18px;right:20px;text-transform:uppercase;letter-spacing:.1em}
.c-hint{bottom:18px;left:20px;text-transform:uppercase;letter-spacing:.1em}.c-read{bottom:18px;right:20px;color:var(--text);font-variant-numeric:tabular-nums}
svg{display:block;width:100%;height:auto;overflow:visible}
.tip{position:absolute;max-width:340px;padding:10px 12px;background:var(--card);color:var(--text);box-shadow:0 0 0 1px var(--mid);
  font-size:12.5px;line-height:1.45;pointer-events:none;opacity:0;transition:opacity .15s}
.tip b{display:block;color:var(--hi);font-weight:600;margin-bottom:3px}
figcaption{margin-top:12px;color:var(--muted);font-size:13px;line-height:1.55}
.keys{display:flex;flex-wrap:wrap;gap:6px 18px;margin-bottom:6px}
__FIG__
__LIVE__
@media (max-width:560px){.plate{padding:48px 8px 70px}.c-hint{bottom:40px}}
</style></head>
<body data-theme="dark"><main><figure style="margin:0"><div class="plate" id="plate">
<span class="corner c-fig">Fig 1</span><span class="corner c-title">Слайс openTPU · VCU128</span>
<span class="corner c-hint">наведите на блок · T — тема</span><span class="corner c-read" id="read">порт B · 128 B/такт · 100 МГц</span>
__SVG__
<div class="tip" id="tip"></div></div>
<figcaption><div class="keys"><span>━ светлые полосы — данные (шире = больше бит/такт)</span><span>▣ мостик — порт B, 1024 бит</span><span>□ белые кубики — чанки 128 B</span></div>
Слайс (otpu_slice) — одна полная копия ядра openTPU: SEQ раздаёт инструкции, DMA, MXU, QUANT и VPU работают одновременно и
делят три ресурса — банки TMEM (арбитр DMA &gt; COLL &gt; VPU &gt; выгрузка MXU &gt; QUANT), порт B (128 B/такт: DMA, затем поток
весов MXU) и порты A / SW. Массив MXU показан 4 колонки × 8 строк вместо 128. Источник: doc/slice.md, diagrams/slice_structure.dot.</figcaption>
</figure></main>
<script>
const INFO=__INFO__, ROUTE=__ROUTE__;
const svg=document.querySelector('svg'), tip=document.getElementById('tip'), read=document.getElementById('read'), plate=document.getElementById('plate');
const base=read.textContent;
let hot=null;
function show(b,e){ if(hot===b) return; document.querySelectorAll('[data-block].hot').forEach(n=>n.classList.remove('hot'));
  hot=b; if(!b||b==='base'){tip.style.opacity=0;read.textContent=base;hot=null;return;}
  document.querySelectorAll('[data-block="'+b+'"]').forEach(n=>n.classList.add('hot'));
  const [t,d]=INFO[b]; tip.innerHTML='<b>'+t+'</b>'+d; tip.style.opacity=1; read.textContent=t; }
svg.addEventListener('pointermove',e=>{const g=e.target.closest('[data-block]'); show(g&&g.dataset.block,e);
  if(hot){const r=plate.getBoundingClientRect(); let x=e.clientX-r.left+16, y=e.clientY-r.top+16;
  if(x+350>r.width) x=e.clientX-r.left-356; tip.style.left=x+'px'; tip.style.top=y+'px';}});
svg.addEventListener('pointerleave',()=>show(null));
document.addEventListener('keydown',e=>{if(e.key==='t'||e.key==='T'){document.body.dataset.theme=document.body.dataset.theme==='dark'?'light':'dark';}});
// живое: чанки 128 B идут по порту B в FIFO, FIFO заполняется, массив проходит строки, окно SEQ двигается
const reduce=matchMedia('(prefers-reduced-motion: reduce)').matches;
const seg=[];let total=0;for(let i=1;i<ROUTE.length;i++){const l=Math.hypot(ROUTE[i][0]-ROUTE[i-1][0],ROUTE[i][1]-ROUTE[i-1][1]);seg.push(l);total+=l;}
function at(s){for(let i=0;i<seg.length;i++){if(s<=seg[i]||i===seg.length-1){const t=Math.min(1,s/seg[i]);return [ROUTE[i][0]+(ROUTE[i+1][0]-ROUTE[i][0])*t,ROUTE[i][1]+(ROUTE[i+1][1]-ROUTE[i][1])*t];} s-=seg[i];}}
const cks=[...document.querySelectorAll('#chunks .ck')], slots=[...document.querySelectorAll('.chunk')], wins=[...document.querySelectorAll('.slot')];
const rows=[0,1,2,3,4,5,6,7].map(r=>[...document.querySelectorAll('.cell.row'+r)]);
let visible=true; new IntersectionObserver(es=>{visible=es[0].isIntersecting}).observe(svg);
const T0=performance.now(), PERIOD=900;
function frame(now){ if(visible){ const t=(now-T0);
  cks.forEach((c,i)=>{const s=((t/PERIOD+i/cks.length)%1); const [x,y]=at(s*total); c.setAttribute('transform','translate('+x.toFixed(1)+' '+y.toFixed(1)+')');
     c.style.opacity=(s<.06? s/.06 : s>.94 ? (1-s)/.06 : 1).toFixed(2);});
  const arrived=Math.floor(t/PERIOD*cks.length);
  const fill=arrived%20; slots.forEach((n,i)=>n.classList.toggle('on', i<Math.min(fill,16)));
  const r=Math.floor(t/160)%8; rows.forEach((row,k)=>row.forEach(n=>n.classList.toggle('on',k===r)));
  const w=Math.floor(t/700)%16; wins.forEach((n,k)=>n.classList.toggle('on',k===w)); }
  requestAnimationFrame(frame);}
if(!reduce) requestAnimationFrame(frame); else { cks.forEach(c=>c.style.opacity=0); }
</script></body></html>"""


def main():
    body, cam, route = build()
    halo = '<defs><filter id="halo" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="9"/></filter></defs>'
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img" '
           f'aria-label="Изометрическая схема слайса openTPU">{halo}{body}</svg>')
    page = (PAGE.replace("__DARK__", css_vars(THEMES["dark"])).replace("__LIGHT__", css_vars(THEMES["light"]))
            .replace("__FIG__", FIG_CSS).replace("__LIVE__", LIVE_CSS).replace("__SVG__", svg)
            .replace("__INFO__", json.dumps(INFO, ensure_ascii=False))
            .replace("__ROUTE__", json.dumps([[round(a, 1), round(b, 1)] for a, b in route])))
    (HERE / "slice_isometric.html").write_text(page)
    # статичный SVG: светлая тема, переменные подставлены (Inkscape и просмотрщики без CSS-переменных)
    t = THEMES["light"]
    css = FIG_CSS
    for k, v in sorted(t.items(), key=lambda kv: -len(kv[0])):
        css = css.replace(f"var(--{k})", v)
    css = css.replace("vector-effect:non-scaling-stroke", "")
    bg = f'<rect width="{W}" height="{H}" fill="{t["card"]}"/>'
    hide = '<style>' + css + '#chunks{display:none}</style>'
    static = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
              f'aria-label="Изометрическая схема слайса openTPU">{hide}{halo}{bg}{body}</svg>')
    (HERE / "slice_isometric.svg").write_text(static)
    print(f"{len(ITEMS)} parts; wrote slice_isometric.html, slice_isometric.svg")


if __name__ == "__main__":
    main()
