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
# shellcheck source=SCRIPTDIR/report.sh
. "$repo/tests/report.sh"
report_begin compartment-test.sh "$repo"
# Our own files, outside every compartment (report_begin made it, in
# the dossier); run_in sets each compartment's TMPDIR to its own .tmp.
scratch="$TMPDIR"
cleanup() {
  report_on_exit
  report_clean "$a" "$b" "$a.dossier" "$b.dossier" "/tmp/$marker"
}
# A failed run keeps its files for you to examine; the names are fixed,
# so a new run starts by removing them.
for d in "$a" "$b" "$a.dossier" "$b.dossier"; do
  [ ! -e "$d" ] || { echo "Removing $d, kept from an earlier run."; rm -rf "$d"; }
done
trap cleanup EXIT
mkdir -p "$a" "$b"
# A compartment sees no other workspace, and this repo is one, so each
# gets its own copy of the helper bwrap runs inside (in .tmp, which the
# workspace's own files check ignores).
for d in "$a" "$b"; do
  mkdir -p "$d/.tmp/,lib"
  cp "$repo/new-session-keyring" "$d/.tmp/,lib/"
done

fails=0
checks=0
check() {
  checks=$((checks + 1))
  if [ "$2" = "$3" ]; then
    echo "ok:   $1"
  else
    echo "FAIL: $1 (got $2, expected $3)"
    fails=$((fails + 1))
  fi
}
# run_in DIR COMMAND [BULKHEAD-COMPARTMENT-OPTION...]: run a shell
# command in DIR's compartment, as anon-access would (prepare the
# workspace, then a TMPDIR in DIR). As compart does, the compartment is
# built for the nono profile the command runs (its "--profile NAME"),
# or pi's if it runs none. Set BULKHEAD_VIEW=full to test the old view
# (TRANSITIONAL).
run_in() {
  d="$1"
  c="$2"
  shift 2
  prof=nolabs-ai/pi
  case "$c" in *"--profile "*) prof="${c#*--profile }"; prof="${prof%% *}" ;; esac
  set -- --nono-profile "$prof" "$@"
  (cd "$d" && export BULKHEAD_COMPARTMENT_PATHS="$repo/compartment-paths" \
    BULKHEAD_WORKSPACE_FORBIDDEN="$repo/workspace-forbidden" \
    BULKHEAD_NETNS_RESOLV="$repo/netns-resolv.conf" BULKHEAD_LIB_DIR="$d/.tmp/,lib" TMPDIR="$d/.tmp" &&
    mkdir -p "$TMPDIR" && "$repo/bulkhead-workspace" prepare > /dev/null 2>&1 &&
    "$repo/bulkhead-compartment" "$@" sh -c "$c")
}

if run_in "$a" true 2> "$scratch/err"; then r=ok; else r=failed; fi
check "bwrap runs" "$r" ok
if [ "$r" = failed ]; then
  cat "$scratch/err"
  rm -f "$scratch/err"
  exit 1
fi
rm -f "$scratch/err"

# compart sh returns its command's exit status, so the whole chain
# (pasta, bwrap, and nono) must pass it on.
# Its hostname says which compartment it is: "c-" and at most 8
# characters of the workspace's name.
r=$(run_in "$a" hostname)
check "a compartment's hostname" "$r" c-compartm
r=0; run_in "$a" "exit 7" || r=$?
check "pasta and bwrap pass on the exit status" "$r" 7
# This is also the first test to start nono, so if nono can't start
# (e.g., the view lacks something it needs), say why.
r=0; run_in "$a" "nono run -s --profile bulkhead-sh --allow-cwd -- sh -c 'exit 7'" 2> "$scratch/nono-err" || r=$?
check "nono passes on the exit status" "$r" 7
[ "$r" = 7 ] || sed 's/^/      nono said: /' "$scratch/nono-err"

