#!/bin/sh
# test_infer_watch.sh: check infer-watch.c on Linux, where there are no
# Apple headers. It compiles it against the stand-ins in macos-stubs/
# with gcc's strict warnings and its static analyzer (-fanalyzer), then
# runs it under AddressSanitizer and UndefinedBehaviorSanitizer through
# the stand-ins' fake power events, with a few hooks. Run by ci.sh.
set -eu

TESTS="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$TESTS/../infer-watch.c"
STUBS="$TESTS/macos-stubs"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

FLAGS="-std=c11 -D_POSIX_C_SOURCE=200809L -O2 -D_FORTIFY_SOURCE=3
  -Werror -Wall -Wextra -Wpedantic -Wformat=2 -Wformat-overflow=2
  -Wformat-truncation=2 -Wconversion -Wsign-conversion -Wshadow
  -Wcast-qual -Wcast-align=strict -Wwrite-strings -Wstrict-prototypes
  -Wmissing-prototypes -Wmissing-declarations -Wold-style-definition
  -Wnull-dereference -Wdouble-promotion -Wfloat-equal -Wundef -Wvla
  -Wredundant-decls -Wimplicit-fallthrough=5 -Wstrict-overflow=2
  -Wduplicated-cond -Wduplicated-branches -Wlogical-op -Wjump-misses-init
  -Walloca -Warray-bounds=2 -Wstringop-overflow=4 -Wbad-function-cast
  -Wunused-macros -Wswitch-default -fstack-protector-strong
  -I$STUBS"

fail=0
failed() {
  echo "FAILED: $1" >&2
  fail=1
}

# shellcheck disable=SC2086
gcc $FLAGS -fanalyzer -c "$SOURCE" -o "$tmp/analyzed.o" ||
  failed "gcc -fanalyzer found problems in infer-watch.c"
# shellcheck disable=SC2086
gcc $FLAGS -DSLEEP_SECONDS=1 -DOTHER_SECONDS=1 -DSTARTUP_SECONDS=2 -g \
  -fsanitize=address,undefined -fno-sanitize-recover=all \
  "$SOURCE" "$STUBS/stubs.c" -o "$tmp/infer-watch" ||
  { echo "FAILED: couldn't build infer-watch.c with the stand-ins" >&2; exit 1; }

# A hook that records each event, then does what $tmp/MODE says.
cat > "$tmp/hook" <<EOF
#!/bin/sh
echo "\$1" >> "$tmp/events"
case "\$(cat "$tmp/mode")" in
  fail) exit 1 ;;
  hang) [ "\$1" = sleep ] && { sleep 41.5 & sleep 41.5; } ;;
esac
exit 0
EOF
chmod +x "$tmp/hook"

# run MODE: run infer-watch with the hook in MODE; save its output and
# the events it ran.
run() {
  echo "$1" > "$tmp/mode"
  : > "$tmp/events"
  status=0
  start=$(date +%s)
  "$tmp/infer-watch" "$tmp/hook" > "$tmp/out" 2> "$tmp/err" || status=$?
  echo "$status" > "$tmp/status"
  echo $(($(date +%s) - start)) > "$tmp/elapsed"
}
events() {
  tr '\n' ' ' < "$tmp/events"
}
expect_success() {
  if [ "$(cat "$tmp/status")" != 1 ]; then
    failed "$1: exit status $(cat "$tmp/status"), not 1 (the run loop returned)"
  fi
  if [ "$(events)" != "power power sleep wake " ]; then
    failed "$1: the hook ran for \"$(events)\""
  fi
  if [ "$(cat "$tmp/out")" != "allowed 5 11
allowed 5 12" ]; then
    failed "$1: didn't allow both sleeps: $(cat "$tmp/out")"
  fi
  if grep -i 'sanitizer\|runtime error' "$tmp/err" >&2; then
    failed "$1: a sanitizer reported a problem"
  fi
}

run ok
expect_success "a working hook"
if [ "$(sed 's/^[0-9-]* [0-9:]* //' "$tmp/err")" != "infer-watch: waiting 2 seconds before starting
infer-watch: watching for sleep, wake, and power changes
infer-watch: the run loop stopped" ]; then
  failed "a working hook: unexpected messages: $(cat "$tmp/err")"
fi
[ "$(cat "$tmp/elapsed")" -ge 2 ] ||
  failed "a working hook: didn't wait 2 seconds before starting"

run fail
expect_success "a failing hook"
[ "$(grep -c 'hook power failed' "$tmp/err")" -eq 2 ] ||
  failed "a failing hook: power failures weren't each reported: $(cat "$tmp/err")"

run hang
expect_success "a hanging sleep hook"
grep -q 'hook sleep took over 1 seconds; stopped it' "$tmp/err" ||
  failed "a hanging sleep hook wasn't stopped: $(cat "$tmp/err")"
if pgrep -f 'sleep 41\.5' >/dev/null; then
  pkill -f 'sleep 41\.5'
  failed "a hanging sleep hook: what it started is still running"
fi

if "$tmp/infer-watch" hook 2>/dev/null; then
  failed "accepted a relative hook path"
fi
if "$tmp/infer-watch" 2>/dev/null; then
  failed "ran without a hook"
fi
if "$tmp/infer-watch" "$tmp/missing" > "$tmp/out" 2> "$tmp/err"; then
  failed "a missing hook: exited 0"
fi
grep -q "can't run $tmp/missing power" "$tmp/err" ||
  failed "a missing hook wasn't reported: $(cat "$tmp/err")"

[ "$fail" -eq 0 ] && echo "infer-watch.c: all checks passed."
exit "$fail"
