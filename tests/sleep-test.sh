#!/bin/sh
# sleep-test.sh: check the sleep watcher across a lid close, on the Mac.
#
# infer-watch waits 2 minutes after it starts before it does anything,
# so run "before" only once its log says it's watching.
#
#   tests/sleep-test.sh before   # load the model, then close the lid
#                                # within 30 minutes (llama-swap's ttl)
#   (close the lid for at least a minute, then open it and log in)
#   tests/sleep-test.sh after    # see what happened
#
# Each phase appends to ,sleep-test.out in the repo's top directory
# (or to $SLEEP_TEST_OUT, which ci.sh sets); send me that file.
set -u
case "${1-}" in
  before | after) ;;
  *)
    echo "Usage: $0 before|after" >&2
    exit 2
    ;;
esac
# The repo's top directory; config.sh needs it as SCRIPT_DIR.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/config.sh"
OUT="${SLEEP_TEST_OUT:-$SCRIPT_DIR/,sleep-test.out}"
model="${INFER_MODELS%% *}"
key="$(cat "$INFER_KEY_FILE")"

show() {
  echo "\$ $*"
  "$@" 2>&1
  echo
}
{
  echo "===== $1: $(date '+%Y-%m-%d %H:%M:%S')"
  if [ "$1" = before ]; then
    show launchctl print "gui/$(id -u)/$INFER_WATCH_LABEL"
    show tail -n 5 "$HOME/Library/Logs/infer-watch.log"
    if ! grep 'infer-watch: \(waiting\|watching\) ' \
        "$HOME/Library/Logs/infer-watch.log" | tail -n 1 | grep -q watching; then
      echo "WARNING: infer-watch isn't watching yet; wait and rerun this."
    fi
    echo "Loading $model (this can take a minute)"
    curl -sS -m 300 -o /dev/null -w 'HTTP %{http_code}\n' \
      -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
      -d "{\"model\": \"$model\", \"max_tokens\": 1, \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}]}" \
      "http://127.0.0.1:$INFER_PORT/v1/chat/completions"
    show pgrep -lx llama-server
  else
    show tail -n 20 "$HOME/Library/Logs/infer-watch.log"
    show pgrep -lx llama-server
    show "$SCRIPT_DIR/infer-access.sh" status
    # pmset's log has the event type in its 4th field; other fields can
    # contain "Wake" (e.g., Chrome's "Video Wake Lock").
    echo "\$ pmset -g log | (Sleep, Wake, and DarkWake events) | tail -n 10"
    pmset -g log | awk '$4 == "Sleep" || $4 == "Wake" || $4 == "DarkWake"' | tail -n 10
    echo
  fi
  show pmset -g batt
  show ls -l /private/var/vm/sleepimage
  show pmset -g custom
} 2>&1 | tee -a "$OUT"
