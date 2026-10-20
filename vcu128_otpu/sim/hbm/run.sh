#!/usr/bin/env bash
# Тесты otpu_hbm_port: cocotb 2.0.1 + Verilator 5.050 (окружение external/rtl/opentpu/.venv).
# Аргументы передаются pytest, например: ./run.sh -k "base and random"; HBM_N=..., SEED=...
set -euo pipefail

sim_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$sim_dir/../../.." && pwd)"
venv="$repo_dir/../external/rtl/opentpu/.venv"
out_dir="$sim_dir/out"
mkdir -p -- "$out_dir"
export PATH="$HOME/.local/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$sim_dir${PYTHONPATH:+:$PYTHONPATH}"
cd -- "$sim_dir"
"$venv/bin/python" -B -m pytest "$sim_dir/test_hbm.py" \
    -v --tb=short -o "cache_dir=$out_dir/pytest-cache" \
    --junitxml="$out_dir/report.xml" "$@" 2>&1 | tee "$out_dir/run.log"
rc="${PIPESTATUS[0]}"
"$venv/bin/python" -B "$sim_dir/summary.py" | tee -a "$out_dir/run.log"
exit "$rc"