run_in "$a" "echo a > /tmp/$marker && echo a > ~/.claude/$marker && echo a > \$XDG_RUNTIME_DIR/cc-socks/$marker && echo a > ~/.cache/$marker"
r=$(run_in "$a" "cat /tmp/$marker ~/.claude/$marker 2>/dev/null | tr -d '\n'")
check "a compartment's /tmp and ~/.claude persist" "$r" aa
r=$(cat "$a/.tmp/$marker" 2>/dev/null)
check "a compartment's /tmp is its TMPDIR" "$r" a
for f in "/tmp/$marker" "\$HOME/.claude/$marker" "\$XDG_RUNTIME_DIR/cc-socks/$marker" "\$HOME/.cache/$marker"; do
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
if [ -d "$HOME/.pi" ]; then
  # nolabs-ai/pi grants ~/.pi read-write; only its agent directory
  # is private, and the shared setup in it is read-only.
  pirun() { run_in "$1" "nono run -s --profile nolabs-ai/pi --allow-cwd -- sh -c '$2'"; }
  r=$(pirun "$a" "touch ~/.pi/$marker 2>/dev/null && echo wrote || echo refused")
  rm -f "$HOME/.pi/$marker"
  check "shared ~/.pi is read-only, even for pi" "$r" refused
  r=$(pirun "$a" "echo a > ~/.pi/agent/$marker && echo a > ~/.pi/agent/sessions/$marker && echo wrote")
  check "pi can write its own agent directory and sessions" "$r" wrote
  for f in "\$HOME/.pi/agent/$marker" "\$HOME/.pi/agent/sessions/$marker"; do
    r=$(pirun "$b" "[ -e $f ] && echo seen || echo unseen")
    check "another compartment can't see $f" "$r" unseen
  done
  if [ -e "$HOME/.pi/agent/settings.json" ]; then
    r=$(pirun "$a" "{ echo >> ~/.pi/agent/settings.json; } 2>/dev/null && echo wrote || echo refused")
    check "shared ~/.pi/agent/settings.json is read-only" "$r" refused
  fi
fi
if [ -d "$HOME/.config/goose" ]; then
  # nolabs-ai/goose grants its settings read-write, and they can name
  # commands goose runs (extensions), so they're each compartment's own,
  # as are its sessions and logs; your shared setup there is read-only.
  gooserun() { run_in "$1" "nono run -s --profile nolabs-ai/goose --allow-cwd -- sh -c '$2'"; }
  r=$(gooserun "$a" "echo a > ~/.config/goose/$marker && echo a > ~/.local/share/goose/$marker && echo a > ~/.local/state/goose/$marker && echo wrote")
  check "goose can write its own settings, sessions, and logs" "$r" wrote
  for f in "\$HOME/.config/goose/$marker" "\$HOME/.local/share/goose/$marker" "\$HOME/.local/state/goose/$marker"; do
    r=$(gooserun "$b" "[ -e $f ] && echo seen || echo unseen")
    check "another compartment can't see $f" "$r" unseen
    r=$(sh -c "[ -e $f ] && echo seen || echo unseen")
    check "outside, $f isn't there" "$r" unseen
  done
  if [ -e "$HOME/.config/goose/AGENTS.md" ]; then
    r=$(gooserun "$a" "{ echo >> ~/.config/goose/AGENTS.md; } 2>/dev/null && echo wrote || echo refused")
    check "shared ~/.config/goose/AGENTS.md is read-only, even for goose" "$r" refused
    r=$(gooserun "$a" "[ -s ~/.config/goose/AGENTS.md ] && echo readable || echo missing")
    check "shared ~/.config/goose/AGENTS.md is readable" "$r" readable
  fi
fi
# Its own /dev: none of the VM's terminals (yours included) are there.
r=$(run_in "$a" "ls /dev/pts | grep -c '^[0-9]'" || :)
check "a compartment sees none of the VM's terminals" "$r" 0
r=$(run_in "$a" "echo x > /dev/null && echo ok")
check "a compartment's /dev/null works" "$r" ok
# Its own /run: none of the VM's service sockets, only what
# compartment-paths lists (and the stand-in sockets; see below).
for s in /run/docker.sock "\$XDG_RUNTIME_DIR/bus" \
  "\$XDG_RUNTIME_DIR/systemd/private" "\$XDG_RUNTIME_DIR/openssh_agent" "\$XDG_RUNTIME_DIR/gnupg"; do
  r=$(run_in "$a" "[ -e $s ] && echo seen || echo unseen")
  check "a compartment can't see $s" "$r" unseen
done
if [ -S "${XDG_RUNTIME_DIR:-/nonexistent}/speech-dispatcher/speechd.sock" ]; then
  r=$(run_in "$a" "[ -S \$XDG_RUNTIME_DIR/speech-dispatcher/speechd.sock ] && echo seen || echo unseen")
  check "a compartment can reach speech-dispatcher" "$r" seen
