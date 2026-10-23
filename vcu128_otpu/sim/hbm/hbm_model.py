"""Модель портов Xilinx HBM IP (AXI3, 256 бит) для тестов otpu_hbm_port.

Каналы чтения и записи независимы: каждое чтение выполняется (читает память) в свой случайный
момент после AR, каждая запись -- в свой после AW и всех W; поэтому чтение, выданное после
записи, может быть выполнено раньше неё (как в HBM, где AR и AW не упорядочены). R и B
возвращаются в произвольном порядке между разными ID (в порядке для одного ID), R разных ID
могут чередоваться по словам. Обратное давление на AW, W, AR -- случайное, паузы на R и B --
случайные. Проверки протокола копятся в self.errors.
"""

import os
import random

MASK64 = (1 << 64) - 1
MASK256 = (1 << 256) - 1
CH_SIZE = 1 << 31                 # канал при PCB 3; размер по PCB -- HbmModel.ch_size


def default_word(waddr):
    """Начальное содержимое 32-байтного слова по его байтовому адресу (детерминированное)."""
    x = (waddr >> 5) & MASK64
    v = 0
    for i in range(4):
        x = (x * 6364136223846793005 + 1442695040888963407 + i) & MASK64
        y = x ^ (x >> 29)
        y = (y * 0xBF58476D1CE4E5B9) & MASK64
        v |= (y ^ (y >> 32)) << (64 * i)
    return v


def default_beat(addr):
    """64-байтный beat по адресу HBM: слово по addr -- младшие 256 бит."""
    return default_word(addr) | (default_word(addr + 32) << 256)


PCB = int(os.environ.get("HBM_PCB", "3"))   # log2 псевдоканалов в канале (otpu_hbm_port PCB)


def hbm_map(beat, ch_base=0, gran=0, xor=True, pcb=None):
    """Номер beat канала -> глобальный байтовый адрес HBM (зеркало otpu_hbm_amap)."""
    g, p = gran, PCB if pcb is None else pcb
    m = (1 << p) - 1
    pc = (beat >> g) & m
    if xor:
        pc ^= (beat >> (g + p)) & m
    off = (((beat >> (g + p)) << g) | (beat & ((1 << g) - 1))) & ((1 << 22) - 1)
    return (ch_base & ~((1 << (28 + p)) - 1)) | (pc << 28) | (off << 6)


def hbm_sub(beat, ns, gran=0, xor=True, pcb=None):
    """Подпорт (AXI-порт native-порта) beat: старшие log2(ns) бит номера псевдоканала
    (зеркало sub_of в otpu_hbm_port)."""
    if ns == 1:
        return 0
    p = PCB if pcb is None else pcb
    m = (1 << p) - 1
    pc = (beat >> gran) & m
    if xor:
        pc ^= (beat >> (gran + p)) & m
    return pc >> (p - (ns.bit_length() - 1))


def apply_strobe(old, new, strb, nbytes):
    out = old
    for k in range(nbytes):
        if (strb >> k) & 1:
            m = 0xFF << (8 * k)
            out = (out & ~m) | (new & m)
    return out


class Memory:
    """Память HBM по 32-байтным словам (ключ -- байтовый адрес слова)."""

    def __init__(self):
        self.words = {}

    def read(self, waddr):
        w = self.words.get(waddr)
        return default_word(waddr) if w is None else w

    def write(self, waddr, data, strb):
        if strb == (1 << 32) - 1:
            self.words[waddr] = data
        else:
            self.words[waddr] = apply_strobe(self.read(waddr), data, strb, 32)


