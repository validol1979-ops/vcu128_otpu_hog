"""Сборка tb_thermal (Verilator) и прогон cocotb test_thermal. Запуск — run.sh.
Результаты: out/results.xml, журнал — out/sim.log."""
from __future__ import annotations

import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
SRC = HERE.parents[1] / "src"
SOURCES = [SRC / "thermal/vcu128_sysmon_drp.sv", SRC / "thermal/vcu128_thermal.sv",
           SRC / "thermal/vcu128_ctl_guard.sv", SRC / "vcu128_platform_regs.sv",
           HERE / "tb_thermal.sv"]


def main() -> int:
    out = HERE / "out"
    out.mkdir(parents=True, exist_ok=True)
    r = get_runner("verilator")
    r.build(sources=SOURCES, hdl_toplevel="tb_thermal", build_dir=out / "build",
            timescale=("1ns", "1ps"), always=True,
            build_args=["-Wno-fatal", "-Wno-WIDTH", "-Wno-TIMESCALEMOD",
                        "--x-assign", "unique", "--x-initial", "unique"])
    xml = r.test(hdl_toplevel="tb_thermal", test_module="test_thermal", test_dir=HERE,
                 build_dir=out / "build", results_xml=str(out / "results.xml"),
                 extra_env={"PYTHONPATH": str(HERE)},
                 test_filter=os.environ.get("THERMAL_TESTS") or None)
    cases = list(ET.parse(xml).getroot().iter("testcase"))
    failed = sum(1 for c in cases if c.find("failure") is not None or c.find("error") is not None)
    skipped = sum(1 for c in cases if c.find("skipped") is not None)
    print(f"thermal: {len(cases) - skipped} tests, {failed} failed ({skipped} skipped)")
    return 1 if failed or not cases else 0


if __name__ == "__main__":
    sys.exit(main())
