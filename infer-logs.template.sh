#!/bin/sh
# infer-logs: copy the Mac's local AI engine logs into this VM (see
# local-ai-plan.md). The Mac writes no log files (the engine has nowhere
# to write), but llama-swap keeps recent logs in memory and streams them;
# this reads one stream through the SSH tunnel and writes it to stdout,
# which the infer-logs@STREAM systemd user service sends to the journal
# on this VM's disk. STREAM is "proxy" (llama-swap's own lines: model
# loads and unloads) or "upstream" (llama-server's output: load details
# and per-request token counts and timing). In llama-swap v265, plain
# /logs/stream is only "proxy". vm-setup.sh renders and installs this.
# Read both with:
#   journalctl --user -u 'infer-logs@*'
#
# "?no-history" streams only new lines, so a reconnect (after the tunnel
# or llama-swap restarts; systemd restarts this) doesn't record lines
# twice. Lines from while it's disconnected stay only on the Mac, in
# memory, until llama-swap restarts; see them with curl .../logs.

set -eu

KEY_FILE="$HOME/.config/bulkhead/infer-api-key"
PORT=@@INFER_PORT@@

case "${1:-}" in
  proxy | upstream) ;;
  *)
    echo "Usage: infer-logs proxy|upstream" >&2
    exit 2
    ;;
esac

# The grep drops per-request detail we don't need (slot bookkeeping and
# graph reuse) and the model's unused-tensor warnings, keeping three
# lines per request: prompt eval (prefill), eval (generation), and total
# time. If llama-server's wording changes, extra lines get through;
# nothing else is lost. When curl exits, grep does too, and systemd
# restarts this.
key="$(cat "$KEY_FILE")"
curl -sS -N --fail -H "Authorization: Bearer $key" \
  "http://127.0.0.1:$PORT/logs/stream/$1?no-history" |
  grep --line-buffered -v -E \
    'graphs reused|graph reallocs|get_availabl|launch_slot_|slot +release:|unused tensor'
