#!/usr/bin/env bash
# Lens profiles of one decode token on the VCU128 configuration (upstream RTL in Verilator):
# .otpuprof + standalone HTML + Markdown/CSV account per workload, in sim/lens/out/.
#
#   vcu128_otpu/sim/lens/run.sh                 # lfm2-tiny, qwen-tiny, lfm2 (fixed memory)
#   vcu128_otpu/sim/lens/run.sh lfm2-tiny       # one workload
#   MEM=axi vcu128_otpu/sim/lens/run.sh lfm2    # the native-port memory model (HBM-like guess)
#   POS=64 vcu128_otpu/sim/lens/run.sh lfm2     # a later token (longer attention)
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ws="$(cd -- "$here/../../../.." && pwd)"                 # the shared workspace (xilinx/)
up="$ws/external/rtl/opentpu-fesens"
out="$here/out"
mkdir -p "$out/tmp"
export PATH="$HOME/.local/bin:$PATH" TMPDIR="$out/tmp" PYTHONDONTWRITEBYTECODE=1
export OTPU_TARGET="${OTPU_TARGET:-$here/../../target/vcu128.toml}"
export PYTHONPATH="$up/patched${PYTHONPATH:+:$PYTHONPATH}"
py="$up/.venv/bin/python"
mem="${MEM:-fixed}"
pos="${POS:-8}"
workloads=("$@")
[[ ${#workloads[@]} -gt 0 ]] || workloads=(lfm2-tiny qwen-tiny lfm2)
for w in "${workloads[@]}"; do
  [[ "$w" == lfm2 && ! -d "$up/patched/models/LFM2.5-230M" ]] && {
    echo "skip lfm2: no $up/patched/models/LFM2.5-230M" >&2; continue; }
  name="${w}_pos${pos}_${mem}"
  echo "== $name"
  "$py" "$here/record.py" "$w" --pos "$pos" --mem "$mem" -o "$out/$name.otpuprof" \
    --html "$out/$name.html" 2>&1 | tee "$out/$name.log"
  "$py" -m opentpu.lens summary "$out/$name.otpuprof" > "$out/$name.summary.txt"
  python3 "$here/explain.py" "$out/$name.otpuprof" -o "$out/$name.md" --csv "$out/$name.csv"
  head -3 "$out/$name.summary.txt"
done
rm -rf "$out/tmp"
echo "Open: $out/*.html (Floorplan / Timeline / Instructions)"
