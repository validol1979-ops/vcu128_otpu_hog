#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
rtl="$here/../../src/otpu-fesens/rtl"
export PATH="$HOME/questasim/bin:$PATH"
mkdir -p "$here/out"
cd "$here/out"
vlib work > vlib.log 2>&1
vmap work work > vmap.log 2>&1
python3 "$here/questa_compat.py" "$rtl/mxu/otpu_mxu.sv" mxu_questa.sv
vlog -sv -svinputport=net -work work "$rtl/top/otpu_pkg.sv" "$rtl/vpu/otpu_fp.sv" \
  "$rtl/vpu/otpu_fpipe.sv" "$rtl/tech/generic/otpu_tech_ram.sv" \
  "$rtl/tech/generic/otpu_tech_dsp.sv" mxu_questa.sv \
  "$here/tb_mxu.sv" "$here/tb_llm_replay.sv" > compile.log 2>&1
if [[ "${1:-}" == --replay-gui ]]; then
  [[ -f llm_events.txt ]] || { echo "Run prepare.py first" >&2; exit 1; }
  exec vsim -gui -voptargs="+acc -suppress 7061" work.tb_llm_replay -do "do {$here/replay_waves.do}; run -all"
fi
if [[ "${1:-}" == --gui ]]; then
  exec vsim -gui -voptargs="+acc -suppress 7061" work.tb_mxu -do "do {$here/waves.do}; run -all"
fi
vsim -batch -voptargs="+acc -suppress 7061" -wlf mxu.wlf work.tb_mxu \
  -do 'onerror {quit -code 1}; onbreak {quit -code 1}; log -r /*; run -all; quit -code 0' | tee mxu.log
rg -q 'ALL MXU TESTS PASSED' mxu.log
if [[ -f llm_events.txt ]]; then
  vsim -batch -voptargs="+acc -suppress 7061" -wlf llm.wlf work.tb_llm_replay \
    -do 'onerror {quit -code 1}; onbreak {quit -code 1}; log -r /*; run -all; quit -code 0' | tee llm.log
  rg -q 'ALL LLM EVENTS REPLAYED' llm.log
fi
