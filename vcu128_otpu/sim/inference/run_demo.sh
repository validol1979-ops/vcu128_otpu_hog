#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/../../.."
mkdir -p "$here/out"
octave --quiet --no-gui --eval "addpath('vcu128_otpu/sim/matlab'); test_otpu; run_flow(false); run_profile([],true);" > "$here/out/octave.log" 2>&1
python3 "$here/prepare.py"
"$here/run_questa.sh"
