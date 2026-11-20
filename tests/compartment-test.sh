#!/bin/sh
# compartment-test.sh: check that bulkhead-compartment (bubblewrap)
# keeps compartments apart, and that nono still runs inside one. Run it
# by hand in a VM, outside any sandbox (bwrap can't run inside nono):
#   tests/compartment-test.sh
# It uses this repo's bulkhead-compartment and compartment-paths, makes
# two scratch projects ~/projects/,compartment-test-a and -b, and
# removes them (and so their compartments' state) when it's done.
set -eu

if [ -n "${NONO_CAP_FILE:-}" ]; then
  echo "compartment-test.sh: run this outside nono." >&2
  exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd -P)
a="$HOME/projects/,compartment-test-a"
b="$HOME/projects/,compartment-test-b"
marker=",compartment-test-$$"
cleanup() {
  rm -rf "$a" "$b"
  rm -f "/tmp/$marker"
}
trap cleanup EXIT
mkdir -p "$a" "$b"

fails=0
check() {
  if [ "$2" = "$3" ]; then
    echo "ok:   $1"
  else
    echo "FAIL: $1 (got $2, expected $3)"
    fails=$((fails + 1))
  fi
}
# run_in DIR COMMAND: run a shell command in DIR's compartment.
run_in() {
  (cd "$1" && BULKHEAD_COMPARTMENT_PATHS="$repo/compartment-paths" \
    "$repo/bulkhead-compartment" sh -c "$2")
}

if run_in "$a" true 2> ,compartment-test.err; then r=ok; else r=failed; fi
check "bwrap runs" "$r" ok
if [ "$r" = failed ]; then
  cat ,compartment-test.err
  rm -f ,compartment-test.err
  exit 1
fi
rm -f ,compartment-test.err

run_in "$a" "echo a > /tmp/$marker && echo a > ~/.claude/$marker && echo a > \$XDG_RUNTIME_DIR/cc-socks/$marker"
r=$(run_in "$a" "cat /tmp/$marker ~/.claude/$marker 2>/dev/null | tr -d '\n'")
check "a compartment's ~/.claude persists (and /tmp doesn't)" "$r" a
for f in "/tmp/$marker" "\$HOME/.claude/$marker" "\$XDG_RUNTIME_DIR/cc-socks/$marker"; do
  r=$(run_in "$b" "[ -e $f ] && echo seen || echo unseen")
  check "another compartment can't see $f" "$r" unseen
  r=$(sh -c "[ -e $f ] && echo seen || echo unseen")
  check "outside, $f isn't there" "$r" unseen
done
if [ -e "$HOME/.claude/CLAUDE.md" ]; then
  r=$(run_in "$a" "echo x >> ~/.claude/CLAUDE.md 2>/dev/null && echo wrote || echo refused")
  check "shared ~/.claude/CLAUDE.md is read-only" "$r" refused
  r=$(run_in "$a" "[ -s ~/.claude/CLAUDE.md ] && echo readable || echo missing")
  check "shared ~/.claude/CLAUDE.md is readable" "$r" readable
fi
r=$(run_in "$a" "echo \"\$BULKHEAD_COMPARTMENT\"")
check "BULKHEAD_COMPARTMENT is set" "$r" "projects-,compartment-test-a"
r=$(git -C "$a" init -q && git -C "$a" status --porcelain)
check "git status ignores .bulkhead" "$r" ""

# nono inside the compartment, with the installed profiles.
if run_in "$a" "nono run -s --profile nolabs-ai/pi --allow-cwd -- sh -c 'echo hi > ./,nono-ok'" &&
  [ -f "$a/,nono-ok" ]; then r=ok; else r=failed; fi
check "nono runs inside a compartment" "$r" ok

echo "$fails failed."
[ "$fails" -eq 0 ]