fi
# Other workspaces are hidden, but not its own dossier's inbox.
r=$(run_in "$a" "[ -e $b ] && echo seen || echo unseen")
check "a compartment can't see another workspace" "$r" unseen
# In the allowlist view, what nono doesn't grant isn't there at all
# (each of these exists on the VM), under each harness's profile (a
# profile may grant more than it seems, e.g., all of /run); what it
# grants is.
if [ "${BULKHEAD_VIEW:-allowlist}" = allowlist ]; then
  for prof in bulkhead-sh bulkhead-claude nolabs-ai/pi nolabs-ai/goose bulkhead-goose-desktop; do
    for p in /etc/shadow /var/log /run/docker.sock \
      "${XDG_RUNTIME_DIR:-/nonexistent}/bus" "$HOME/.ssh" "$HOME/.gnupg" \
      "$HOME/.bash_history" "$HOME/.local/share/keyrings"; do
      [ -e "$p" ] || continue
      r=$(run_in "$a" "[ -e $p ] && echo there || echo absent" --nono-profile "$prof")
      check "allowlist view, $prof: $p (not granted) isn't there" "$r" absent
    done
    for p in /usr/bin/python3 /etc/passwd /etc/resolv.conf "$HOME/.gitconfig" "$HOME/.agents"; do
      [ -e "$p" ] || continue
      r=$(run_in "$a" "[ -e $p ] && echo there || echo absent" --nono-profile "$prof")
      check "allowlist view, $prof: $p (granted) is there (so the check works)" "$r" there
    done
  done
fi
r=$(run_in "$a" "[ -d $a.dossier/inbox ] && [ ! -e $a.dossier/policy ] && echo ok")
check "a compartment sees only its dossier's inbox, outbox, and logs" "$r" ok
# nono, run as compart runs it, logs to the dossier (not to stderr,
# over a harness's display).
rm -f "$a.dossier/logs/nono.log"
r=$(run_in "$a" "nono run -s --profile nolabs-ai/pi --allow-cwd --log-file $a.dossier/logs/nono.log -- true" 2>&1)
case "$r" in *"failed to open log file"*) r=stderr ;; *) [ -f "$a.dossier/logs/nono.log" ] && r=dossier || r=nowhere ;; esac
check "nono's log from a compartment reaches the dossier" "$r" dossier
# nono mediates Unix sockets: a socket outside the compartment's own
# places is refused, even where nothing hides it; its own work.
sock="$HOME/,compartment-test-$$.sock"
python3 -I -c 'import socket, sys, time; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(60)' "$sock" > /dev/null 2>&1 &
listener=$!
sleep 1
# Python prints nothing (quotes don't survive the nesting); sh says.
conn="python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1])'"
r=$(run_in "$a" "nono run -s --profile bulkhead-sh --allow-cwd -- sh -c \"$conn $sock 2>/dev/null && echo connected || echo refused\"")
kill "$listener" 2> /dev/null; rm -f "$sock"
check "nono refuses a socket outside the compartment" "$r" refused
bind="python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])'"
r=$(run_in "$a" "nono run -s --profile bulkhead-sh --allow-cwd -- sh -c \"$bind $a/,s && echo bound\""; rm -f "$a/,s")
check "nono lets an agent make a socket in its workspace" "$r" bound
# A key one compartment holds, another can't see (by /proc/keys or a
# keyring search). The VM can, which shows the key was really there.
cp "$repo/tests/compartment-sweep.py" "$a/,compartment-sweep.py"
cp "$repo/tests/compartment-sweep.py" "$b/,compartment-sweep.py"
key="bulkhead-test-key-$$"
run_in "$a" "python3 ,compartment-sweep.py key-hold $key 4" > "$scratch/key-held" 2>&1 &
holder=$!
i=0
until grep -qx held "$scratch/key-held" 2> /dev/null || [ "$i" -ge 30 ]; do
  sleep 0.1
  i=$((i + 1))