class Cfg:
    """Параметры случайности модели (вероятности 0..1, задержки в тактах uclk)."""

    def __init__(self, **kw):
        self.p_awready = 0.7
        self.p_wready = 0.7
        self.p_arready = 0.7
        self.p_rgap = 0.2          # такт без R, когда есть что отдать
        self.p_bgap = 0.3
        self.rlat = (2, 60)        # AR -> выполнение чтения
        self.wlat = (2, 60)        # последний W (и AW) -> выполнение записи
        self.blat = (0, 20)        # выполнение записи -> B готов
        self.interleave = True     # чередовать R разных ID
        self.p_rerr = 0.0          # RRESP = SLVERR
        self.p_berr = 0.0          # BRESP = SLVERR
        self.stall = (0.0, 0, 0)   # (вероятность, мин, макс): все ready = 0 на N тактов
        for k, v in kw.items():
            if not hasattr(self, k):
                raise KeyError(k)
            setattr(self, k, v)

    @staticmethod
    def fast(lat=40):
        """Без обратного давления и пауз, фиксированная задержка: предел адаптера."""
        return Cfg(p_awready=1.0, p_wready=1.0, p_arready=1.0, p_rgap=0.0, p_bgap=0.0,
                   rlat=(lat, lat), wlat=(lat, lat), blat=(0, 0), interleave=False)


