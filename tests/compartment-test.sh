#!/bin/sh
# compartment-test.sh: check that bulkhead-compartment (bubblewrap)
# keeps compartments apart, and that nono still runs inside one. Run it
# by hand in a VM, outside any sandbox (bwrap can't run inside nono):
#   tests/compartment-test.sh
# It uses this repo's bulkhead-workspace-prepare, bulkhead-compartment,
# compartment-paths, and workspace-forbidden, makes two scratch
# projects ~/projects/,compartment-test-a and -b, and removes them, their
# dossiers, and their registry lines when it's done.
set -eu

if [ -n "${NONO_CAP_FILE:-}" ]; then
  echo "compartment-test.sh: run this outside nono." >&2
  exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd -P)
a="$HOME/projects/,compartment-test-a"
b="$HOME/projects/,compartment-test-b"
marker=",compartment-test-$$"
registry="$("$repo/bulkhead-compartment-info" registry)"
cleanup() {
  rm -rf "$a" "$b" "$a.dossier" "$b.dossier"
  rm -f "/tmp/$marker"
  if [ -f "$registry" ]; then
    grep -vFx -e "$(cd "$HOME" && pwd -P)/projects/,compartment-test-a" \
      -e "$(cd "$HOME" && pwd -P)/projects/,compartment-test-b" "$registry" > "$registry.new" || :
    mv -f "$registry.new" "$registry"
  fi
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
# run_in DIR [--forward-port PORT] COMMAND: run a shell command in
# DIR's compartment, as anon-access would (prepare the workspace, then
# a TMPDIR in DIR).
run_in() {
  d="$1"
  shift
  (cd "$d" && export BULKHEAD_COMPARTMENT_PATHS="$repo/compartment-paths" \
    BULKHEAD_WORKSPACE_FORBIDDEN="$repo/workspace-forbidden" \
    BULKHEAD_NETNS_RESOLV="$repo/netns-resolv.conf" TMPDIR="$d/.tmp" &&
    mkdir -p "$TMPDIR" && "$repo/bulkhead-workspace-prepare" 2> /dev/null &&
    if [ "$1" = --forward-port ]; then
      "$repo/bulkhead-compartment" --forward-port "$2" sh -c "$3"
    else
      "$repo/bulkhead-compartment" sh -c "$1"
    fi)
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
check "a compartment's /tmp and ~/.claude persist" "$r" aa
r=$(cat "$a/.tmp/$marker" 2>/dev/null)
check "a compartment's /tmp is its TMPDIR" "$r" a
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
if [ -d "$HOME/.agents" ]; then
  # Even with nolabs-ai/goose, whose pack grants ~/.agents read-write.
  r=$(run_in "$a" "nono run -s --profile nolabs-ai/goose --allow-cwd -- sh -c 'touch ~/.agents/$marker 2>/dev/null && echo wrote || echo refused'")
  rm -f "$HOME/.agents/$marker"
  check "shared ~/.agents is read-only, even for goose" "$r" refused
fi
r=$(run_in "$a" "echo \"\$BULKHEAD_COMPARTMENT\"")
check "BULKHEAD_COMPARTMENT is set" "$r" "projects-,compartment-test-a"
r=$(git -C "$a" init -q && git -C "$a" status --porcelain | grep -v '^?? .tmp/$' || :)
check "the workspace holds no harness state" "$r" ""
r=$([ -d "$a.dossier/state" ] && [ -d "$a.dossier/logs" ] && echo made || echo missing)
check "the workspace's dossier is beside it" "$r" made

# nono inside the compartment, with the installed profiles.
if run_in "$a" "nono run -s --profile nolabs-ai/pi --allow-cwd -- sh -c 'echo hi > ./,nono-ok'" &&
  [ -f "$a/,nono-ok" ]; then r=ok; else r=failed; fi
check "nono runs inside a compartment" "$r" ok
r=$(run_in "$a" "nono run -s --profile nolabs-ai/pi --allow-cwd -- sh -c 'ls ../,compartment-test-a.dossier/logs > /dev/null 2>&1 && echo read || echo refused'")
check "an agent can't read its workspace's dossier" "$r" refused

# An agent with the arguments anon-access adds (inbox and outbox).
# COMMAND mustn't contain single quotes.
run_agent() {
  run_in "$1" "nono run -s --profile nolabs-ai/pi --allow-cwd \$(\"$repo/bulkhead-workspace-nono-args\" 2>/dev/null) -- sh -c '$2'"
}
echo hi > "$a.dossier/inbox/given"
r=$(run_agent "$a" "cat $a.dossier/inbox/given 2>/dev/null || echo refused")
check "an agent can read its inbox" "$r" hi
r=$(run_agent "$a" "echo x > $a.dossier/inbox/new 2>/dev/null && echo wrote || echo refused")
check "an agent can't write its inbox" "$r" refused
r=$(run_agent "$a" "echo x > $a.dossier/outbox/proposal 2>/dev/null && echo wrote || echo refused")
check "an agent can write its outbox" "$r" wrote
r=$(run_agent "$a" "cat $a.dossier/outbox/proposal > /dev/null 2>&1 && echo read || echo refused")
check "an agent can't read its outbox" "$r" refused
cp "$repo/tests/net-probe.py" "$a/,net-probe.py"
cp "$repo/tests/net-probe.py" "$b/,net-probe.py"
r=$(run_agent "$a" "python3 ,net-probe.py connect22")
check "an agent can't reach the VM's loopback services" "$r" refused
r=$(run_agent "$a" "python3 ,net-probe.py loopback")
check "an agent can't use loopback ports not in local-ports" "$r" refused

# The compartment's own network namespace (pasta).
r=$(run_in "$a" "id -u")
check "a compartment keeps your uid (not pasta's root)" "$r" "$(id -u)"
if python3 "$a/,net-probe.py" see22 | grep -qx ok; then
  r=$(run_in "$a" "python3 ,net-probe.py see22")
  check "a compartment can't see the VM's sshd listening" "$r" refused
else
  echo "skip: the VM's sshd isn't listening on port 22"
fi
r=$(run_in "$a" "python3 ,net-probe.py resolve example.com")
check "a compartment can look up names" "$r" ok
python3 -m http.server -b 127.0.0.1 18989 > /dev/null 2>&1 &
server=$!
sleep 1
r=$(run_in "$a" "python3 ,net-probe.py connect 18989")
check "a compartment can't reach a VM port it isn't given" "$r" refused
r=$(run_in "$a" --forward-port 18989 "python3 ,net-probe.py connect 18989")
check "a compartment can reach a VM port it's given" "$r" ok
kill "$server"
r=$(run_in "$a" "nono run -s --profile nolabs-ai/pi --allow-cwd --allow-domain example.com -- curl -s -o /dev/null -w %{http_code} --max-time 20 https://example.com/")
check "an agent reaches an allowed site through nono's proxy" "$r" 200
name="bulkhead-test-$$"
run_agent "$a" "python3 ,net-probe.py abstract-listen $name" > ,compartment-test.abs &
sleep 2
r=$(run_agent "$b" "python3 ,net-probe.py abstract-connect $name")
check "another workspace's agent can't reach its abstract sockets" "$r" refused
wait
r=$(cat ,compartment-test.abs)
check "an agent can bind an abstract socket" "$r" ok
rm -f ,compartment-test.abs

echo "$fails failed."
[ "$fails" -eq 0 ]
