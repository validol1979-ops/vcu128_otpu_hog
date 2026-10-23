"""Температура ПЛИС (SYSMON каждого SLR) и HBM, термоконтроль VCU128: чтение, пороги, флаги.

Регистры — окно платформы 0x40000, 0x20…0x5C (vcu128_thermal, doc/design.md
«Температура и контроль»). Транспорт — любой объект с reg_read / reg_write /
reg_read_many (EthTransport по 40G, Board.t, эмулятор); то же по JTAG —
tools/jtag/thermal.tcl.

    python vcu128_otpu/tools/otpu_temp.py                    # одно чтение
    python vcu128_otpu/tools/otpu_temp.py --watch 2          # опрос раз в 2 с
    python vcu128_otpu/tools/otpu_temp.py --fpga 85 100 10 --hbm 85 95 5
    python vcu128_otpu/tools/otpu_temp.py --clear --clear-max --resume
    python vcu128_otpu/tools/otpu_temp.py --act off          # без удержания ядра
    python vcu128_otpu/tools/otpu_temp.py --force on         # проверка действия (HOLD)

Адрес платы — --host или OTPU_ETH_HOST (по умолчанию 192.168.41.2). С платой одновременно
работает одна программа: во время инференса этот опрос мешает только тем, что делит канал
регистров (одно чтение — пачка из ~20 регистров).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

PLAT = 0x40000
STATUS = 0x04
TH_INFO, TH_CTRL, TH_STATUS, TH_FPGA_LIM, TH_HBM_LIM = 0x20, 0x24, 0x28, 0x2C, 0x30
TH_EVENTS, TH_RAW, TH_ABORTS, T_SLR, T_HBM, V_SLR = 0x34, 0x38, 0x3C, 0x40, 0x4C, 0x50
NSLR = 3
SENSORS = ("SLR0", "SLR1", "SLR2", "HBM0", "HBM1")

CTRL_BITS = {"act": 1, "auto": 2, "cattrip": 4, "force": 8}
RESUME, CLR_FLAGS, CLR_MAX = 1 << 8, 1 << 9, 1 << 10
ST_BITS = ("warn", "alarm", "cattrip", "hold", "warn_l", "alarm_l", "cattrip_l", "hold_l",
           "cool", "valid", "drp_err")


def code_to_c(code12: int) -> float:
    """Код SYSMONE4 (12 бит, [15:4] регистра состояния) -> °C (UG580, внутренняя опора);
    та же формула, что у upstream opentpu.host.regs.temp_c(code, "xilinxus")."""
    return (code12 & 0xFFF) * 509.3140064 / 4096 - 280.2308787


def _q4(v: int) -> float | None:
    v &= 0xFFFF
    if v == 0x8000:
        return None
    return (v - 0x10000 if v & 0x8000 else v) / 16


def _lim(v: int) -> dict:
    return {"warn": v & 0xFF, "alarm": (v >> 8) & 0xFF, "hyst": (v >> 16) & 0xFF}


def read(t) -> dict:
    """Всё о температуре одной пачкой регистров."""
    offs = [STATUS, TH_INFO, TH_CTRL, TH_STATUS, TH_FPGA_LIM, TH_HBM_LIM, TH_EVENTS, TH_RAW,
            TH_ABORTS, T_HBM] + [T_SLR + 4 * s for s in range(NSLR)] + \
           [V_SLR + 4 * s for s in range(NSLR)]
    v = dict(zip(offs, t.reg_read_many([PLAT + o for o in offs])))
    info = v[TH_INFO]
    if not info >> 16 & 1:
        raise RuntimeError(f"no thermal monitor in this bitstream (TH_INFO {info:#x})")
    st = v[TH_STATUS]
    d = {"version": (info >> 8) & 0xFF, "slrs": info & 0xF, "master_slr": (info >> 4) & 0xF,
         "ctrl": {k: bool(v[TH_CTRL] & b) for k, b in CTRL_BITS.items()},
         "status": {k: bool(st >> i & 1) for i, k in enumerate(ST_BITS)},
         "warn_sensors": [n for i, n in enumerate(SENSORS) if st >> (16 + i) & 1],
         "alarm_sensors": [n for i, n in enumerate(SENSORS) if st >> (24 + i) & 1],
         "fpga_lim": _lim(v[TH_FPGA_LIM]), "hbm_lim": _lim(v[TH_HBM_LIM]),
         "holds": v[TH_EVENTS] & 0xFFFF, "warns": v[TH_EVENTS] >> 16,
         "aborts": v[TH_ABORTS] & 0xFFFF,
         "raw_code": v[TH_RAW] & 0xFFF, "ot": [bool(v[TH_RAW] >> (16 + s) & 1) for s in range(NSLR)],
         "board_status": v[STATUS], "slr": [], "hbm": []}
    d["r_temp_c"] = round(code_to_c(d["raw_code"]), 2) if d["raw_code"] else None
    for s in range(NSLR):
        x, y = v[T_SLR + 4 * s], v[V_SLR + 4 * s]
        d["slr"].append({"temp_c": _q4(x), "max_c": _q4(x >> 16),
                         "vccint": round((y & 0x3FF) * 3 / 1024, 4),
                         "vccaux": round((y >> 10 & 0x3FF) * 3 / 1024, 4),
                         "vccbram": round((y >> 20 & 0x3FF) * 3 / 1024, 4)})
    h = v[T_HBM]
    for k in range(2):
        d["hbm"].append({"temp_c": h >> (8 * k) & 0xFF, "max_c": h >> (16 + 8 * k) & 0xFF})
    for s in d["slr"]:                  # no reading yet (maximum 0x8000)
        if s["max_c"] is None:
            s["temp_c"] = None
    return d


def _ctrl_word(t, **kw) -> int:
    cur = t.reg_read(PLAT + TH_CTRL) & 0xF
    for k, on in kw.items():
        if on is None:
            continue
        cur = cur | CTRL_BITS[k] if on else cur & ~CTRL_BITS[k]
    return cur


def set_ctrl(t, act=None, auto=None, cattrip=None, force=None, resume=False, clear=False,
             clear_max=False) -> None:
    """Биты TH_CTRL (None — не менять) и однократные команды."""
    w = _ctrl_word(t, act=act, auto=auto, cattrip=cattrip, force=force)
    w |= (RESUME if resume else 0) | (CLR_FLAGS if clear else 0) | (CLR_MAX if clear_max else 0)
    t.reg_write(PLAT + TH_CTRL, w)


def set_limits(t, fpga: tuple | None = None, hbm: tuple | None = None) -> None:
    """Пороги (warn, alarm, hyst) в °C. Проверки: warn <= alarm, alarm < 125 (аппаратный OT
    SYSMON ПЛИС), hyst < alarm."""
    for off, lim in ((TH_FPGA_LIM, fpga), (TH_HBM_LIM, hbm)):
        if lim is None:
            continue
        w, a, h = (int(x) for x in lim)
        if not (0 <= w <= a < 125 and 0 <= h < a):
            raise ValueError(f"limits {lim}: need 0 <= warn <= alarm < 125, 0 <= hyst < alarm")
        t.reg_write(PLAT + off, h << 16 | a << 8 | w)


def _f(x) -> str:
    return "  —  " if x is None else f"{x:6.2f}"


def format_report(d: dict) -> str:
    st = d["status"]
    flags = " ".join(k.upper() for k in ("warn", "alarm", "cattrip", "hold") if st[k]) or "норма"
    sticky = " ".join(k[:-2].upper() for k in ("warn_l", "alarm_l", "cattrip_l", "hold_l")
                      if st[k]) or "—"
    lines = [f"Термоконтроль v{d['version']}: {d['slrs']} SLR (master SLR{d['master_slr']}); "
             f"сейчас: {flags}; защёлки: {sticky}" + ("; ОШИБКА DRP" if st["drp_err"] else "")]
    for i, s in enumerate(d["slr"]):
        lines.append(f"  SLR{i}  {_f(s['temp_c'])} °C  max {_f(s['max_c'])}   VCCINT "
                     f"{s['vccint']:.3f} В  VCCAUX {s['vccaux']:.3f} В  VCCBRAM {s['vccbram']:.3f} В"
                     + ("  OT!" if d["ot"][i] else ""))
    for i, h in enumerate(d["hbm"]):
        lines.append(f"  HBM{i}  {h['temp_c']:6d} °C  max {h['max_c']:6d}")
    fl, hl = d["fpga_lim"], d["hbm_lim"]
    c = d["ctrl"]
    lines.append(f"  пороги ПЛИС {fl['warn']}/{fl['alarm']} °C (гист. {fl['hyst']}), HBM "
                 f"{hl['warn']}/{hl['alarm']} °C (гист. {hl['hyst']}); действие "
                 f"{'вкл' if c['act'] else 'выкл'}, автовозврат {'вкл' if c['auto'] else 'выкл'}, "
                 f"CATTRIP {'вкл' if c['cattrip'] else 'выкл'}" + (", FORCE_HOLD" if c["force"] else ""))
    lines.append(f"  удержаний {d['holds']}, остановок CTRL {d['aborts']}, предупреждений "
                 f"{d['warns']}; R_TEMP {d['raw_code']:#05x} = {_f(d['r_temp_c'])} °C"
                 + (f"; тревога: {','.join(d['alarm_sensors'])}" if d["alarm_sensors"] else "")
                 + (f"; предупреждение: {','.join(d['warn_sensors'])}" if d["warn_sensors"] else ""))
    if st["hold"]:
        lines.append("  ЯДРО УДЕРЖАНО: RUN/LOAD не принимаются (STATUS CALIB читается 0); "
                     + ("возврат — после охлаждения ниже alarm − гист. и --resume"
                        if not c["auto"] else "возврат автоматически после охлаждения"))
    return "\n".join(lines)


def _onoff(s: str | None):
    if s is None:
        return None
    if s.lower() in ("on", "1", "yes", "вкл"):
        return True
    if s.lower() in ("off", "0", "no", "выкл"):
        return False
    raise argparse.ArgumentTypeError(f"on/off: {s}")


def main(argv=None, transport=None) -> int:
    ap = argparse.ArgumentParser(description="VCU128: температура ПЛИС/HBM и термоконтроль")
    ap.add_argument("--host", default=os.environ.get("OTPU_ETH_HOST", "192.168.41.2"))
    ap.add_argument("--watch", type=float, metavar="S", help="опрос с интервалом S секунд")
    ap.add_argument("--count", type=int, default=0, help="с --watch: число опросов (0 — без конца)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--fpga", nargs=3, type=int, metavar=("WARN", "ALARM", "HYST"))
    ap.add_argument("--hbm", nargs=3, type=int, metavar=("WARN", "ALARM", "HYST"))
    for k in CTRL_BITS:
        ap.add_argument(f"--{k}", type=_onoff, metavar="on|off")
    ap.add_argument("--resume", action="store_true", help="снять удержание (если остыло)")
    ap.add_argument("--clear", action="store_true", help="сбросить защёлки")
    ap.add_argument("--clear-max", action="store_true", help="сбросить максимумы")
    a = ap.parse_args(argv)

    own = transport is None
    if own:
        from otpu_eth import EthTransport
        transport = EthTransport(a.host)
    t = transport
    try:
        if a.fpga or a.hbm:
            set_limits(t, a.fpga, a.hbm)
        if any(getattr(a, k) is not None for k in CTRL_BITS) or a.resume or a.clear or a.clear_max:
            set_ctrl(t, act=a.act, auto=a.auto, cattrip=a.cattrip, force=a.force,
                     resume=a.resume, clear=a.clear, clear_max=a.clear_max)
        n = 0
        while True:
            d = read(t)
            if a.json:
                print(json.dumps(d, ensure_ascii=False))
            else:
                if a.watch:
                    print(time.strftime("%H:%M:%S"), end=" ")
                print(format_report(d))
            sys.stdout.flush()
            n += 1
            if not a.watch or (a.count and n >= a.count):
                break
            time.sleep(a.watch)
    except KeyboardInterrupt:
        pass
    finally:
        if own:
            t.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
