#!/usr/bin/env bash
# serve_board.sh under a watchdog: restarts the API server when it exits, or when it hangs —
# requests running or waiting, yet no token generated and no prompt token prefilled for STALL seconds
# (a generate run the server itself does not recover from: see doc/journal.md, 23.10).
# Before a kill of a hung server every thread's stack goes to its log (SIGUSR1, faulthandler);
# the restart cuts the card's run short (OTPU_STOP_RUN=1).
#
#   OTPU_API_KEY=<key> vcu128_otpu/tools/serve_watchdog.sh [2b|4b|gemma|lfm2] [serve options]
#   LOG=<file> STALL=180 POLL=15 ...                (default log: tmp/serve_board.log, appended)
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$here/../../.." && pwd)"
log="${LOG:-$root/tmp/serve_board.log}"
stall="${STALL:-180}" poll="${POLL:-15}" port="${PORT:-8000}"
key="${OTPU_API_KEY:-$(cat ~/.otpu_api_key 2>/dev/null)}"
export OTPU_API_KEY="$key"
pid=""
trap '[[ -n "$pid" ]] && kill "$pid" 2>/dev/null; exit 0' INT TERM

note() { echo "watchdog $(date '+%F %T'): $*" | tee -a "$log" >&2; }

# "<running+waiting> <generated+prefill_tokens>" from /v1/stats, or nothing
probe() {
  curl -s -m 10 -H "Authorization: Bearer $key" "http://127.0.0.1:$port/v1/stats" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["running"]+d["waiting"], d["generated"]+d["prefill_tokens"])' 2>/dev/null
}

while true; do
  note "starting serve_board.sh $*"
  OTPU_STOP_RUN=1 setsid "$here/serve_board.sh" "$@" >> "$log" 2>&1 < /dev/null &
  pid=$!
  last="" since=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$poll"
    p=$(probe) || p=""
    [[ -z "$p" ]] && continue                    # loading, or busy answering: no verdict
    read -r busy work <<< "$p"
    now=$(date +%s)
    if [[ "$busy" == 0 || "$work" != "$last" ]]; then
      last="$work" since=$now
    elif (( now - since > stall )); then
      note "hung: $busy request(s), no progress for $((now - since)) s; stack dump, restart"
      kill -USR1 "$pid" 2>/dev/null; sleep 2
      kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
      break
    fi
  done
  wait "$pid" 2>/dev/null
  note "server exited ($?)"
  sleep 5
done