done
r=$(grep -q "$key" /proc/keys && echo found || echo "not found")
check "a compartment's key is really there (seen from the VM)" "$r" found
r=$(run_in "$b" "python3 ,compartment-sweep.py key-find $key")
check "another compartment can't see a compartment's key" "$r" "not found"
wait "$holder" || :
rm -f "$a/,compartment-sweep.py" "$b/,compartment-sweep.py"
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
# COMMAND mustn't contain single quotes. Our workspaces' names start with
# a comma, so this catches a grant that nono splits at commas (as it
# does --allow's; see compart).
run_agent() {
  if [ -n "${3:-}" ]; then
    run_in "$1" "nono run -s --profile nolabs-ai/pi --allow-cwd --read $1.dossier/inbox --read $1.dossier/outbox --write $1.dossier/outbox --open-port $3 -- sh -c '$2'" --expose-port "$3"
  else
    run_in "$1" "nono run -s --profile nolabs-ai/pi --allow-cwd --read $1.dossier/inbox --read $1.dossier/outbox --write $1.dossier/outbox -- sh -c '$2'"
  fi
}
echo hi > "$a.dossier/inbox/given"
r=$(run_agent "$a" "cat $a.dossier/inbox/given 2>/dev/null || echo refused")
check "an agent can read its inbox" "$r" hi
r=$(run_agent "$a" "{ echo x > $a.dossier/inbox/new; } 2>/dev/null && echo wrote || echo refused")
check "an agent can't write its inbox" "$r" refused
r=$(run_agent "$a" "echo x > $a.dossier/outbox/proposal 2>/dev/null && echo wrote || echo refused")
check "an agent can write its outbox" "$r" wrote
r=$(run_agent "$a" "cat $a.dossier/outbox/proposal 2>/dev/null || echo refused")
check "an agent can read back its outbox" "$r" x
r=$(run_agent "$a" "cd $a.dossier/outbox && echo y > ,new && mv ,new proposal && mkdir ,d && rmdir ,d && rm proposal && echo revised || echo refused")
check "an agent can rename, replace, and remove in its outbox" "$r" revised
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
  --expose-port 18990 --expose-port 18992 --expose-port 18993 > "$scratch/serve" &
