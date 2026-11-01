#!/bin/sh
# infer-doctor.sh: look for obvious problems with the local AI engine,
# e.g., when a client seems stuck. Run it on the Mac, as you, any time.
# It only reads state and logs: it sends the engine no requests (unlike
# infer-check.sh, which loads every model), restarts nothing, and needs
# no sudo, so it can't disturb a running job. It takes about 20 seconds,
# since it watches a few things for a while.
#
# Each line starts with OK, WARN, or INFO; each WARN says what to try.
# It exits with 1 if anything got a WARN.
#
# Usage: ./infer-doctor.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"
macos_only "infer-doctor.sh"

url="http://127.0.0.1:$INFER_PORT"
warnings=0
ok() { echo "OK    $*"; }
info() { echo "INFO  $*"; }
# warn PROBLEM HINT: report PROBLEM, and HINT, what to try.
warn() {
  echo "WARN  $1"
  echo "      $2"
  warnings=$((warnings + 1))
}
# The key reaches curl on its stdin, not its command line, which any
# process here can read.
auth() { printf 'Authorization: Bearer %s\n' "$(cat "$INFER_KEY_FILE")"; }
# upstream_tail: the newest lines of the backends' output (llama-swap's
# /logs/stream/upstream sends its history, then waits for more, so cut
# it off).
upstream_tail() {
  auth | curl -s -m 3 -H @- "$url/logs/stream/upstream" 2>/dev/null | tail -n 200
}
# progress_line LINES: the newest line that says a request is under way
# or done, from llama-server's own output.
progress_line() {
  printf '%s\n' "$1" |
    grep -E 'processing task|prompt processing|n_gen =|stop processing|release:|total time' | tail -n 1
}

echo "== Power"
batt="$(pmset -g batt)"
percent="$(printf '%s\n' "$batt" | sed -n 's/.*[[:space:]]\([0-9][0-9]*\)%;.*/\1/p' | head -n 1)"
case "$batt" in
  *"AC Power"*) ok "on AC power${percent:+, battery $percent%}" ;;
  *) warn "on battery${percent:+, at $percent%}" \
    "Plug in (and check the plug really charges). Below $INFER_LOW_POWER_BELOW%, the sleep watcher switches to Low Power Mode, which slows the engine a lot." ;;
esac
mode="$(pmset -g | awk '$1 == "powermode" { print $2; exit }')"
case "$mode" in
  1) warn "Low Power Mode is on" \
    "It throttles the GPU. Plug in; the sleep watcher restores the modes once the battery is back to $INFER_LOW_POWER_UNTIL%." ;;
  "") info "no power mode setting found" ;;
  *) ok "power mode $mode (not Low Power Mode)" ;;
esac
therm="$(pmset -g therm 2>&1)"
if printf '%s\n' "$therm" | grep -i 'warning level' | grep -qiv 'no .*warning level'; then
  warn "macOS reports a thermal or performance warning" "See pmset -g therm; let it cool, and check the fans aren't blocked."
else
  ok "no thermal warnings"
fi

echo "== Memory"
free="$(memory_pressure 2>/dev/null | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p')"
if [ -n "$free" ] && [ "$free" -lt 15 ]; then
  warn "only $free% of memory is free" "Close big apps or VMs (see the biggest users below)."
else
  ok "${free:-?}% of memory is free"
fi
swap_used="$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p' | cut -d. -f1)"
if [ "${swap_used:-0}" -gt 1024 ]; then
  warn "${swap_used} MB of swap is in use" \
    "Something didn't fit in RAM. Keep the engine plus VMs and apps under the Mac's memory; see the biggest users below."
else
  ok "${swap_used:-0} MB of swap in use"
fi
# vm_stat's first line of numbers is the totals since boot; the next is
# the change over the interval.
swapping="$(vm_stat 3 | awk '
  /swapins/ { for (i = 1; i <= NF; i++) { if ($i == "swapins") si = i; if ($i == "swapouts") so = i }; next }
  si && ++row == 2 { print $si + $so; exit }')"
if [ "${swapping:-0}" -gt 0 ]; then
  warn "$swapping pages swapped in or out in 3 seconds" "Memory is overcommitted right now; close something."
else
  ok "nothing swapping right now"
fi
pid="$(pgrep -x llama-server | head -n 1)"
rss="$([ -z "$pid" ] || ps -o rss= -p "$pid" | tr -d ' ')"
[ -z "$rss" ] || info "llama-server uses $((rss / 1048576)) GB of RAM"
info "the biggest memory users:"
top -l 1 -o mem -n 6 -stats pid,command,mem,cmprs | sed -n '/^PID/,$p' | sed 's/^/        /'

echo "== The engine"
if launchctl print "system/$INFER_LABEL" 2>/dev/null | grep -q 'state = running'; then
  ok "the engine's launchd job ($INFER_LABEL) is running"
else
  warn "the engine's launchd job ($INFER_LABEL) isn't running" "Run ./host-setup.sh, which starts it."
fi
if curl -sf -m 5 -o /dev/null "$url/health"; then
  ok "llama-swap answers on port $INFER_PORT"
else
  warn "llama-swap doesn't answer on port $INFER_PORT" "Run ./host-setup.sh; if it still fails, it prints how to run llama-swap by hand."
fi
loaded="$(auth | curl -s -m 5 -H @- "$url/running" | jq -r '[.running[]?.model] | join(", ")' 2>/dev/null)"
info "loaded now: ${loaded:-nothing}"
# A progress line comes every few seconds while llama-server works, so
# the same "under way" line twice, 15 seconds apart, means it's stuck or
# very slow.
first="$(progress_line "$(upstream_tail)")"
case "$first" in
  *"processing task"* | *"prompt processing"* | *"n_gen ="*)
    sleep 15
    second="$(progress_line "$(upstream_tail)")"
    if [ "$first" = "$second" ]; then
      warn "a request is under way, but llama-server made no progress in 15 seconds" \
        "Check the power and memory lines above. The client waits forever; press Escape in it to give up."
    else
      ok "a request is under way and making progress"
    fi
    info "newest: $(printf '%s' "$second" | sed 's/.*task/task/')"
    ;;
  "") info "no requests since the model loaded" ;;
  *) ok "idle: the last request finished" ;;
esac
cpu="$([ -z "$pid" ] || ps -o %cpu= -p "$pid" | tr -d ' ')"
[ -z "$pid" ] || info "llama-server CPU: $cpu% (it's mostly the GPU's work, so low CPU doesn't mean idle)"

echo "== Tunnels and sleep"
"$SCRIPT_DIR/infer-access.sh" status 2>&1 | sed 's/^/      /'
if launchctl print "gui/$(id -u)/$INFER_WATCH_LABEL" 2>/dev/null | grep -q 'state = running'; then
  ok "the sleep watcher ($INFER_WATCH_LABEL) is running"
else
  warn "the sleep watcher ($INFER_WATCH_LABEL) isn't running" "Run ./host-setup.sh, which starts it."
fi
info "the sleep watcher's last events (a Sleep line means it unloaded the models):"
tail -n 4 "$HOME/Library/Logs/infer-watch.log" 2>/dev/null | sed 's/^/        /'

echo "== $warnings warning(s)"
[ "$warnings" -eq 0 ]
