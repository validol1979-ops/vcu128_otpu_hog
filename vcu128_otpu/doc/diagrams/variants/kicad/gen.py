#!/usr/bin/env python3
"""Структурная схема слайса openTPU (otpu_slice, конфигурация VCU128) в KiCad 10.

Содержание — из ../../slice_structure.dot и ../../slice.md (тот же набор блоков, подписей и
связей). Блоки — свои символы-прямоугольники с выводами-портами (локальная библиотека
slice_blocks.kicad_sym), связи — провода: сплошные — данные (подпись — ширина за такт),
пунктир — управление, точки — обходные пути; стрелки — направление. Группы SEQ / MXU / TMEM /
otpu_slice — рамки. Правки только здесь: файл .kicad_sch пересоздаётся.

    python3 gen.py            # пишет slice_kicad.kicad_sch, slice_blocks.kicad_sym, sym-lib-table
"""
import os
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT, LIB = 'slice_kicad', 'slice_blocks'
NS = uuid.UUID('5a1c3e00-7f2b-4d1e-9c11-0b6a2f6d4e21')
G = 1.27                  # сетка
CH = 1.12                 # ширина знака шрифта 1,27 мм (замер по экспорту KiCad 10)
PITCH = 2.54              # шаг строк в блоке


def U(key):
    return str(uuid.uuid5(NS, key))


def S(v):
    return round(round(v / G) * G, 4)


def f(v):
    v = round(v, 4)
    return ('%.4f' % v).rstrip('0').rstrip('.') if v != int(v) else str(int(v))


def q(s):
    return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def col(h, a=1):
    r, g, b = rgb(h)
    return f'(color {r} {g} {b} {a})'


# ------------------------------------------------------------------ содержание (из .dot)
TEXT = {
    'ctrl': ['otpu_ctrl (s_ctl 0x00000)', 'CTRL: RUN / LOAD / CLEAR · ARG0..7',
             'STATUS · счётчики · буфер трассы'],
    'coll': ['otpu_coll (общий на S слайсов)', 'BAR · GATHER: сегменты слайсов →',
             'TMEM всех слайсов'],
    'dram': ['память слайса: otpu_native_dram', '2 канала (beat 64 B, чередование + CHASH)',
             '→ otpu_mem_ch ×2 → otpu_hbm_port ×2 → HBM'],
    'loader': ['загрузчик программы', 'HBM → IMEM, 1 чанк = 4 инстр./такт',
               '(старт и HALT CHAIN)'],
    'imem': ['IMEM 4096 инструкций × 256 бит', 'чтение на такт вперёд'],
    'dec': ['выборка + декод: 1 инстр./такт', 'R0..R15, LI / ADDI / LOOP (до 4 уровней)',
            'w1..w3 += R[ra..rc]'],
    'win': ['окно WIN = 16 + табло', 'отпечатки диапазонов TMEM / HBM / ACT',
            'RAW / WAR / WAW → старт самой старой готовой'],
    'dma': ['DMA — otpu_dma', 'LD / ST: чанк 128 B ↔ 8 слов FP32/такт',
            'буфер LD 128 чанков · WAITW · DSTEP/STREAM'],
    'iss': ['issuer (ustart)', 'запросы N×KB чанков + строк масштабов'],
    'cfifo': ['FIFO чанков', '1024 × 128 B'],
    'sfifo': ['FIFO масштабов', 'Sw, dw по блокам'],
    'arr': ['систолический массив (urel)', '4 колонки × 128 INT8·INT8',
            'цепочки DSP48E2 по 16 · точная целая сумма'],
    'epi': ['FIFO результатов → эпилог, 2 полосы', 'i2f · ×Sw · ×Sa·2⁻¹⁶ · ACC / ASCALE / RMAX'],
    'act': ['ACT RAM — otpu_actram', '4 строки × 128 блоков × 128 B INT8',
            '+ {da, Sa} на (строку, блок)'],
    'quant': ['QUANT — otpu_quant', '8 FP32/такт, 2 прохода (max → коды)',
              'буфер строки 1024 чанка · CSCALE / RSCALE'],
    'vpu': ['VPU — otpu_vpu', '8 полос FP32 (простые) + составные',
            '(exp2, recip, rsqrt, log2) · дерево редукции', 'SE: хвост stream engine (DeltaNet)'],
    'arb': ['арбитр банков (каждый такт, всё-или-ничего)',
            'приоритет: DMA > COLL > VPU > MXU drain > QUANT'],
    'tm': ['65536 × FP32 = 256 KiB, 8 банков (адрес mod 8)', 'на FPGA — копия на каждый порт чтения',
           '8 портов чтения: MXU, DMA, Q, VA, VB, Q2, Q3, COLL', '4 порта записи: DMA, MXU, COLL, VPU'],
    'portb': ['порт B', '128 B/такт (1024 бит)', 'DMA, затем поток MXU, загрузчик'],
    'porta': ['порт A', 'строки 32 B', 'масштабы MXU'],
    'portsw': ['порт SW', '32 бит/такт + маска байт', 'QST (KV)'],
}
FILL = {'ctrl': '#e6f4ea', 'coll': '#e6f4ea', 'dram': '#ffe3d6', 'loader': '#f0e6ff', 'imem': '#f0e6ff',
        'dec': '#f0e6ff', 'win': '#f0e6ff', 'dma': '#eef3f8', 'iss': '#fff0e0', 'cfifo': '#fff0e0',
        'sfifo': '#fff0e0', 'arr': '#fff0e0', 'epi': '#fff0e0', 'act': '#fff4d6', 'quant': '#e9f7ec',
        'vpu': '#e7f0ff', 'arb': '#dff0ff', 'tm': '#dff0ff', 'portb': '#ffe3d6', 'porta': '#ffe3d6',
        'portsw': '#ffe3d6'}
