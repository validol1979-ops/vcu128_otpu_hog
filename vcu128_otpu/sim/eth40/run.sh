#!/usr/bin/env bash
# RTL-тесты моста 40G (otpu_eth_bridge + eth40_regs): cocotb 2.0.1 + Verilator.
#   ./run.sh            — NC = 2 и NC = 4
#   ./run.sh 2          — только NC = 2
#   ETH40_TESTS=test_arp ./run.sh 2   — выбранные тесты (регулярное выражение)
# Окружение: ../external/rtl/opentpu/.venv (cocotb, cocotbext-axi, scapy), Verilator в
# ~/.local/bin. Результаты — out/nc<NC>/ (results.xml, sim.log, throughput.txt); сборки
# Verilator (out/nc<NC>/build) удаляются после прогона (KEEP_BUILD=1 — оставить).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
venv=${ETH40_VENV:-$root/../external/rtl/opentpu/.venv}
export PATH=$HOME/.local/bin:$venv/bin:$PATH
export PYTHONDONTWRITEBYTECODE=1 PYTHONWARNINGS=ignore::DeprecationWarning
cd "$here"
mkdir -p out
status=0
for nc in ${@:-2 4}; do
    mkdir -p out/nc$nc
    "$venv/bin/python" run.py "$nc" 2>&1 | tee out/nc$nc/sim.log || status=1
    grep -q "^NC=$nc: [0-9]* tests, 0 failed (0 skipped)" out/nc$nc/sim.log || status=1
    [ -n "${KEEP_BUILD:-}" ] || rm -rf out/nc$nc/build
done
exit $status