class PortModel:
    def __init__(self, p, mem, rng, cfg, ch_base, errors):
        self.p, self.mem, self.rng, self.cfg, self.errors = p, mem, rng, cfg, errors
        self.ch_size = 1 << (28 + PCB)
        self.ch_base = ch_base & ~(self.ch_size - 1)
        self.aw = []              # принятые AW: (id, addr), ждут W
        self.wb = []              # принятые W: (data, strb, last, wid)
        self.wq = []              # записи к выполнению: (t, id, addr, beats)
        self.rq = []              # чтения к выполнению: (t, id, addr)
        self.rr = []              # выполненные чтения: [id, [слова], индекс, resp]
        self.bq = []              # выполненные записи: (t, id, resp)
        self.last_rt = {}
        self.last_bt = {}
        self.stall_until = -1
        # выходы модели (вход DUT) в текущем такте
        self.awready = self.wready = self.arready = 0
        self.rvalid = 0
        self.rcur = None          # (запись rr, слово)
        self.bvalid = 0
        self.bcur = None
        # счётчики
        self.n_ar = self.n_aw = self.n_r = self.n_b = 0
        self.w_before_aw = 0
        self.overtakes = 0        # чтение выполнено раньше записи, принятой до него
        self.on_ar = None
        self.on_aw = None

    def err(self, msg):
        if len(self.errors) < 50:
            self.errors.append(f"порт {self.p}: {msg}")

    def check_ax(self, kind, addr, ln, size, burst):
        if ln != 1 or size != 5 or burst != 1:
            self.err(f"{kind}: LEN {ln} SIZE {size} BURST {burst}")
        if addr & 63:
            self.err(f"{kind}: адрес {addr:#x} не кратен 64")
        if not (self.ch_base <= addr < self.ch_base + self.ch_size):
            self.err(f"{kind}: адрес {addr:#x} вне канала {self.ch_base:#x}")

    def step(self, now, s):
        """s -- выходы DUT порта в этом такте; обработать рукопожатия, вычислить выходы модели."""
        rng, cfg = self.rng, self.cfg
        # ---- рукопожатия этого такта
        if s["arvalid"] and self.arready:
            self.check_ax("AR", s["araddr"], s["arlen"], s["arsize"], s["arburst"])
            rid = s["arid"]
            t = now + rng.randint(*cfg.rlat)
            t = max(t, self.last_rt.get(rid, -1) + 1)
            self.last_rt[rid] = t
            self.rq.append((t, rid, s["araddr"], now))
            self.n_ar += 1
            if self.on_ar:
                self.on_ar(self.p, s["araddr"], rid)
        if s["awvalid"] and self.awready:
            self.check_ax("AW", s["awaddr"], s["awlen"], s["awsize"], s["awburst"])
            self.aw.append((s["awid"], s["awaddr"], now))
            self.n_aw += 1
            if self.on_aw:
                self.on_aw(self.p, s["awaddr"], s["awid"])
        if s["wvalid"] and self.wready:
            if len(self.wb) >= 2 * len(self.aw):
                self.w_before_aw += 1
            self.wb.append((s["wdata"], s["wstrb"], s["wlast"], s.get("wid")))
        if self.rvalid and s["rready"]:
            e, k = self.rcur
            e[2] += 1
            self.n_r += 1
            if e[2] == len(e[1]):
                self.rr.remove(e)
            self.rcur = None
        if self.bvalid and s["bready"]:
            self.bq.remove(self.bcur)
            self.n_b += 1
            self.bcur = None
        # ---- пакеты записи собраны: AW + 2 W
        while self.aw and len(self.wb) >= 2:
            wid, addr, ta = self.aw.pop(0)
            beats = [self.wb.pop(0), self.wb.pop(0)]
            if beats[0][2] or not beats[1][2]:
                self.err(f"WLAST не на втором слове (AWID {wid})")
            for b in beats:
                if b[3] is not None and b[3] != wid:
                    self.err(f"WID {b[3]} != AWID {wid}")
            t = now + rng.randint(*cfg.wlat)
            self.wq.append((t, wid, addr, beats, ta))
        # ---- выполнение: чтения и записи в свои моменты (порядок между ними -- по времени)
        due = [x for x in self.wq if x[0] <= now]
        if due:
            self.wq = [x for x in self.wq if x[0] > now]
        due_r = [x for x in self.rq if x[0] <= now]
        if due_r:
            self.rq = [x for x in self.rq if x[0] > now]
        ops = [(x[0], 1, x) for x in due] + [(x[0], 0, x) for x in due_r]
        rng.shuffle(ops)
        ops.sort(key=lambda o: o[0])
        for _, isw, x in ops:
            if isw:
                t, wid, addr, beats, _ = x
                for i, (d, strb, _, _) in enumerate(beats):
                    self.mem.write(addr + 32 * i, d, strb)
                resp = 2 if rng.random() < cfg.p_berr else 0
                tb = max(now + rng.randint(*cfg.blat), self.last_bt.get(wid, -1) + 1)
                self.last_bt[wid] = tb
                self.bq.append((tb, wid, resp))
            else:
                t, rid, addr, ta = x
                self.overtakes += sum(1 for y in self.wq if y[4] < ta) + \
                    sum(1 for y in self.aw if y[2] < ta)
                words = [self.mem.read(addr), self.mem.read(addr + 32)]
                resp = 2 if rng.random() < cfg.p_rerr else 0
                self.rr.append([rid, words, 0, resp])
        # ---- выходы следующего такта
        if now < self.stall_until:
            self.awready = self.wready = self.arready = 0
        else:
            pr, mn, mx = cfg.stall
            if pr and rng.random() < pr:
                self.stall_until = now + rng.randint(mn, mx)
            self.awready = int(rng.random() < cfg.p_awready)
            self.wready = int(rng.random() < cfg.p_wready)
            self.arready = int(rng.random() < cfg.p_arready)
        if self.rcur is None:
            self.rvalid = 0
            if self.rr and rng.random() >= cfg.p_rgap:
                # для каждого ID -- только старейшее; без чередования -- начатый пакет первым
                started = [e for e in self.rr if 0 < e[2]]
                if started and not cfg.interleave:
                    cand = started[:1]
                else:
                    seen, cand = set(), []
                    for e in self.rr:
                        if e[0] not in seen:
                            seen.add(e[0])
                            cand.append(e)
                    if not cfg.interleave:
                        cand = cand[:1]
                e = rng.choice(cand)
                self.rcur = (e, e[2])
                self.rvalid = 1
        if self.bcur is None:
            self.bvalid = 0
            ready = [b for b in self.bq if b[0] <= now]
            if ready and rng.random() >= cfg.p_bgap:
                seen, cand = set(), []
                for b in sorted(self.bq, key=lambda b: b[0]):
                    if b[1] not in seen:
                        seen.add(b[1])
                        if b[0] <= now:
                            cand.append(b)
                if cand:
                    self.bcur = rng.choice(cand)
                    self.bvalid = 1

    def busy(self):
        return bool(self.aw or self.wb or self.wq or self.rq or self.rr or self.bq)

    def r_out(self):
        if self.rcur is None:
            return 0, 0, 0, 0
        e, k = self.rcur
        return e[0], e[1][k], e[3], int(k == len(e[1]) - 1)

    def b_out(self):
        if self.bcur is None:
            return 0, 0
        return self.bcur[1], self.bcur[2]