EDGE = '#396484'

# Размещение: центр блока (мм, y вниз, лист A3). Ширина — по тексту (не меньше MINW).
POS = {
    'ctrl': (286, 23), 'coll': (375, 165), 'dram': (379, 132),
    'loader': (286, 51), 'imem': (286, 64), 'dec': (286, 77), 'win': (286, 92),
    'portsw': (311, 123), 'porta': (311, 137), 'portb': (311, 153),
    'dma': (311, 172), 'vpu': (311, 193),
    'quant': (49, 123), 'act': (45, 143),
    'iss': (174, 166), 'cfifo': (110, 184), 'sfifo': (215, 184),
    'arr': (50, 201), 'epi': (128, 233.5),
    'arb': (291, 218), 'tm': (291, 237),
}
MINW = {'loader': 55.88, 'imem': 55.88, 'dec': 55.88, 'win': 55.88, 'portsw': 40.64,
        'porta': 40.64, 'portb': 40.64, 'dram': 53.34}
MINH = {'dram': 25.4, 'arb': 12.7}

# Рамки групп: (x0, y0, x1, y1, подпись, цвет, место подписи)
FRAMES = [
    (13.97, 31.75, 350.52, 250.19, 'otpu_slice', EDGE, (16, 105.4)),
    (237.49, 36.83, 320.04, 100.33, 'SEQ — otpu_seq', '#8a63c6', (289.5, 41)),
    (19.05, 157.48, 233.68, 241.3, 'MXU — otpu_mxu (2 команды в работе)', '#d77b12', (21, 239.4)),
    (241.3, 208.28, 346.71, 245.11, 'TMEM — otpu_tmem', '#1971c2', (322, 212.6)),
]

# Стили связей: цвет, толщина, тип линии
DATA = ('#396484', 0.25, 'solid')
DATA_MXU = ('#d77b12', 0.5, 'solid')
DATA_MXU_THIN = ('#d77b12', 0.25, 'solid')
DATA_Q = ('#2b8a3e', 0.5, 'solid')
DATA_Q_THIN = ('#2b8a3e', 0.25, 'solid')
DATA_VPU = ('#1971c2', 0.3, 'solid')
DATA_DMA = ('#555555', 0.3, 'solid')
DATA_COLL = ('#7a7a7a', 0.25, 'solid')
CTRL = ('#396484', 0.25, 'dash')
DISP = ('#8a63c6', 0.25, 'dash')
DOT = ('#555555', 0.25, 'dot')
DOT_MXU = ('#d77b12', 0.25, 'dot')
TM = (EDGE, 0.4, 'solid')