wait_ready "$scratch/serve"
r=$(cat "$scratch/serve")
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
run_agent "$a" "python3 ,net-probe.py serve $stop 127.0.0.1:18990" 18990 > "$scratch/serve" &
wait_ready "$scratch/serve"
r=$(cat "$scratch/serve")
check "an agent can serve an exposed port" "$r" ready
r=$(http_get http://127.0.0.1:18990/)
check "you can reach an agent's exposed port" "${r##* }" 200
touch "$a/$stop"
wait
rm -f "$a/$stop" "$scratch/serve"
r=$(curl -s -o /dev/null --max-time 2 http://127.0.0.1:18990/ && echo reached || echo unreachable)
check "an exposed port closes when its compartment ends" "$r" unreachable
# A bad port must stop the launch, not be silently dropped.
if run_in "$b" true --expose-port 010 2> /dev/null; then r=ran; else r=refused; fi
check "a compartment won't start with a bad exposed port" "$r" refused
r=$(run_in "$a" "nono run -s --profile nolabs-ai/pi --allow-cwd --allow-domain example.com -- curl -s -o /dev/null -w %{http_code} --max-time 20 https://example.com/")
check "an agent reaches an allowed site through nono's proxy" "$r" 200
# The host's secrets server: you can reach it (it refuses a request
# with no session, and logs that), but no agent can, neither directly
# nor through nono's proxy (in broad mode, the widest). secrets-client
# refuses inside a compartment anyway, but an agent could skip it.
# config.sh reads config.local.sh from $SCRIPT_DIR.
# shellcheck source=SCRIPTDIR/../config.sh
port=$(SCRIPT_DIR="$repo" && . "$repo/config.sh" && echo "$SECRETS_SERVER_PORT")
gw=$(ip route | awk '/default/ {print $3; exit}')
secret_probe="curl -s --max-time 5 -X POST -d {} http://$gw:$port/secret"
if [ -n "$gw" ] && $secret_probe | grep -q BULKHEAD_AUTH_SESSION; then
  r=$(run_agent "$a" "python3 ,net-probe.py connect $port $gw")
  check "an agent can't connect to the secrets server" "$r" refused
  r=$(run_in "$a" "nono run -s --profile nolabs-ai/pi --extends bulkhead-broad --allow-cwd -- sh -c '$secret_probe | grep -q BULKHEAD_AUTH_SESSION && echo reached || echo refused'")
  check "an agent can't reach the secrets server through nono's proxy" "$r" refused
else
  echo "skip: the secrets server (${gw:-no gateway}, port $port) isn't answering, so I can't check that agents can't reach it."
fi
name="bulkhead-test-$$"
run_agent "$a" "python3 ,net-probe.py abstract-listen $name" > "$scratch/abs" &
sleep 2
r=$(run_agent "$b" "python3 ,net-probe.py abstract-connect $name")
check "another workspace's agent can't reach its abstract sockets" "$r" refused
wait
# nono's socket mediation denies abstract sockets outright (each
# compartment's network namespace already kept them apart).
r=$(cat "$scratch/abs")
check "an agent can't bind an abstract socket" "$r" refused
rm -f "$scratch/abs"

# Socket mediation, as each harness's merged profile really has it.
# Python's multiprocessing makes its sockets in TMPDIR, which nono
# allows, so it still works.
r=$(run_agent "$a" "python3 -I -c \"import multiprocessing as m; print(m.Pool(2).map(abs, [-1, -2]))\" 2>&1 | tail -n 1")
check "Python multiprocessing works under nono" "$r" "[1, 2]"
spd="${XDG_RUNTIME_DIR:-/nonexistent}/speech-dispatcher/speechd.sock"
if [ -S "$spd" ]; then
  r=$(run_in "$a" "nono run -s --profile nolabs-ai/pi --allow-cwd -- sh -c \"$conn $spd 2>/dev/null && echo connected || echo refused\"")
  check "pi's profile lets an agent reach speech-dispatcher" "$r" connected
fi
r=$(run_in "$a" "nono run -s --profile bulkhead-claude --allow-cwd -- sh -c \"$bind \$XDG_RUNTIME_DIR/cc-socks/,t.sock && echo bound\"")
check "Claude's profile lets it make its socket in cc-socks" "$r" bound
# glibc's connect to nscd's socket reaches our stand-in and is refused
# by the kernel (not blocked by nono, which would warn when it ends).
nscd="python3 -I -c 'import errno, socket, sys
try:
    socket.socket(socket.AF_UNIX).connect(sys.argv[1])
except OSError as e:
    print(errno.errorcode[e.errno])' /var/run/nscd/socket"
r=$(run_in "$a" "nono run -s --profile bulkhead-sh --allow-cwd -- sh -c \"$nscd\"")
check "nscd's socket is refused, not blocked" "$r" ECONNREFUSED
# And so is SSSD's (in the allowlist view; see bulkhead-compartment).
if [ "${BULKHEAD_VIEW:-allowlist}" = allowlist ]; then
  sss="${nscd%/var/run/nscd/socket}/var/lib/sss/pipes/nss"
  r=$(run_in "$a" "nono run -s --profile bulkhead-sh --allow-cwd -- sh -c \"$sss\"")
  check "SSSD's socket is refused, not blocked" "$r" ECONNREFUSED
fi
# And so is the system D-Bus: a stand-in, never the VM's real bus.
bus="${nscd%/var/run/nscd/socket}/run/dbus/system_bus_socket"
r=$(run_in "$a" "nono run -s --profile bulkhead-sh --allow-cwd -- sh -c \"$bus\"")
check "the system D-Bus is refused, not blocked (and not the VM's)" "$r" ECONNREFUSED
# Another compartment's processes are invisible.
# Killing run_in wouldn't stop the sleep inside the compartment, which
# would then hold our output open (e.g., a pipe to tee) until it ended,
# so it's short, and we wait for it. Its output isn't ours.
run_in "$a" "exec sleep 3.141" > /dev/null 2>&1 &
sleeper=$!
# Make sure it's running (seen from outside), so the check below means
# something.
i=0
until pgrep -f '^sleep 3\.141$' > /dev/null || [ "$i" -ge 20 ]; do
  sleep 0.1
  i=$((i + 1))
done
r=$(pgrep -f '^sleep 3\.141$' > /dev/null && echo running || echo missing)
check "a compartment's process is running, seen from outside" "$r" running
# cmdline separates arguments with NULs, which grep takes as binary. A
# process can end mid-loop, so the shell's own error is hidden too.
# shellcheck disable=SC2016 # It expands in the compartment, not here.
seen='for f in /proc/[0-9]*/cmdline; do [ "$( { tr "\\0" " " < $f; } 2> /dev/null)" = "sleep 3.141 " ] && echo $f; done | wc -l'
r=$(run_in "$b" "$seen")
check "a compartment can't see another's processes" "$r" 0
wait "$sleeper" || :
# The sweeps: everything a compartment can reach or write, checked
# against what it should, with each compartment started as compart
# starts it for that profile (--nono-profile). Each has a positive control, so a sweep that
# found nothing (e.g., a broken pattern) can't pass.
echo "Sweeping the VM's sockets and each profile's grants (this takes a moment)..."
for d in "$a" "$b"; do
  cp "$repo/tests/compartment-sweep.py" "$d/,compartment-sweep.py"
done
# Every Unix socket on the VM, as seen from outside, and every abstract
# one in the VM's network namespace.
{
  find / /run /tmp /dev/shm "${XDG_RUNTIME_DIR:-/nonexistent}" -xdev \
    \( -path /proc -o -path /sys \) -prune -o -type s -print 2> /dev/null
  awk 'NR > 1 && $8 ~ /^@/ { print $8 }' /proc/net/unix
} | sort -u > "$a/,sockets.list"
r=$([ "$(wc -l < "$a/,sockets.list")" -gt 0 ] && echo some || echo none)
check "the sweep listed the VM's sockets" "$r" some
# Shared on purpose, as compartment-paths says.
shared=$(awk -v home="$HOME" '$1 == "shared" { sub("^~", home, $2); print $2 }' "$repo/compartment-paths" | tr '\n' ' ')
for prof in bulkhead-sh bulkhead-claude nolabs-ai/pi nolabs-ai/goose bulkhead-goose-desktop; do
  r=$(run_in "$a" "nono run -s --profile $prof --allow-cwd -- python3 ,compartment-sweep.py sockets ,sockets.list $spd" --nono-profile "$prof")
  check "$prof: no socket on the VM is reachable, but those allowed" "$(printf '%s\n' "$r" | grep '^CONNECTS' || :)" ""
  if [ -S "$spd" ]; then
    check "$prof: the socket sweep reaches speech-dispatcher (so it works)" "$(printf '%s\n' "$r" | grep -c '^allowed' || :)" 1
  fi
  # What an agent writes outside its workspace stays in its compartment:
  # it plants a marker in every directory it may write, and neither the
  # VM nor another compartment may see one, but its outbox's.
  mark=",compartment-sweep-$$"
  grants="--allow-cwd --read $a.dossier/inbox --read $a.dossier/outbox --write $a.dossier/outbox"
  r=$(run_in "$a" "nono run -s --profile $prof $grants -- python3 ,compartment-sweep.py plant $mark $a $shared" --nono-profile "$prof")
    # The list stays outside every compartment, where we read it to
  # remove the markers; B gets a copy to check against.
  printf '%s\n' "$r" | sed -n 's/^planted //p' > "$scratch/planted.list"
  cp "$scratch/planted.list" "$b/,planted.list"
  r=$(grep -c . "$scratch/planted.list" || :)
  [ "$r" -gt 1 ] && r=some || r=none
  check "$prof: the sweep could write outside the workspace (so it works)" "$r" some
  r=$([ -e "$a.dossier/outbox/$mark" ] && echo shows || echo missing)
  check "$prof: what it writes in its outbox shows outside (so the check works)" "$r" shows
  leaked=""
  while IFS= read -r f; do
    [ "$f" != "$a.dossier/outbox/$mark" ] || continue
    [ ! -e "$f" ] || leaked="$leaked $f"
  done < "$scratch/planted.list"
  check "$prof: nothing else it wrote shows outside its compartment" "$leaked" ""
  b_grants="--allow-cwd --read $b.dossier/inbox --read $b.dossier/outbox --write $b.dossier/outbox"
  r=$(run_in "$b" "nono run -s --profile $prof $b_grants -- python3 ,compartment-sweep.py seen ,planted.list" --nono-profile "$prof")
  check "$prof: another compartment sees nothing it wrote" "$r" ""
  # The markers outside are only the outbox's (and any leaks).
  while IFS= read -r f; do rm -f "$f"; done < "$scratch/planted.list"
done

# Every path the installed profiles let agents write is covered.
r=$(cd "$a" && BULKHEAD_COMPARTMENT_PATHS="$repo/compartment-paths" \
  "$repo/bulkhead-grant-check" bulkhead-sh bulkhead-claude nolabs-ai/pi nolabs-ai/goose bulkhead-goose-desktop 2>&1 && echo covered || :)
check "compartment-paths covers every write the installed profiles grant" "$r" covered

report_end "$fails" "$checks"
