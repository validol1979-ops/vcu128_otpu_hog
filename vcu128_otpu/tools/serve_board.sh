#!/usr/bin/env bash
# The model on the VCU128 as an OpenAI-style API server for the local network (upstream opentpu.serve.api
# over 40G: otpu_eth_run.py), e.g. for any OpenAI client or a web UI on another machine.
#
#   vcu128_otpu/tools/serve_board.sh [2b|4b|gemma|lfm2] [extra opentpu.serve.api options]
#   HOST=0.0.0.0 PORT=8000 CAP=32768 OTPU_API_KEY=<key> vcu128_otpu/tools/serve_board.sh 4b
#
# Listens on HOST (default every interface) : PORT (8000). OTPU_API_KEY is required unless HOST is
# 127.0.0.1: clients send "Authorization: Bearer <key>". The board is used by one program at a time
# (stop chat_board.sh first); several clients share the server (--slots / --max-running).
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/../.." && pwd)"
up=""                                          # external/rtl/opentpu-fesens: up the tree
for d in "$repo/.." "$repo/../../../.."; do      # (main checkout, or a .claude/worktrees one)
  [[ -d "$d/external/rtl/opentpu-fesens/patched" ]] && { up="$(cd -- "$d/external/rtl/opentpu-fesens" && pwd)"; break; }
done
[[ -n "$up" ]] || { echo "external/rtl/opentpu-fesens/patched not found above $repo" >&2; exit 1; }
export PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$up/patched:$here" OTPU_TARGET="$repo/vcu128_otpu/target/vcu128.toml"
host="${HOST:-0.0.0.0}" port="${PORT:-8000}"
if [[ "$host" != 127.0.0.1 && -z "${OTPU_API_KEY:-}" ]]; then
  echo "OTPU_API_KEY is required when listening on $host (set it, or HOST=127.0.0.1)" >&2; exit 2
fi
which="${1:-4b}"; shift || true
case "$which" in
  2b)    args=(--model qwen35-2b --wformat fp4 --head-format int8) ;;
  4b)    args=(--model qwen35-4b --wformat fp4 --head-format int8) ;;
  gemma) args=(--model gemma4-e4b --wformat fp4 --head-format fp4) ;;
  lfm2)  args=(--model lfm2) ;;
  *)     echo "model: 2b | 4b | gemma | lfm2" >&2; exit 2 ;;
esac
echo "serving $which on http://$host:$port/v1 (LAN: http://$(ip -4 -br addr show eno2 2>/dev/null | awk '{print $3}' | cut -d/ -f1):$port/v1)"
exec "$up/.venv/bin/python" "$here/otpu_eth_run.py" -m opentpu.serve.api "${args[@]}" --backend board \
  --host "$host" --port "$port" --cap "${CAP:-32768}" "$@"