SLICE_NOTCH = (233.68, 101.6)  # угол выреза рамки otpu_slice (x, y)
TY = 107.95          # магистраль раздачи команд окном (один провод-дерево)
# Связи: (откуда, куда, путь, стиль, стрелки, подпись, место подписи)
#   конец — (блок, сторона, координата): сторона L/R — y вывода, T/B — x; или точка (x, y) на проводе;
#   путь — повороты ('x', v) / ('y', v); последний отрезок подходит к выводу по нормали;
#   стрелки: '>' к концу, '<' к началу, '<>' обе, '' нет;
#   место подписи: (x, y — базовая линия, выравнивание) или None — без подписи.
LINKS = [
    # управление
    (('ctrl', 'B', 285.75), ('loader', 'T', 285.75), [], CTRL, '>', 'LOAD: PROG_ADDR, PROG_N', (284.2, 30.4, 'right')),
    (('ctrl', 'L', 24.13), ('dec', 'L', 77.47), [('x', 250.19)], CTRL, '>', 'RUN · ARG0..7 → R8..R15', (243.6, 23.6, 'right')),
    (('win', 'L', 92.71), ('ctrl', 'L', 20.32), [('x', 245.11)], CTRL, '>', 'HALTED / ERROR / icount', (243.6, 19.8, 'right')),
    (('loader', 'B', 285.75), ('imem', 'T', 285.75), [], CTRL, '>', '', None),
    (('imem', 'B', 285.75), ('dec', 'T', 285.75), [], CTRL, '>', '', None),
    (('dec', 'B', 285.75), ('win', 'T', 285.75), [], CTRL, '>', '', None),
    # раздача команд окном: дерево с магистралью y = TY
    (('win', 'B', 285.75), (285.75, TY), [], DISP, '', '', None),
    ((44.45, TY), (345.44, TY), [], DISP, '', 'команды из окна (старт по готовности)', (120, 106.9, 'left')),
    ((44.45, TY), ('quant', 'T', 44.45), [], DISP, '>', '', None),
    ((80.01, TY), ('iss', 'L', 166.37), [('y', 166.37)], DISP, '>', '', None),
    ((80.01, 166.37), ('arr', 'R', 198.12), [('y', 198.12)], DISP, '>', 'urel', (81.5, 196.9, 'left')),
    ((345.44, TY), ('coll', 'L', 165.1), [('y', 165.1)], DISP, '>', 'BAR / GATHER', (355, 158.4, 'left')),
    ((345.44, 165.1), ('dma', 'R', 171.45), [('y', 171.45)], DISP, '>', '', None),
    ((345.44, 171.45), ('vpu', 'R', 191.77), [('y', 191.77)], DISP, '>', '', None),
    # порты памяти
    (('portsw', 'R', 123.19), ('dram', 'L', 123.19), [], DATA, '>', 'запись слов', (353, 117.6, 'left')),
    (('dram', 'L', 137.16), ('porta', 'R', 137.16), [], DATA, '>', 'чтение', (332.8, 136.1, 'left')),
    (('portb', 'R', 155.58), ('dram', 'L', 142.24), [('x', 342.9)], DATA, '<>', 'чтение / запись чанков', (353, 149.4, 'left')),
    (('portb', 'R', 150.5), ('loader', 'R', 50.8), [('x', 340.36)], DATA, '>', 'программа', (338.9, 75, 'right')),
    (('portb', 'B', 311.15), ('dma', 'T', 311.15), [], DATA, '<>', 'LD / ST', (312.6, 163.7, 'left')),
    (('portb', 'L', 150.5), ('cfifo', 'T', 109.22), [('x', 109.22)], DATA_MXU, '>', 'веса, K-строки, Vᵀ', (111, 149.3, 'left')),
    (('iss', 'T', 186.69), ('portb', 'L', 154.31), [('y', 154.31)], CTRL, '>', 'запросы', (250, 153.2, 'left')),
    (('iss', 'T', 160.02), ('porta', 'L', 134.62), [('y', 134.62)], CTRL, '>', 'запросы масштабов', (250, 133.5, 'left')),
    (('porta', 'L', 139.7), ('sfifo', 'T', 214.63), [('x', 214.63)], DATA_MXU_THIN, '>', 'строки масштабов', (250, 141.6, 'left')),
    # внутри MXU
    (('cfifo', 'L', 184.15), ('arr', 'R', 201.93), [('x', 87.63)], DATA_MXU, '>', '1 чанк/такт', (89, 194, 'left')),
    (('sfifo', 'B', 214.63), ('epi', 'T', 143.51), [('y', 224.79)], DATA_MXU_THIN, '>', '', None),
    (('act', 'B', 44.45), ('arr', 'T', 44.45), [], DATA_MXU, '>', '4 строки × блок + Sa', (46, 172, 'left')),
    (('arr', 'B', 49.53), ('epi', 'T', 115.57), [('y', 220.98)], DATA_MXU, '>', '', None),
    (('epi', 'R', 236.22), ('arb', 'L', 217.17), [('x', 248.92)], DATA_MXU, '>', '≤ 2 FP32/такт', (160, 239.6, 'left')),
    (('arb', 'L', 214.63), ('epi', 'R', 232.41), [('x', 245.11)], DOT_MXU, '>', 'ACC/ASCALE: старое значение', (160, 231.4, 'left')),
    # остальные блоки с TMEM
    (('dma', 'L', 171.45), ('arb', 'T', 274.32), [('x', 274.32)], DATA_DMA, '<>', '8 слов/такт', (272.9, 196, 'right')),
    (('arb', 'L', 220.98), ('quant', 'L', 123.19), [('x', 252.73), ('y', 247.65), ('x', 16.51)], DATA_Q_THIN, '>', '8 FP32/такт из TMEM (Q, Q2, Q3)', (30, 246.4, 'left')),
    (('quant', 'B', 44.45), ('act', 'T', 44.45), [], DATA_Q, '>', 'QACT: 8 B/такт + {da, Sa}', (46, 133.3, 'left')),
    (('quant', 'R', 123.19), ('portsw', 'L', 123.19), [], DATA_Q, '>', 'QST', (180, 122.1, 'left')),
    (('vpu', 'B', 311.15), ('arb', 'T', 311.15), [], DATA_VPU, '<>', 'VA, VB → запись: 8 слов/такт', (312.6, 206.5, 'left')),
    (('dma', 'B', 311.15), ('vpu', 'T', 311.15), [], DOT, '>', 'DSTEP / STREAM (минуя TMEM)', (309.6, 183.9, 'right')),
    (('coll', 'B', 377.19), ('arb', 'R', 217.17), [('y', 217.17)], DATA_COLL, '<>', 'GATHER; RLD → R[rd]', (352.5, 216.1, 'left')),
    (('arb', 'B', 291.08), ('tm', 'T', 291.08), [], TM, '<>', '', None),
]


