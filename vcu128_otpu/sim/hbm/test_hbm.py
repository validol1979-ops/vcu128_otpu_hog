"""pytest: сборка (Verilator) и запуск cocotb-тестов otpu_hbm_port и связки otpu_mem_ch +
otpu_hbm_port; полный перебор отображения адресов (tb_amap, verilator --binary); проверка
чувствительности тестов (мутант без зависимостей по beat должен упасть). Всё в out/."""

import json
import os
import re
import subprocess
from pathlib import Path
import xml.etree.ElementTree as ET

import pytest
from cocotb_tools.runner import get_runner

SIM = Path(__file__).resolve().parent
SRC = SIM.parents[1] / "src"
HBM = SRC / "hbm/otpu_hbm_port.sv"
SHELL = SRC / "otpu-fesens/rtl/shell"
OUT = SIM / "out"
N = os.environ.get("HBM_N", "20000")
SEED = os.environ.get("SEED", "1")

# конфигурации DUT: параметры RTL и окружение теста
CONFIGS = {
    "base": dict(params={}, env=dict(HBM_CH_BASE="0", HBM_PC_GRAN="0", HBM_PC_XOR="1")),
    "small": dict(params={"CH_BASE": "33'h180000000", "PC_GRAN": 2, "RD": 8, "WD": 4, "WQ": 4,
                          "AQ": 2},
                  env=dict(HBM_CH_BASE="0x180000000", HBM_PC_GRAN="2", HBM_PC_XOR="1")),
    "big": dict(params={"CH_BASE": "33'h080000000", "PC_GRAN": 5, "PC_XOR": 0, "RD": 64,
                        "WD": 64, "WQ": 16, "AQ": 8},
                env=dict(HBM_CH_BASE="0x80000000", HBM_PC_GRAN="5", HBM_PC_XOR="0")),
}
VFLAGS = ["-Wno-fatal", "-Wno-lint", "-Wno-style", "-O3"]


def build(name, sources, top, params):
    runner = get_runner("verilator")
    runner.build(sources=sources, hdl_toplevel=top, build_dir=OUT / f"build_{name}",
                 parameters=params, timescale=("1ns", "1ps"), build_args=VFLAGS, waves=False,
                 log_file=OUT / f"build_{name}.log")
    return runner


def run(runner, top, module, case, tag, env):
    xml = OUT / f"{tag}.xml"
    log = OUT / f"{tag}.log"
    xml.unlink(missing_ok=True)
    try:
        runner.test(hdl_toplevel=top, test_module=module, testcase=case, test_dir=OUT,
                    results_xml=str(xml), waves=False, log_file=log,
                    extra_env={"PYTHONDONTWRITEBYTECODE": "1", "HBM_OUT": str(OUT), "HBM_N": N,
                               "SEED": SEED, "HBM_TAG": tag, **env})
    except SystemExit as exc:
        if exc.code and not xml.exists():
            raise AssertionError(f"{tag}: код {exc.code}, журнал {log}") from exc
    root = ET.parse(xml).getroot()
    fails = [tc.get("name") for tc in root.iter("testcase")
             if tc.find("failure") is not None or tc.find("error") is not None]
    return fails, log


@pytest.fixture(scope="session")
def runners():
    OUT.mkdir(exist_ok=True)
    return {}


def get(runners, name):
    if name not in runners:
        runners[name] = build(name, [HBM], "otpu_hbm_port", CONFIGS[name]["params"])
    return runners[name]


UNIT = [("base", c) for c in ("random_traffic", "hazard_pairs", "resp_errors", "stream_read",
                              "stream_write", "stream_mixed", "stream_read_lat100")] + \
       [(k, c) for k in ("small", "big") for c in ("random_traffic", "hazard_pairs",
                                                   "resp_errors", "stream_read")]


@pytest.mark.parametrize("cfg,case", UNIT)
def test_port(runners, cfg, case):
    fails, log = run(get(runners, cfg), "otpu_hbm_port", "cocotb_hbm_port", case,
                     f"{cfg}_{case}", CONFIGS[cfg]["env"])
    assert not fails, f"{fails}: {log}"


