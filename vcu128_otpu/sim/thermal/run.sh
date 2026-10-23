#!/usr/bin/env bash
# RTL-тесты термоконтроля (src/thermal + vcu128_platform_regs): cocotb 2.0.1 + Verilator.
#   ./run.sh                         — все тесты
#   THERMAL_TESTS=test_hbm ./run.sh  — выбранные (регулярное выражение)
# Окружение: ../external/rtl/opentpu/.venv (cocotb, cocotbext-axi; из worktree —
# OTPU_VENV=<абсолютный путь>), Verilator в ~/.local/bin. Результаты — out/ (results.xml,
# sim.log); сборка Verilator (out/build) удаляется после прогона (KEEP_BUILD=1 — оставить).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
venv=${OTPU_VENV:-$root/../external/rtl/opentpu/.venv}
export PATH=$HOME/.local/bin:$venv/bin:$PATH
export PYTHONDONTWRITEBYTECODE=1 PYTHONWARNINGS=ignore::DeprecationWarning
cd "$here"
mkdir -p out
status=0
"$venv/bin/python" run.py 2>&1 | tee out/sim.log || status=1
grep -q "^thermal: [0-9]* tests, 0 failed (0 skipped)" out/sim.log || status=1
[ -n "${KEEP_BUILD:-}" ] || rm -rf out/build
exit $status