# ------------------------------------------------------------------ геометрия блоков
class Block:
    def __init__(self, name):
        self.name, self.lines = name, TEXT[name]
        x, y = POS[name]
        w = max(max(len(s) for s in self.lines) * CH + 5, MINW.get(name, 0))
        h = max(len(self.lines) * PITCH + PITCH, MINH.get(name, 0))
        self.x0, self.y0 = S(x - w / 2), S(y - h / 2)
        self.x1, self.y1 = S(x + w / 2), S(y + h / 2)
        self.pins = []        # (сторона, координата)

    @property
    def c(self):
        return S((self.x0 + self.x1) / 2), S((self.y0 + self.y1) / 2)

    def pin_end(self, side, v):
        """Точка подключения провода: вывод нулевой длины на краю блока."""
        v = S(v)
        if side == 'L':
            assert self.y0 < v < self.y1, (self.name, side, v)
            return self.x0, v
        if side == 'R':
            assert self.y0 < v < self.y1, (self.name, side, v)
            return self.x1, v
        assert self.x0 < v < self.x1, (self.name, side, v)
        return (v, self.y0) if side == 'T' else (v, self.y1)

    def add_pin(self, side, v):
        k = (side, S(v))
        if k not in self.pins:
            self.pins.append(k)
        return self.pin_end(side, v)

    def symbol(self):
        cx, cy = self.c
        lx = lambda X: X - cx
        ly = lambda Y: cy - Y            # библиотека: y вверх
        body = [f'(rectangle (start {f(lx(self.x0))} {f(ly(self.y0))}) (end {f(lx(self.x1))} {f(ly(self.y1))}) '
                f'(stroke (width 0.254) (type default) {col(EDGE)}) (fill (type color) {col(FILL[self.name])}))']
        n = len(self.lines)
        top = cy - (n - 1) * PITCH / 2
        for i, s in enumerate(self.lines):
            bold = ' (bold yes)' if i == 0 else ''
            body.append(f'(text {q(s)} (at 0 {f(ly(top + i * PITCH))} 0) '
                        f'(effects (font (size 1.27 1.27){bold} {col("#1f2d3a")})))')
        for i, (side, v) in enumerate(self.pins, 1):
            ex, ey = self.pin_end(side, v)
            rot = {'L': 0, 'R': 180, 'T': 270, 'B': 90}[side]
            body.append(f'(pin passive line (at {f(lx(ex))} {f(ly(ey))} {rot}) (length 0) '
                        f'(name "~" (effects (font (size 1.27 1.27)))) '
                        f'(number {q(i)} (effects (font (size 1.27 1.27)))))')
        nm = 'blk_' + self.name
        props = ''.join(f'(property {q(k)} {q(v)} (at 0 0 0) (effects (font (size 1.27 1.27)) (hide yes)))'
                        for k, v in (('Reference', '#B'), ('Value', nm), ('Footprint', ''),
                                     ('Datasheet', ''), ('Description', ' / '.join(self.lines))))
        return (nm, f'(symbol {{NAME}} (pin_names (offset 0) (hide yes)) (pin_numbers (hide yes)) '
                    f'(exclude_from_sim yes) (in_bom no) (on_board no) {props} '
                    f'(symbol {q(nm + "_1_1")} ' + ' '.join(body) + '))')