MUTANTS = {
    # голова не ждёт ничего
    "nodep": [("assign h_go  = h_v && h_ok &&", "assign h_go  = h_v &&")],
    # запись не ждёт чтений того же beat (нет WAR)
    "nowar": [("a_rdep <= c_cmd_we[p] ? ((c_rm & ~r_fr) | (eq_c ? al_rv : '0)) : '0;",
               "a_rdep <= '0;"),
              ("((eq_a && a_we) ? al_rv : '0)", "'0"),
              ("!(eq_a && (al_w || (al_r && a_we)))", "!(eq_a && al_w)")],
    # чтение не ждёт записей того же beat (нет RAW; WAW остаётся)
    "noraw": [("a_wdep <= (c_wm & ~w_fr) | (eq_c ? al_wv : '0);",
               "a_wdep <= c_cmd_we[p] ? ((c_wm & ~w_fr) | (eq_c ? al_wv : '0)) : '0;"),
              ("(eq_a ? al_wv : '0)", "((eq_a && a_we) ? al_wv : '0)"),
              ("!(eq_a && (al_w || (al_r && a_we)))", "!(eq_a && a_we && (al_w || al_r))")],
}


@pytest.mark.parametrize("mut", list(MUTANTS))
def test_mutant(runners, mut):
    """Испорченный механизм зависимостей обязан быть пойман случайным тестом (по данным)."""
    src = HBM.read_text()
    for x, y in MUTANTS[mut]:
        assert src.count(x) == 1, x
        src = src.replace(x, y)
    path = OUT / f"otpu_hbm_port_{mut}.sv"
    path.write_text(src)
    r = build(f"mutant_{mut}", [path], "otpu_hbm_port", {})
    fails, log = run(r, "otpu_hbm_port", "cocotb_hbm_port", "random_traffic", f"mutant_{mut}",
                     {**CONFIGS["base"]["env"], "HBM_N": "4000"})
    assert fails == ["random_traffic"], f"мутант не пойман: {log}"
    assert "ожидалось" in log.read_text(), f"мутант упал не на данных: {log}"


def test_amap_exhaustive():
    """Все 2^25 beat, 6 наборов параметров: окно канала, взаимно однозначно, 8 псевдоканалов."""
    OUT.mkdir(exist_ok=True)
    mdir = OUT / "amap"
    with open(OUT / "amap.log", "w") as log:
        subprocess.run(["verilator", "--binary", "-O3", *VFLAGS[:3], "--top-module", "tb_amap",
                        "-Mdir", str(mdir), str(SIM / "tb_amap.sv"), str(HBM)], check=True,
                       stdout=log, stderr=subprocess.STDOUT)
        res = subprocess.run([str(mdir / "Vtb_amap")], check=True, capture_output=True, text=True)
        log.write(res.stdout)
    assert "tb_amap: PASS" in res.stdout, res.stdout


# ---------------------------------------------------------------- связка otpu_mem_ch + otpu_hbm_port
SYS = [("random_both", 10000), ("stream_n_read", 10000), ("stream_n_write", 10000),
       ("stream_n_read", 4444), ("stream_n_write", 4444), ("stream_x", 10000)]


@pytest.mark.parametrize("case,clk_ps", SYS)
def test_system(runners, case, clk_ps):
    if "sys" not in runners:
        runners["sys"] = build("sys", [SHELL / "otpu_afifo.sv", SHELL / "otpu_mem_ch.sv", HBM,
                                       SIM / "tb_memch_hbm.sv"], "tb_memch_hbm", {})
    fails, log = run(runners["sys"], "tb_memch_hbm", "cocotb_memch_hbm", case,
                     f"sys_{case}_clk{clk_ps}",
                     {**CONFIGS["base"]["env"], "SYS_CLK_PS": str(clk_ps)})
    assert not fails, f"{fails}: {log}"