def _field(v, p, w):
    return (v >> (p * w)) & ((1 << w) - 1)


class HbmModel:
    """nports портов HBM на упакованных сигналах DUT m_*[nports-1:0][...] (домен uclk)."""

    def __init__(self, dut, rng, cfg, ch_base=0, nports=2, prefix="m_"):
        self.dut, self.rng, self.n = dut, rng, nports
        self.mem = Memory()
        self.errors = []
        self.ports = [PortModel(p, self.mem, rng, cfg, ch_base, self.errors) for p in range(nports)]
        g = lambda name: getattr(dut, prefix + name)
        self.h = {k: g(k) for k in (
            "awvalid", "awaddr", "awid", "awlen", "awsize", "awburst", "wvalid", "wdata", "wstrb",
            "wlast", "wid", "bready", "arvalid", "araddr", "arid", "arlen", "arsize", "arburst",
            "rready", "awready", "wready", "arready", "rvalid", "rid", "rdata", "rresp", "rlast",
            "bvalid", "bid", "bresp")}
        self.widths = {"awaddr": 33, "araddr": 33, "awid": 6, "arid": 6, "wid": 6, "awlen": 4,
                       "arlen": 4, "awsize": 3, "arsize": 3, "awburst": 2, "arburst": 2,
                       "wdata": 256, "wstrb": 32}
        self.drive_idle()

    def set_cfg(self, cfg):
        for pm in self.ports:
            pm.cfg = cfg

    def drive_idle(self):
        for k in ("awready", "wready", "arready", "rvalid", "rid", "rdata", "rresp", "rlast",
                  "bvalid", "bid", "bresp"):
            self.h[k].value = 0

    def drive(self):
        """Выходы модели на входы DUT (после фронта)."""
        aw = w = ar = rv = rl = bv = 0
        rid = rdata = rresp = bid = bresp = 0
        for pm in self.ports:
            p = pm.p
            aw |= pm.awready << p
            w |= pm.wready << p
            ar |= pm.arready << p
            rv |= pm.rvalid << p
            bv |= pm.bvalid << p
            i, d, rs, last = pm.r_out()
            rid |= i << (6 * p)
            rdata |= d << (256 * p)
            rresp |= rs << (2 * p)
            rl |= last << p
            i, rs = pm.b_out()
            bid |= i << (6 * p)
            bresp |= rs << (2 * p)
        h = self.h
        h["awready"].value = aw
        h["wready"].value = w
        h["arready"].value = ar
        h["rvalid"].value = rv
        h["rid"].value = rid
        h["rdata"].value = rdata
        h["rresp"].value = rresp
        h["rlast"].value = rl
        h["bvalid"].value = bv
        h["bid"].value = bid
        h["bresp"].value = bresp

    def sample_step(self, now):
        """В ReadOnly: прочитать выходы DUT, обработать такт."""
        h = self.h
        v = {k: h[k].value.to_unsigned() for k in (
            "awvalid", "wvalid", "arvalid", "bready", "rready")}
        if not (v["awvalid"] or v["wvalid"] or v["arvalid"]):
            vals = None
        else:
            vals = {k: h[k].value.to_unsigned() for k in (
                "awaddr", "awid", "awlen", "awsize", "awburst", "wdata", "wstrb", "wlast", "wid",
                "araddr", "arid", "arlen", "arsize", "arburst")}
        for pm in self.ports:
            p = pm.p
            s = {"awvalid": (v["awvalid"] >> p) & 1, "wvalid": (v["wvalid"] >> p) & 1,
                 "arvalid": (v["arvalid"] >> p) & 1, "bready": (v["bready"] >> p) & 1,
                 "rready": (v["rready"] >> p) & 1}
            if vals is not None:
                for k, x in vals.items():
                    s[k] = _field(x, p, self.widths.get(k, 1))
            pm.step(now, s)

    def busy(self):
        return any(pm.busy() for pm in self.ports)