# ------------------------------------------------------------------ провода
def path(a, b, via, bside):
    pts = [a]
    for axis, v in via:
        x, y = pts[-1]
        pts.append((S(v), y) if axis == 'x' else (x, S(v)))
    x, y = pts[-1]
    bx, by = b
    if x != bx and y != by:          # последний отрезок — по нормали к выводу
        pts.append((bx, y) if bside in ('T', 'B') else (x, by))
    pts.append(b)
    out = [pts[0]]
    for p in pts[1:]:
        if p != out[-1]:
            out.append(p)
    for (x1, y1), (x2, y2) in zip(out, out[1:]):
        assert x1 == x2 or y1 == y2, f'неортогональный отрезок {out}'
    return out


def arrow(tip, frm, color, items, key):
    """Закрашенный треугольник с вершиной в tip, направлен от frm к tip."""
    (tx, ty), (fx, fy) = tip, frm
    L, W = 2.2, 0.9
    if tx == fx:
        d = 1 if ty > fy else -1
        pts = [(tx, ty), (tx - W, ty - d * L), (tx + W, ty - d * L)]
    else:
        d = 1 if tx > fx else -1
        pts = [(tx, ty), (tx - d * L, ty - W), (tx - d * L, ty + W)]
    pts.append(pts[0])
    items.append('(polyline (pts ' + ' '.join(f'(xy {f(x)} {f(y)})' for x, y in pts) + ') '
                 f'(stroke (width 0.05) (type solid) {col(color)}) (fill (type color) {col(color)}) '
                 f'(uuid {q(U("arrow" + key))}))')


