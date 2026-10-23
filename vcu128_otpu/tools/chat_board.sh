#!/usr/bin/env bash
# Interactive chat with a model on the VCU128 over 40G (otpu_chat_eth.py, --backend board).
#
#   vcu128_otpu/tools/chat_board.sh [2b|4b|lfm2] [extra otpu-chat options]
#   gnome-terminal -- vcu128_otpu/tools/chat_board.sh 4b      # in a window of its own
#
# Weights fp4, LM head int8 (Qwen3.5); the board is used by one program at a time. Context window
# CAP tokens (default 32768: in HBM up to ~110k at S = 4; upstream's own default is 2048).
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/../.." && pwd)"
up=""                                          # external/rtl/opentpu-fesens: up the tree
for d in "$repo/.." "$repo/../../../.."; do      # (main checkout, or a .claude/worktrees one)
  [[ -d "$d/external/rtl/opentpu-fesens/patched" ]] && { up="$(cd -- "$d/external/rtl/opentpu-fesens" && pwd)"; break; }
done
[[ -n "$up" ]] || { echo "external/rtl/opentpu-fesens/patched not found above $repo" >&2; read -rp "Enter " _; exit 1; }
export PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$up/patched:$here" OTPU_TARGET="$repo/vcu128_otpu/target/vcu128.toml"
which="${1:-4b}"; shift || true
case "$which" in
  2b)   args=(--model qwen35-2b --wformat fp4 --head-format int8) ;;
  4b)   args=(--model qwen35-4b --wformat fp4 --head-format int8) ;;
  lfm2) args=(--model lfm2) ;;
  *)    echo "model: 2b | 4b | lfm2" >&2; exit 2 ;;
esac
"$up/.venv/bin/python" "$here/otpu_chat_eth.py" "${args[@]}" --backend board --cap "${CAP:-32768}" "$@"
status=$?
read -rp "chat exited ($status); Enter closes the window " _
exit $status
