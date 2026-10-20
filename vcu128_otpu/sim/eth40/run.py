"""Сборка tb_eth40 (Verilator) и прогон тестов cocotb test_eth40 для NC = 2 и 4.
Запуск — run.sh. Результаты: out/nc<NC>/results.xml, журнал — out/nc<NC>/sim.log."""
from __future__ import annotations

import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
SRC = HERE.parents[1] / "src"
SOURCES = [SRC / "eth40/eth40_pkg.sv",
           SRC / "lib/verilog-axis/rtl/axis_fifo.v",
           SRC / "lib/verilog-axis/rtl/axis_register.v",
           *[SRC / "eth40" / f for f in ("eth40_fifo.sv", "eth40_rx_filter.sv", "eth40_arp_rx.sv",
                                         "eth40_tx_mux.sv", "eth40_disp.sv", "eth40_wr.sv",
                                         "eth40_rd.sv", "eth40_regx.sv", "eth40_ctl_tx.sv",
                                         "eth40_regs.sv", "otpu_eth_bridge.sv")],
           HERE / "tb_eth40.sv"]


def main() -> int:
    ncs = [int(x) for x in (sys.argv[1:] or ["2", "4"])]
    fails = 0
    for nc in ncs:
        out = HERE / "out" / f"nc{nc}"
        out.mkdir(parents=True, exist_ok=True)
        r = get_runner("verilator")
        r.build(sources=SOURCES, hdl_toplevel="tb_eth40", parameters={"NC": nc},
                build_dir=out / "build", timescale=("1ns", "1ps"), always=True,
                build_args=["-Wno-fatal", "-Wno-WIDTH", "-Wno-TIMESCALEMOD", "-O3",
                            "--x-assign", "unique", "--x-initial", "unique"])
        xml = r.test(hdl_toplevel="tb_eth40", test_module="test_eth40", test_dir=HERE,
                     build_dir=out / "build", results_xml=str(out / "results.xml"),
                     extra_env={"ETH40_NC": str(nc), "PYTHONPATH": str(HERE)},
                     test_filter=os.environ.get("ETH40_TESTS") or None)
        import xml.etree.ElementTree as ET
        cases = list(ET.parse(xml).getroot().iter("testcase"))
        failed = sum(1 for c in cases if c.find("failure") is not None or c.find("error") is not None)
        skipped = sum(1 for c in cases if c.find("skipped") is not None)
        print(f"NC={nc}: {len(cases) - skipped} tests, {failed} failed ({skipped} skipped)")
        fails += failed
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