def main():
    blocks = {n: Block(n) for n in TEXT}
    items, junctions, wires = [], {}, set()

    def text(x, y, s, size=1.27, color='#444444', just='left', bold=False, key=''):
        b = ' (bold yes)' if bold else ''
        items.append(f'(text {q(s)} (exclude_from_sim no) (at {f(x)} {f(y)} 0) '
                     f'(effects (font (size {size} {size}){b} {col(color)}) (justify {just} bottom)) '
                     f'(uuid {q(U("text" + key + s + f(x) + f(y)))}))')

    for i, (fa, fb, via, style, arrows, label, lpos) in enumerate(LINKS):
        end = lambda e: blocks[e[0]].add_pin(e[1], e[2]) if isinstance(e[0], str) else (S(e[0]), S(e[1]))
        a, b = end(fa), end(fb)
        pts = path(a, b, via, fb[1] if isinstance(fb[0], str) else None)
        color, width, kind = style
        for p, r in zip(pts, pts[1:]):
            seg = (min(p, r), max(p, r))
            if seg in wires:
                continue
            wires.add(seg)
            items.append(f'(wire (pts (xy {f(p[0])} {f(p[1])}) (xy {f(r[0])} {f(r[1])})) '
                         f'(stroke (width {width}) (type {kind}) {col(color)}) '
                         f'(uuid {q(U(f"w{i}" + f(p[0]) + f(p[1]) + f(r[0]) + f(r[1])))}))')
        # стрелки — у края блока (вывод длиной в одну клетку)
        edge = lambda end, nxt: end      # стрелка — вершиной в край блока
        if '>' in arrows:
            arrow(edge(pts[-1], pts[-2]), pts[-2], color, items, f'{i}>')
        if '<' in arrows:
            arrow(edge(pts[0], pts[1]), pts[1], color, items, f'{i}<')
        for p in pts:
            junctions[p] = junctions.get(p, 0) + 1
        if label:
            if lpos is None:
                p, r = max(zip(pts, pts[1:]), key=lambda s: abs(s[0][0] - s[1][0]) + abs(s[0][1] - s[1][1]))
                lpos = ((p[0] + r[0]) / 2, (p[1] + r[1]) / 2 - 0.8, 'left')
            text(lpos[0], lpos[1], label, color='#3a3a3a', just=lpos[2], key=f'l{i}')

    # точки соединения (три и больше направлений в точке; не на концах выводов)
    pins_at = {b.pin_end(sd, v) for b in blocks.values() for sd, v in b.pins}
    deg = {}
    for (p, r) in wires:
        deg[p] = deg.get(p, 0) + 1
        deg[r] = deg.get(r, 0) + 1
    # провод, проходящий через точку, тоже считается (середина отрезка)
    for (p, r) in wires:
        for pt in deg:
            if pt not in (p, r) and (p[0] == r[0] == pt[0] and min(p[1], r[1]) < pt[1] < max(p[1], r[1]) or
                                     p[1] == r[1] == pt[1] and min(p[0], r[0]) < pt[0] < max(p[0], r[0])):
                deg[pt] += 2
    for pt, n in deg.items():
        if n >= 3 and pt not in pins_at:
            items.append(f'(junction (at {f(pt[0])} {f(pt[1])}) (diameter 0.9) (color 0 0 0 0) '
                         f'(uuid {q(U("j" + f(pt[0]) + f(pt[1])))}))')

    for k, (x0, y0, x1, y1, label, color, lp) in enumerate(FRAMES):
        if k == 0:       # otpu_slice: Г-образная рамка, слева сверху — легенда
            cx, cy = SLICE_NOTCH
            pts = [(x0, cy), (cx, cy), (cx, y0), (x1, y0), (x1, y1), (x0, y1), (x0, cy)]
            for j, ((a, b), (c, d)) in enumerate(zip(pts, pts[1:])):   # замкнутая ломаная — фигура,
                items.append(f'(polyline (pts (xy {f(S(a))} {f(S(b))}) (xy {f(S(c))} {f(S(d))})) '  # её KiCad
                             f'(stroke (width 0.35) (type solid) {col(color)}) (fill (type none)) '  # рисует
                             f'(uuid {q(U("frame" + label + str(j)))}))')                          # пунктиром
        else:
            items.append(f'(rectangle (start {f(S(x0))} {f(S(y0))}) (end {f(S(x1))} {f(S(y1))}) '
                         f'(stroke (width 0.3) (type dash) {col(color)}) '
                         f'(fill (type none)) (uuid {q(U("frame" + label))}))')
        text(lp[0], lp[1], label, size=1.6, color=color, bold=True, key='frame')

    text(16, 19, 'Слайс openTPU (otpu_slice) на VCU128: S = 1, D = 128, MCOLS = 4, LANES = 8, '
                 'WIN = 16, core_clk 100 МГц', size=2.0, color='#1f2d3a', bold=True, key='title')
    text(16, 24, 'Сплошные — данные (подпись — ширина за такт), пунктир — управление, точки — '
                   'обходные пути. Источник: slice_structure.dot, slice.md.',
         size=1.27, color='#444444', key='sub')
    # легенда
    lx, ly = 16, 40
    text(lx, ly, 'Обозначения', size=1.5, color='#1f2d3a', bold=True, key='leg')
    for j, (style, s) in enumerate(((DATA_MXU, 'поток весов MXU'), (DATA_Q, 'QUANT: QACT, QST'),
                                    (DATA, 'данные (порты, программа)'), (CTRL, 'управление ctrl / SEQ'),
                                    (DISP, 'раздача команд окном'), (DOT, 'обходной путь'))):
        x0, y = lx + (j % 2) * 105, ly + 6 + (j // 2) * 6
        color, width, kind = style
        items.append(f'(polyline (pts (xy {f(x0)} {f(y)}) (xy {f(x0 + 14)} {f(y)})) '
                     f'(stroke (width {width}) (type {kind}) {col(color)}) (fill (type none)) '
                     f'(uuid {q(U("leg" + s))}))')
        text(x0 + 16, y + 0.7, s, color='#333333', key='leg')

    # символы и экземпляры
    root = U('root')
    libsyms, insts, libfile = [], [], []
    for n, b in enumerate(blocks.values(), 1):
        nm, body = b.symbol()
        libsyms.append(body.replace('{NAME}', q(f'{LIB}:{nm}'), 1))
        libfile.append(body.replace('{NAME}', q(nm), 1))
        cx, cy = b.c
        key = 'inst' + b.name
        ref = f'#B{n:02d}'
        props = ''.join(f'(property {q(k)} {q(v)} (at {f(cx)} {f(cy)} 0) (effects (font (size 1.27 1.27)) (hide yes)))'
                        for k, v in (('Reference', ref), ('Value', nm), ('Footprint', ''), ('Datasheet', '')))
        pins = ' '.join(f'(pin {q(i)} (uuid {q(U(key + str(i)))}))' for i in range(1, len(b.pins) + 1))
        insts.append(f'(symbol (lib_id {q(f"{LIB}:{nm}")}) (at {f(cx)} {f(cy)} 0) (unit 1) (exclude_from_sim yes) '
                     f'(in_bom no) (on_board no) (dnp no) (uuid {q(U(key))}) {props} {pins} '
                     f'(instances (project {q(PROJECT)} (path {q("/" + root)} (reference {q(ref)}) (unit 1)))))')

    sch = os.path.join(HERE, f'{PROJECT}.kicad_sch')
    with open(sch, 'w', encoding='utf-8') as fh:
        fh.write(f'(kicad_sch (version 20250114) (generator "eeschema") (generator_version "9.0") '
                 f'(uuid {q(root)}) (paper "A3") '
                 f'(title_block (title "Слайс openTPU (otpu_slice), VCU128 — структурная схема") '
                 f'(date "2026-10-20") (rev "1") (company "vcu128_otpu_hog") '
                 f'(comment 1 "Из doc/diagrams/slice_structure.dot и doc/slice.md; генератор variants/kicad/gen.py"))\n'
                 '(lib_symbols\n')
        for s in libsyms:
            fh.write('  ' + s + '\n')
        fh.write(')\n')
        for it in items + insts:
            fh.write('  ' + it + '\n')
        fh.write('(sheet_instances (path "/" (page "1"))) (embedded_fonts no))\n')
    with open(os.path.join(HERE, f'{LIB}.kicad_sym'), 'w', encoding='utf-8') as fh:
        fh.write('(kicad_symbol_lib (version 20241209) (generator "slice_gen")\n')
        for s in libfile:
            fh.write('  ' + s + '\n')
        fh.write(')\n')
    with open(os.path.join(HERE, 'sym-lib-table'), 'w', encoding='utf-8') as fh:
        fh.write(f'(sym_lib_table (version 7)\n  (lib (name "{LIB}")(type "KiCad")'
                 f'(uri "${{KIPRJMOD}}/{LIB}.kicad_sym")(options "")(descr "Блоки слайса openTPU"))\n)\n')
    pro = os.path.join(HERE, f'{PROJECT}.kicad_pro')
    if not os.path.exists(pro):
        with open(pro, 'w', encoding='utf-8') as fh:
            fh.write('{\n  "meta": {"filename": "%s.kicad_pro", "version": 3},\n  "sheets": [],\n'
                     '  "text_variables": {}\n}\n' % PROJECT)
    print(f'ok: {len(blocks)} блоков, {len(LINKS)} связей, {len(wires)} отрезков → {sch}')


if __name__ == '__main__':
    main()
