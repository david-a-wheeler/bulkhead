#!/bin/sh
# compartment-test.sh: check that bulkhead-compartment (bubblewrap)
# keeps compartments apart, and that nono still runs inside one. Run it
# by hand in a VM, outside any sandbox (bwrap can't run inside nono):
#   tests/compartment-test.sh
# It uses this repo's bulkhead-workspace, bulkhead-compartment,
# compartment-paths, and workspace-forbidden, makes two scratch
# projects ~/projects/,compartment-test-a and -b, and removes them and
# their dossiers when it's done.
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
  rm -rf "$a" "$b" "$a.dossier" "$b.dossier"
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
# run_in DIR COMMAND [BULKHEAD-COMPARTMENT-OPTION...]: run a shell
# command in DIR's compartment, as anon-access would (prepare the
# workspace, then a TMPDIR in DIR).
run_in() {
  d="$1"
  c="$2"
  shift 2
  (cd "$d" && export BULKHEAD_COMPARTMENT_PATHS="$repo/compartment-paths" \
    BULKHEAD_WORKSPACE_FORBIDDEN="$repo/workspace-forbidden" \
    BULKHEAD_NETNS_RESOLV="$repo/netns-resolv.conf" TMPDIR="$d/.tmp" &&
    mkdir -p "$TMPDIR" && "$repo/bulkhead-workspace" prepare > /dev/null 2>&1 &&
    "$repo/bulkhead-compartment" "$@" sh -c "$c")
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
  r=$(run_in "$a" "{ echo x >> ~/.claude/CLAUDE.md; } 2>/dev/null && echo wrote || echo refused")
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

# run_agent DIR COMMAND [PORT]: run a shell command as an agent, with
# the options compart adds (inbox and outbox), plus an exposed PORT.
# COMMAND mustn't contain single quotes.
run_agent() {
  if [ -n "${3:-}" ]; then
    run_in "$1" "nono run -s --profile nolabs-ai/pi --allow-cwd --read $1.dossier/inbox --write $1.dossier/outbox --open-port $3 -- sh -c '$2'" --expose-port "$3"
  else
    run_in "$1" "nono run -s --profile nolabs-ai/pi --allow-cwd --read $1.dossier/inbox --write $1.dossier/outbox -- sh -c '$2'"
  fi
}
echo hi > "$a.dossier/inbox/given"
r=$(run_agent "$a" "cat $a.dossier/inbox/given 2>/dev/null || echo refused")
check "an agent can read its inbox" "$r" hi
r=$(run_agent "$a" "{ echo x > $a.dossier/inbox/new; } 2>/dev/null && echo wrote || echo refused")
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
r=$(run_in "$a" "echo \"\$TMPDIR\"")
check "a compartment keeps TMPDIR (pasta drops it)" "$r" "$a/.tmp"
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
r=$(run_in "$a" "python3 ,net-probe.py connect 18989" --forward-port 18989)
check "a compartment can reach a VM port it's given" "$r" ok
kill "$server"
# Exposed ports: you can reach the agent's servers from the VM, but
# only at 127.0.0.1, only on the exposed ports, and another compartment
# can't. Three exposed ports check that every one is forwarded, not
# just the first.
stop=",stop-serving"
# http_get URL: print the reply's body and HTTP status (e.g.,
# "127.0.0.1 200"), or "unreachable/N", where N is curl's exit status.
# We want an HTTP reply, not just a connection: pasta may accept one
# itself.
http_get() {
  out=$(curl -s --max-time 5 -w ' %{http_code}' "$1") || out="unreachable/$?"
  echo "$out"
}
# unreachable URL: print "unreachable" if http_get can't reach URL.
unreachable() {
  case "$(http_get "$1")" in
    unreachable/*) echo unreachable ;;
    *) echo reached ;;
  esac
}
# wait_ready FILE: wait up to 10 seconds for a net-probe.py serve
# writing to FILE to say it's ready (or that it couldn't bind).
wait_ready() {
  n=0
  while [ "$n" -lt 10 ] && ! grep -qx -e ready -e refused "$1" 2> /dev/null; do
    sleep 1
    n=$((n + 1))
  done
}
rm -f "$a/$stop"
run_in "$a" "python3 ,net-probe.py serve $stop 127.0.0.1:18990 127.0.0.1:18991 0.0.0.0:18992 127.0.0.1:18993" \
  --expose-port 18990 --expose-port 18992 --expose-port 18993 > ,compartment-test.serve &
wait_ready ,compartment-test.serve
r=$(cat ,compartment-test.serve)
check "a compartment can serve its exposed and local ports" "$r" ready
r=$(http_get http://127.0.0.1:18990/)
check "you can reach a compartment's exposed port" "${r##* }" 200
check "an exposed port's clients appear to come from loopback" "${r% *}" 127.0.0.1
r=$(http_get http://127.0.0.1:18993/)
check "you can reach every exposed port (18993)" "${r##* }" 200
r=$(http_get http://127.0.0.1:18992/)
check "you can reach an exposed port the agent binds on 0.0.0.0" "${r##* }" 200
r=$(unreachable http://127.0.0.1:18991/)
check "you can't reach a port that isn't exposed" "$r" unreachable
vm_ip=$(ip -4 -o addr show scope global 2> /dev/null | awk '{ sub("/.*", "", $4); print $4; exit }')
if [ -n "$vm_ip" ]; then
  r=$(unreachable "http://$vm_ip:18990/")
  check "an exposed port isn't on the VM's address $vm_ip" "$r" unreachable
else
  echo "skip: the VM has no global IPv4 address"
fi
r=$(run_in "$b" "python3 ,net-probe.py connect 18990")
check "another compartment can't reach an exposed port" "$r" refused
touch "$a/$stop"
wait
rm -f "$a/$stop"
# The same through nono, with the --open-port that compart adds, as a
# real agent would run.
run_agent "$a" "python3 ,net-probe.py serve $stop 127.0.0.1:18990" 18990 > ,compartment-test.serve &
wait_ready ,compartment-test.serve
r=$(cat ,compartment-test.serve)
check "an agent can serve an exposed port" "$r" ready
r=$(http_get http://127.0.0.1:18990/)
check "you can reach an agent's exposed port" "${r##* }" 200
touch "$a/$stop"
wait
rm -f "$a/$stop" ,compartment-test.serve
r=$(curl -s -o /dev/null --max-time 2 http://127.0.0.1:18990/ && echo reached || echo unreachable)
check "an exposed port closes when its compartment ends" "$r" unreachable
# A bad port must stop the launch, not be silently dropped.
if run_in "$b" true --expose-port 010 2> /dev/null; then r=ran; else r=refused; fi
check "a compartment won't start with a bad exposed port" "$r" refused
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
