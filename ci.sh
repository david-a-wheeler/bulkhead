#!/bin/sh
# ci.sh: runs every check this repo has (shellcheck, syntax checks, a
# couple of logic tests). Run it locally before committing; .github/
# workflows/ci.yml just calls this same script, so local and CI runs are
# always identical, never two checklists that can drift apart.
#
# Usage: ./ci.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT

fail=0
failed() {
  echo "FAILED: $1" >&2
  fail=1
}
step() {
  echo
  echo "== $1 =="
}

step "awk lint (gawk --posix --lint)"
# Each .awk program must parse, with no lint warnings, using only POSIX
# awk (macOS's awk runs them). A problem here stops ci.sh at once, since
# every later test that runs the program would fail less clearly. The
# --source rules come first, so gawk parses the program but runs none of
# it: BEGIN's exit skips input and the program's own BEGIN rules, and
# END's exit stops before the program's own END rules. (Not -o, which
# also parses without running: before 5.3, gawk crashes on --lint with
# -o for any program using "+".)
if command -v gawk > /dev/null; then
  for f in *.awk tests/*.awk; do
    [ -f "$f" ] || continue
    if ! out="$(gawk --posix --lint --source 'BEGIN { exit } END { exit }' -f "$f" < /dev/null 2>&1)" || [ -n "$out" ]; then
      printf '%s\n' "$out" >&2
      echo "FAILED: awk lint of $f (above); stopping." >&2
      exit 1
    fi
  done
else
  echo "Skipping the awk lint check: gawk isn't installed."
fi

# Plain scripts: no @@VAR@@ templating, safe to check as-is.
PLAIN_SCRIPTS="config.sh common.sh host-backend.sh host-models.sh host-install.sh host-setup.sh infer-check.sh infer-doctor.sh manage-models.sh install-models.sh vm-setup.sh install-nono-deb.sh vm-piper-install.sh vm-speech-setup.sh speechd-piper compart noclaude nopi my-gen-image host-secrets.sh infer-access.sh rotate-github-pat.sh rotate-heroku-key.sh anon-access heroku-session gh-session vm-git-helper check-prose-style.sh git-commit-msg git-hook-passthrough tests/sleep-test.sh tests/stand-in-curl.sh tests/agent-network-test.sh update-broad-profile.sh bulkhead-compartment bulkhead-workspace bulkhead-copy-claude-history tests/compartment-test.sh bulkhead-reclaim-memory"

step "shellcheck (plain scripts)"
# shellcheck disable=SC2086
shellcheck -x $PLAIN_SCRIPTS || fail=1

step "dash -n (plain scripts)"
for f in $PLAIN_SCRIPTS; do
  dash -n "$f" || failed "$f"
done

step "rendering and checking templates"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# No shebang (sourced into ~/.bash_aliases, never run directly), so it
# needs an explicit "shellcheck -s bash" rather than joining
# PLAIN_SCRIPTS above, which relies on each file's own shebang for shell
# detection. (No comment line may start with the word "shellcheck", or
# that tool parses the line as a directive.)
dash -n vm-bash-aliases-block.sh || failed "vm-bash-aliases-block.sh (dash -n)"
bash -n vm-bash-aliases-block.sh || failed "vm-bash-aliases-block.sh (bash -n)"
shellcheck -x -s bash vm-bash-aliases-block.sh || fail=1

render_template secrets-client.template.py "$tmp/secrets-client" SECRETS_SERVER_PORT
render_template secrets-server.template.py "$tmp/secrets-server.py" \
  SECRETS_SERVER_PORT KEYCHAIN_PREFIX UTMCTL
for f in "$tmp/secrets-client" "$tmp/secrets-server.py" extract-chat-template.py tests/check_llama_swap_config.py tests/make_tar_fixtures.py tests/net-probe.py; do
  python3 -m py_compile "$f" || failed "$f (py_compile)"
done

render_template infer-models.template.sh "$tmp/infer-models" INFER_PORT
render_template infer-logs.template.sh "$tmp/infer-logs" INFER_PORT
render_template infer-watch-hook.template.sh "$tmp/infer-watch-hook" \
  INFER_PORT INFER_KEY_FILE INFER_LABEL INFER_LOW_POWER_BELOW INFER_LOW_POWER_UNTIL
for f in infer-models infer-logs infer-watch-hook; do
  { dash -n "$tmp/$f" && shellcheck "$tmp/$f"; } || failed "$f"
done
INFER_LABEL=test.label MACOS_INFER_USER=_infer INFER_PROFILE=/p SWAP_BIN=/b INFER_CONFIG=/c
render_template infer.template.plist "$tmp/infer.plist" \
  INFER_LABEL MACOS_INFER_USER INFER_PROFILE SWAP_BIN INFER_CONFIG INFER_PORT
INFER_TUNNEL_LABEL=test.tunnel INFER_TUNNEL_VM=testvm
render_template infer-tunnel.template.plist "$tmp/infer-tunnel.plist" \
  INFER_TUNNEL_LABEL INFER_TUNNEL_VM INFER_PORT
render_template infer-watch.template.plist "$tmp/infer-watch.plist" INFER_WATCH_LABEL HOME
for f in infer.plist infer-tunnel.plist infer-watch.plist; do
  { python3 -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' "$tmp/$f" &&
    ! grep -q '@@' "$tmp/$f"; } || failed "$f"
done
# Only macOS can load the sandbox profile (host-setup.sh checks it
# there), so just check that host-setup.sh's variables fill it in.
INFER_GENERALIST_PORT=8999 INFER_SPECIALIST_PORT=8998 METAL_CACHE=/m MODELS_DIR=/d
render_template infer.template.sb "$tmp/infer.sb" \
  INFER_PORT INFER_GENERALIST_PORT INFER_SPECIALIST_PORT METAL_CACHE MODELS_DIR
! grep -q '@@' "$tmp/infer.sb" || failed infer.sb
render_template bulkhead-reclaim-memory.template.service "$tmp/reclaim.service" \
  VM_RECLAIM_KEEP_MB VM_RECLAIM_MAX_LOAD
render_template bulkhead-reclaim-memory.template.timer "$tmp/reclaim.timer" VM_RECLAIM_INTERVAL
for f in reclaim.service reclaim.timer; do
  ! grep -q '@@' "$tmp/$f" || failed "$f"
done

step "nono's shared profile (nono-default-profile.json)"
# Every network entry is a host, or a host with endpoint rules that each
# name a method and a path (nono default-denies anything else on it).
jq -e '.network.allow_domain | length > 0 and all(
    (type == "string") or
    (type == "object" and (.domain | type == "string") and
      (.endpoints | length > 0) and
      all(.endpoints[]; (.method | type == "string") and (.path | startswith("/")))))' \
  nono-default-profile.json > /dev/null || failed nono-default-profile.json
jq -e '.network.deny_domain | length > 0 and all(type == "string")' \
  nono-default-profile.json > /dev/null || failed "nono-default-profile.json deny_domain"
# The broad profile is many GET- and HEAD-only "*.<tld>" entries.
jq -e '.meta.name == "bulkhead-broad" and (.network.allow_domain | length > 1000 and all(
    (.domain | test("^[*][.][a-z0-9-]+$")) and
    ([.endpoints[].method] | sort == ["GET", "HEAD"])))' \
  nono-broad-profile.json > /dev/null || failed nono-broad-profile.json
jq -e '.extends == "nolabs-ai/claude" and (.network.allow_domain | length > 0)' \
  nono-claude-profile.json > /dev/null || failed nono-claude-profile.json
step "workspaces (bulkhead-workspace, bulkhead-compartment --dry-run, compart)"
# A fake HOME with projects/, sensitive/, and directories outside both,
# without needing bwrap. It's under the repo's .tmp, not $tmp: $tmp may
# be in /tmp, where workspace-forbidden refuses every workspace.
mkdir -p "$SCRIPT_DIR/.tmp"
wst="$(mktemp -d "$SCRIPT_DIR/.tmp/ci-workspaces.XXXXXX")"
trap 'rm -rf "${tmp:?}" "${wst:?}"' EXIT
fh="$wst/home"
mkdir -p "$fh/projects/p1/sub" "$fh/sensitive/s1" "$fh/other" "$fh/junk/sub" "$fh/.claude" "$fh/.ssh"
: > "$fh/.claude/CLAUDE.md"
fhp="$(cd "$fh" && pwd -P)"
wsenv() {
  env -u CLAUDE_CONFIG_DIR -u BULKHEAD_COMPARTMENT -u XDG_STATE_HOME -u NONO_LOG_FILE HOME="$fh" XDG_RUNTIME_DIR=/run/user/9 \
    BULKHEAD_COMPARTMENT_PATHS="$SCRIPT_DIR/compartment-paths" \
    BULKHEAD_WORKSPACE_FORBIDDEN="$SCRIPT_DIR/workspace-forbidden" "$@"
}
# run_ws DIR COMMAND [ARG...]: run one of this repo's scripts in DIR.
run_ws() {
  (cd "$1" && shift && wsenv "$SCRIPT_DIR/$@")
}
cinfo() { wsenv ./bulkhead-workspace "$@"; }
compart_dry() { run_ws "$1" bulkhead-compartment --dry-run cmd 'a b'; }
prep() { run_ws "$1" bulkhead-workspace prepare --yes > /dev/null; }
central="$fhp/.local/state/bulkhead/dossiers"

# Keys, roots, and where the dossier goes.
[ "$(cinfo key "$fh/projects/p1/sub")" = projects-p1 ] || failed "workspace key under ~/projects"
[ "$(cinfo key "$fh/sensitive/s1")" = sensitive-s1 ] || failed "workspace key under ~/sensitive"
[ "$(cinfo key "$fh/other")" = "dir$(printf '%s' "$fhp/other" | tr '/' '%')" ] ||
  failed "workspace key elsewhere"
[ "$(cinfo dossier "$fh/projects/p1/sub")" = "$fhp/projects/p1.dossier" ] ||
  failed "workspace dossier beside it"
[ "$(cinfo dossier "$fh/other")" = "$central/dir$(printf '%s' "$fhp/other" | tr '/' '%')" ] ||
  failed "workspace dossier elsewhere is central"
cinfo bogus "$fh/other" 2> /dev/null && failed "bulkhead-workspace accepted a bad command"

# Refusals: ~ and above it, the forbidden patterns, and an unwritable
# workspace (the last only when not root, who can write anything).
mkdir -p "$fh/projects/x.dossier" "$fh/projects/p1/y.dossier"
for d in "$fh" "$fh/.." / "$fh/projects" "$fh/sensitive" "$fh/.ssh" "$fh/.claude" \
  "$fh/projects/x.dossier" "$fh/projects/p1/y.dossier"; do
  cinfo root "$d" > /dev/null 2>&1 && failed "workspace allowed in $d"
  prep "$d" 2> /dev/null && failed "prepare allowed $d"
done
rmdir "$fh/projects/x.dossier"
cinfo root "$fh/junk" > /dev/null || failed "workspace refused in ~/junk"
mkdir -p "$fh/ro"
chmod 555 "$fh/ro"
if [ "$(id -u)" -ne 0 ]; then
  prep "$fh/ro" 2> /dev/null && failed "prepare allowed an unwritable workspace"
fi
chmod 755 "$fh/ro"

# prepare: makes the dossier, records the workspace, and says so only
# the first time.
[ "$(run_ws "$fh/projects/p1/sub" bulkhead-workspace prepare 2> /dev/null)" = "$fhp/projects/p1.dossier" ] ||
  failed "prepare printed the dossier"
rm -rf "$fh/projects/p1.dossier"
out="$(prep "$fh/projects/p1/sub" 2>&1)" || failed "prepare ran"
case "$out" in *created*) ;; *) failed "prepare said it created the dossier" ;; esac
for d in state logs policy; do
  [ -d "$fh/projects/p1.dossier/$d" ] || failed "prepare made .dossier/$d"
done
[ "$(stat -c %a "$fh/projects/p1.dossier")" = 700 ] || failed "prepare made .dossier mode 700"
[ "$(cat "$fh/projects/p1.dossier/workspace")" = "$fhp/projects/p1" ] ||
  failed "prepare recorded the workspace"
[ -z "$(prep "$fh/projects/p1" 2>&1)" ] || failed "prepare was quiet the second time"
# Outside ~/projects and ~/sensitive, prepare asks first, and with no
# terminal to ask on, it refuses. setsid gives it no terminal.
(cd "$fh/other" && wsenv setsid -w "$SCRIPT_DIR/bulkhead-workspace" prepare > /dev/null 2>&1) &&
  failed "prepare made a central dossier without asking"
[ ! -e "$central/dir$(printf '%s' "$fhp/other" | tr '/' '%')" ] ||
  failed "prepare refused but made the dossier anyway"
(cd "$fh/projects/p1" && wsenv setsid -w "$SCRIPT_DIR/bulkhead-workspace" prepare > /dev/null 2>&1) ||
  failed "prepare asked under ~/projects"

# A dossier that isn't a directory you own (here, a symlink) is refused.
mkdir -p "$fh/projects/p3" "$wst/elsewhere"
ln -s "$wst/elsewhere" "$fh/projects/p3.dossier"
prep "$fh/projects/p3" 2> /dev/null && failed "prepare used a symlinked .dossier"

# The dry run binds the private ~/.claude from the dossier's state.
out="$(compart_dry "$fh/projects/p1/sub")"
[ "$(printf '%s\n' "$out" | head -n 1)" = "key: projects-p1" ] || failed "compartment key"
printf '%s\n' "$out" | tail -n 3 | tr '\n' '|' | grep -qx -- '--|cmd|a b|' ||
  failed "compartment command passthrough"
# /tmp and TMPDIR are the directory's .tmp, whatever TMPDIR was.
(cd "$fh/projects/p1/sub" && TMPDIR="$fh" wsenv "$SCRIPT_DIR/bulkhead-compartment" --dry-run cmd) |
  tr '\n' '|' > "$tmp/dry"
grep -qF -- "|--setenv|TMPDIR|$fhp/projects/p1/sub/.tmp|" "$tmp/dry" || failed "compartment TMPDIR is .tmp"
grep -qF -- "|--bind|$fhp/projects/p1/sub/.tmp|/tmp|" "$tmp/dry" || failed "compartment /tmp is .tmp"
printf '%s\n' "$out" | grep -qx "$fhp/projects/p1.dossier/state/.*%.claude" ||
  failed "compartment private ~/.claude"
printf '%s\n' "$out" | grep -qx -- '--ro-bind' || failed "compartment read-only CLAUDE.md"
# The network namespace: pasta forwards nothing, unless asked.
printf '%s\n' "$out" | sed -n 2p | grep -qx pasta || failed "compartment runs under pasta"
for opt in --tcp-ports --udp-ports --udp-ns --tcp-ns --map-host-loopback --map-guest-addr; do
  printf '%s\n' "$out" | tr '\n' '|' | grep -qF -- "|$opt|none|" || failed "compartment pasta $opt none"
done
(cd "$fh/projects/p1/sub" && wsenv "$SCRIPT_DIR/bulkhead-compartment" --dry-run \
  --forward-port 8089 --forward-port 8090 cmd) | tr '\n' '|' |
  grep -qF -- "|--tcp-ns|8089,8090|" || failed "compartment forwards ports"
(cd "$fh/projects/p1/sub" && wsenv "$SCRIPT_DIR/bulkhead-compartment" --dry-run \
  --forward-port 80x cmd) > /dev/null 2>&1 && failed "compartment forwarded a bad port"
(cd "$fh/projects/p1/sub" && wsenv "$SCRIPT_DIR/bulkhead-compartment" --dry-run \
  --expose-port 3000 --expose-port 4000 cmd) | tr '\n' '|' |
  grep -qF -- "|--tcp-ports|127.0.0.1/3000,4000|--host-lo-to-ns-lo|" || failed "compartment exposes ports"
for bad in 80x 010 ''; do
  (cd "$fh/projects/p1/sub" && wsenv "$SCRIPT_DIR/bulkhead-compartment" --dry-run \
    --expose-port "$bad" cmd) > /dev/null 2>&1 && failed "compartment exposed the port '$bad'"
done

# compart's command line, with a stand-in anon-access that prints its
# arguments: nono's options for the workspace (the inbox read-only, the
# outbox write-only, and local ports), and bulkhead-compartment's.
d1="$fhp/projects/p1.dossier"
[ -d "$d1/inbox" ] && [ -d "$d1/outbox" ] || failed "prepare made inbox and outbox"
for f in local-ports expose-ports; do
  grep -q '^#' "$d1/policy/$f" && ! grep -q '^[^#]' "$d1/policy/$f" ||
    failed "prepare made a commented $f"
done
mkdir -p "$wst/bin"
printf '#!/bin/sh\nprintf "%%s|" "$@"\n' > "$wst/bin/anon-access"
chmod 755 "$wst/bin/anon-access"
# cargs DIR [CLAUDE-ARG...]: print compart claude's command line.
cargs() {
  d="$1"
  shift
  (cd "$d" && wsenv PATH="$wst/bin:$PATH" "$SCRIPT_DIR/compart" claude "$@" 2> /dev/null)
}
nono_head="nono|run|--profile|bulkhead-claude|--allow-cwd"
inout="--log-file|$d1/logs/nono.log|--read|$d1/inbox|--write|$d1/outbox"
[ "$(cargs "$fh/projects/p1" x)" = "$nono_head|--extends|bulkhead-broad|$inout|--|claude|x|" ] ||
  failed "compart: nono options: $(cargs "$fh/projects/p1" x)"
case "$(cargs "$fh/sensitive/s1")" in
  *bulkhead-broad*) failed "compart used bulkhead-broad under ~/sensitive" ;;
esac
cp "$d1/policy/local-ports" "$wst/local-ports"
cp "$d1/policy/expose-ports" "$wst/expose-ports"
printf '8089\n\n# a dev server\n3000' >> "$d1/policy/local-ports"
echo 4000 >> "$d1/policy/expose-ports"
[ "$(cargs "$fh/projects/p1")" = "--expose-port|4000|$nono_head|--extends|bulkhead-broad|$inout|--open-port|4000|--open-port|3000|--open-port|8089|--|claude|" ] ||
  failed "compart: ports: $(cargs "$fh/projects/p1")"
cp "$wst/expose-ports" "$d1/policy/expose-ports"
for bad in 80x 0 010 65536 3000-3002 ' 8089' '8089 # web'; do
  for f in local-ports expose-ports; do
    cp "$wst/$f" "$d1/policy/$f"
    printf '%s\n' "$bad" >> "$d1/policy/$f"
    [ -z "$(cargs "$fh/projects/p1")" ] || failed "compart accepted '$bad' in $f"
  done
done
cp "$wst/local-ports" "$d1/policy/local-ports"
cp "$wst/expose-ports" "$d1/policy/expose-ports"

# Moving a workspace with its dossier updates the record.
mv "$fh/projects/p1" "$fh/projects/p1b"
mv "$fh/projects/p1.dossier" "$fh/projects/p1b.dossier"
run_ws "$fh/projects/p1b" bulkhead-workspace orphans | grep -q . &&
  failed "orphans listed a moved-together workspace"
out="$(prep "$fh/projects/p1b" 2>&1)" || failed "prepare after a move"
case "$out" in *"it's now for"*) ;; *) failed "prepare noticed the move" ;; esac
[ "$(cat "$fh/projects/p1b.dossier/workspace")" = "$fhp/projects/p1b" ] ||
  failed "prepare updated the record after a move"
# Moving a workspace without its dossier leaves an orphan.
prep "$fh/sensitive/s1" 2> /dev/null
mv "$fh/sensitive/s1" "$fh/sensitive/s1b"
[ "$(run_ws "$fh/other" bulkhead-workspace orphans)" = "$fhp/sensitive/s1.dossier" ] ||
  failed "orphans listed a dossier left behind"

# Outside ~/projects and ~/sensitive, each directory is its own
# workspace, with a central dossier, so nesting puts no dossier in
# another workspace.
prep "$fh/junk" 2> /dev/null || failed "prepare in ~/junk"
prep "$fh/junk/sub" 2> /dev/null || failed "prepare in ~/junk/sub"
[ "$(cinfo root "$fh/junk/sub")" = "$fhp/junk/sub" ] || failed "a subdirectory elsewhere is its own workspace"
[ -d "$central/dir$(printf '%s' "$fhp/junk" | tr '/' '%')/state" ] || failed "prepare made a central dossier"
[ "$(stat -c %a "$central")" = 700 ] || failed "prepare made the central directory mode 700"
[ ! -e "$fh/junk.dossier" ] && [ ! -e "$fh/junk/sub.dossier" ] || failed "prepare put a dossier beside ~/junk"
# A central dossier whose workspace is gone is an orphan.
mv "$fh/junk/sub" "$fh/junk/sub2"
run_ws "$fh/other" bulkhead-workspace orphans | grep -qx "$central/dir$(printf '%s' "$fhp/junk/sub" | tr '/' '%')" ||
  failed "orphans listed a central dossier left behind"
mv "$fh/junk/sub2" "$fh/junk/sub"

# TRANSITIONAL (remove with the registry move): a registered
# workspace's old dossier beside it moves to the central directory,
# whichever directory you start in, and the registry goes.
mkdir -p "$fh/old/sub.dossier/state"
echo "$fhp/old/sub" > "$fh/old/sub.dossier/workspace"
mkdir -p "$fh/old/sub"
printf '%s\n' "$fhp/projects/p1b" "$fhp/old/sub" > "$fhp/.local/state/bulkhead/workspaces"
cinfo key "$fh/other" > /dev/null 2> /dev/null
[ -d "$central/dir$(printf '%s' "$fhp/old/sub" | tr '/' '%')/state" ] && [ ! -e "$fh/old/sub.dossier" ] ||
  failed "an old dossier moved to the central directory"
[ ! -e "$fhp/.local/state/bulkhead/workspaces" ] || failed "the registry went away"
[ -d "$fh/projects/p1b.dossier" ] || failed "a project's dossier stayed beside it"

# TRANSITIONAL (remove with prepare's migration code): an old
# .bulkhead we made moves into the dossier, as do old logs; one we
# didn't make (or that git tracks) stays, with a warning.
mkdir -p "$fh/projects/p4/.bulkhead/home%x%.claude" "$fhp/.local/state/bulkhead/logs/projects-p4"
echo '*' > "$fh/projects/p4/.bulkhead/.gitignore"
echo t > "$fh/projects/p4/.bulkhead/home%x%.claude/t"
echo l > "$fhp/.local/state/bulkhead/logs/projects-p4/nono.log"
prep "$fh/projects/p4" 2> /dev/null || failed "prepare migrating"
[ "$(cat "$fh/projects/p4.dossier/state/home%x%.claude/t" 2> /dev/null)" = t ] ||
  failed "prepare moved .bulkhead into the dossier"
[ ! -e "$fh/projects/p4/.bulkhead" ] || failed "prepare removed the old .bulkhead"
[ "$(cat "$fh/projects/p4.dossier/logs/nono.log" 2> /dev/null)" = l ] ||
  failed "prepare moved the old logs"
mkdir -p "$fh/projects/p5/.bulkhead"
echo '*' > "$fh/projects/p5/.bulkhead/.gitignore"
: > "$fh/projects/p5/.bulkhead/x"
git -C "$fh/projects/p5" init -q && git -C "$fh/projects/p5" add -f .bulkhead/x
out="$(prep "$fh/projects/p5" 2>&1)"
[ -z "$(ls -A "$fh/projects/p5.dossier/state")" ] || failed "prepare moved a tracked .bulkhead"
case "$out" in *WARNING*) ;; *) failed "prepare warned about a tracked .bulkhead" ;; esac

# TRANSITIONAL (remove with it): bulkhead-copy-claude-history copies
# a project's history in, without overwriting, into the private
# ~/.claude that the dry run names.
mkdir -p "$fh/projects/p6"
hist="$fh/.claude/projects/$(printf '%s' "$fhp/projects/p6" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$hist/memory"
echo old > "$hist/s1.jsonl"
echo mem > "$hist/memory/MEMORY.md"
copyhist() {
  (cd "$fh/projects/p6" && wsenv PATH="$SCRIPT_DIR:$PATH" "$SCRIPT_DIR/bulkhead-copy-claude-history")
}
copyhist > /dev/null 2>&1 || failed "bulkhead-copy-claude-history ran"
claude_src="$(compart_dry "$fh/projects/p6" | grep -x "$fhp/projects/p6.dossier/state/.*%.claude")"
[ "$(cat "$claude_src/projects/${hist##*/}/memory/MEMORY.md" 2> /dev/null)" = mem ] ||
  failed "bulkhead-copy-claude-history copied memory"
echo new > "$claude_src/projects/${hist##*/}/s1.jsonl"
copyhist > /dev/null 2>&1
[ "$(cat "$claude_src/projects/${hist##*/}/s1.jsonl")" = new ] ||
  failed "bulkhead-copy-claude-history overwrote a file"

# compart pi opens the engine's port from what infer-models --url prints.
[ "$(sh "$tmp/infer-models" --url)" = "http://127.0.0.1:$INFER_PORT/v1" ] ||
  failed "infer-models --url"

step "compart (usage and unknown harnesses)"
./compart --help | grep -q '^Usage: compart HARNESS' || failed "compart --help"
for args in "" nope -x; do
  # shellcheck disable=SC2086 # "" is meant to give no arguments.
  ./compart $args > /dev/null 2>&1 && failed "compart ran with arguments '$args'"
done

step "host models (tests/test_host_models.sh)"
# initial-models.yaml and the list's rules, llama-swap's config from it,
# and infer-models and pi-models.jq on llama-swap's real listing.
{ shellcheck -x tests/test_host_models.sh && tests/test_host_models.sh; } || fail=1

step "release archive checks (archive_names_ok, unpacked_tree_ok)"
# install_release in host-setup.sh lists each release's archive with
# "tar tzf" and checks the names, then unpacks it and checks the tree.
printf '%s\n' llama-b1/ llama-b1/libllama.dylib ./x a..b/c..d | archive_names_ok ||
  failed "archive_names_ok refused good names"
for bad in /etc/x ../x a/../../x a/.. ..; do
  printf '%s\n' good "$bad" | archive_names_ok 2>/dev/null &&
    failed "archive_names_ok accepted $bad"
done
# Tarballs: one like llama.cpp's, then one per thing unpacked_tree_ok
# must refuse (tests/make_tar_fixtures.py).
python3 -I tests/make_tar_fixtures.py "$tmp/tars"
for t in "$tmp"/tars/*.tar.gz; do
  name="$(basename "$t" .tar.gz)"
  rm -rf "${tmp:?}/unpack"
  mkdir "$tmp/unpack"
  tar xzf "$t" -C "$tmp/unpack"
  tar tzf "$t" | archive_names_ok || failed "archive_names_ok refused $name's names"
  case "$name" in
    good) unpacked_tree_ok "$tmp/unpack" ||
      failed "unpacked_tree_ok refused $name" ;;
    *) ! unpacked_tree_ok "$tmp/unpack" 2>/dev/null ||
      failed "unpacked_tree_ok accepted $name" ;;
  esac
done
# stable-diffusion.cpp's release is a zip, listed with "unzip -Z1": one
# with a ".." name, and one with a symlink out.
python3 -I - "$tmp" <<'EOF'
import os, stat, sys, zipfile
def z(name, path, data, mode):
    with zipfile.ZipFile(os.path.join(sys.argv[1], name + ".zip"), "w") as f:
        i = zipfile.ZipInfo(path)
        i.create_system = 3
        i.external_attr = mode << 16
        f.writestr(i, data)
z("up", "../x", "x", stat.S_IFREG | 0o644)
z("link", "sd-server", "/bin/sh", stat.S_IFLNK | 0o777)
EOF
unzip -Z1 "$tmp/up.zip" | archive_names_ok 2>/dev/null &&
  failed "archive_names_ok accepted a zip's ../x"
rm -rf "${tmp:?}/unpack"
unzip -q "$tmp/link.zip" -d "$tmp/unpack"
unpacked_tree_ok "$tmp/unpack" 2>/dev/null &&
  failed "unpacked_tree_ok accepted a zip's symlink to /bin/sh"

step "python unit tests (tests/)"
# tests/render_helper.py renders a template in memory and imports it as a
# real module, so these exercise the actual logic (not a reimplementation
# of it) without needing a macOS host, Keychain, or network. Add new test
# files under tests/ named test_*.py and this picks them up automatically.
python3 -m unittest discover -s "$SCRIPT_DIR/tests" -v || fail=1

step "infer-watch.c (tests/test_infer_watch.sh)"
# Builds the sleep watcher against stand-ins for Apple's headers, with
# strict gcc warnings and -fanalyzer, then runs it under the sanitizers.
{ shellcheck -x tests/test_infer_watch.sh && tests/test_infer_watch.sh; } || fail=1

step "infer-doctor.sh's awk programs (tests/test_infer_doctor.sh)"
# Its flag and request summaries, on a sample command line and real
# llama-server log lines; infer-doctor.sh itself needs macOS.
{ shellcheck -x tests/test_infer_doctor.sh && tests/test_infer_doctor.sh; } || fail=1

step "speechd-piper (tests/test_speechd_piper.sh)"
# How it maps speech-dispatcher's rate and volume to Piper's, and that it
# refuses bad voice names and numbers.
{ shellcheck -x tests/test_speechd_piper.sh && tests/test_speechd_piper.sh; } || fail=1

step "bulkhead-reclaim-memory (tests/test_reclaim_memory.sh)"
{ shellcheck -x tests/test_reclaim_memory.sh && tests/test_reclaim_memory.sh; } || fail=1

step "manage-models.sh (tests/test_manage_models.sh)"
# Starts a list, adds and removes a generalist and a
# specialist, and updates, syncs, and prunes, on a copy of the repo with
# a stand-in for Hugging Face; and checks that bad requests change
# nothing.
{ shellcheck -x tests/test_manage_models.sh && tests/test_manage_models.sh; } || fail=1

step "tests/sleep-test.sh runs"
# It only runs on the Mac, so run both phases here with stand-ins for
# the Mac's commands. This catches mistakes that static checks can't
# see, such as a variable config.sh needs that's never set.
# (The shell ignores set -e in a subshell followed by ||, so each step
# here checks for failure itself.)
(
  mkdir -p "$tmp/sleep/bin" "$tmp/sleep/home/.config/bulkhead" \
    "$tmp/sleep/home/Library/Logs" || exit 1
  for cmd in launchctl pmset curl ioreg; do
    { printf '#!/bin/sh\necho "fake %s $*"\n' "$cmd" > "$tmp/sleep/bin/$cmd" &&
      chmod +x "$tmp/sleep/bin/$cmd"; } || exit 1
  done
  # Except that the engine lists one default model.
  printf '#!/bin/sh\ncase "$*" in\n  */v1/models) echo %s ;;\n  *) echo "fake curl $*" ;;\nesac\n' \
    "'{\"data\": [{\"id\": \"m\", \"meta\": {\"llamaswap\": {\"default\": true}}}]}'" \
    > "$tmp/sleep/bin/curl" || exit 1
  echo sk-test > "$tmp/sleep/home/.config/bulkhead/infer-api-key" || exit 1
  echo "x infer-watch: watching for sleep, wake, and power changes" \
    > "$tmp/sleep/home/Library/Logs/infer-watch.log" || exit 1
  for phase in before after; do
    if ! HOME="$tmp/sleep/home" PATH="$tmp/sleep/bin:$PATH" \
        SLEEP_TEST_OUT="$tmp/sleep/out" tests/sleep-test.sh "$phase" \
        > "$tmp/sleep/stdout" 2>&1; then
      cat "$tmp/sleep/stdout" >&2
      echo "FAILED: tests/sleep-test.sh $phase" >&2
      exit 1
    fi
  done
  if grep -E 'unbound variable|parameter not set|not found|WARNING' "$tmp/sleep/out" >&2 ||
      [ "$(grep -c '^===== ' "$tmp/sleep/out")" != 2 ]; then
    echo "FAILED: tests/sleep-test.sh's output (above, if any)" >&2
    exit 1
  fi
) || fail=1

step "jq revoke-filter logic (rotate-heroku-key.sh's auto-revoke query)"
# This is the trickiest logic in the repo, and it had a real bug once
# (matching by description instead of created_at silently revoked
# nothing on any routine same-VM rotation, since the old and new
# authorizations share an identical description). This fixture
# reproduces exactly that: two entries with the same description, one
# older, plus an unrelated third entry that must never be touched.
cat > "$tmp/fake_authorizations.json" <<'EOF'
[
  {"id": "OLD-1111-1111-1111-111111111111", "description": "bulkhead: lftux", "created_at": "2026-01-15T10:00:00-00:00"},
  {"id": "NEW-2222-2222-2222-222222222222", "description": "bulkhead: lftux", "created_at": "2026-08-28T14:30:00-00:00"},
  {"id": "OTHER-333-333-333-333333333333", "description": "Heroku Dashboard", "created_at": "2026-08-28T14:31:00-00:00"}
]
EOF
result="$(jq -r '
  [.[] | select(.description | startswith("bulkhead"))] |
  sort_by(.created_at) | reverse | .[1:] | .[] | .id
' "$tmp/fake_authorizations.json")"
[ "$result" = "OLD-1111-1111-1111-111111111111" ] ||
  failed "expected only the old entry's ID, got: $result"

step "commit-msg git hook"
# Builds the hooks directory vm-setup.sh installs, in a scratch repo
# with its own global config, and checks that the hook rejects a bad
# message, accepts a good one, ignores a "git commit -v" diff, and still
# runs the repository's own hooks.
(
  set -e
  mkdir -p "$tmp/bin" "$tmp/hooks"
  ln -s "$SCRIPT_DIR/check-prose-style.sh" "$tmp/bin/check-prose-style"
  cp git-commit-msg "$tmp/hooks/commit-msg"
  cp git-hook-passthrough "$tmp/hooks/passthrough"
  ln -s passthrough "$tmp/hooks/pre-commit"
  PATH="$tmp/bin:$PATH"
  GIT_CONFIG_GLOBAL="$tmp/gitconfig"
  GIT_CONFIG_NOSYSTEM=1
  export PATH GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
  git config --global user.name Test
  git config --global user.email test@example.com
  git config --global core.hooksPath "$tmp/hooks"
  # git_config_set leaves ~/.gitconfig alone (same inode) unless a value
  # changes.
  before="$(ls -i "$GIT_CONFIG_GLOBAL")"
  git_config_set user.name Test
  [ "$(ls -i "$GIT_CONFIG_GLOBAL")" = "$before" ] ||
    { echo "FAILED: git_config_set rewrote an unchanged ~/.gitconfig" >&2; exit 1; }
  git_config_set init.defaultbranch main
  [ "$(git config --global --get init.defaultbranch)" = main ] ||
    { echo "FAILED: git_config_set didn't set a new value" >&2; exit 1; }
  git init -q "$tmp/repo"
  cd "$tmp/repo"
  echo a > f
  git add f
  if git commit -q -m 'We leverage this.' 2>/dev/null; then
    echo "FAILED: commit-msg accepted a banned phrase" >&2
    exit 1
  fi
  git commit -q -m 'Add f.'
  printf '#!/bin/sh\ntouch ran-pre-commit\n' > .git/hooks/pre-commit
  printf '#!/bin/sh\ntouch ran-commit-msg\n' > .git/hooks/commit-msg
  chmod +x .git/hooks/pre-commit .git/hooks/commit-msg
  echo 'We leverage this.' >> f
  git add f
  GIT_EDITOR='sed -i 1s/^/Change.f./' git commit -q -v
  if [ ! -e ran-pre-commit ] || [ ! -e ran-commit-msg ]; then
    echo "FAILED: the repository's own hooks didn't run" >&2
    exit 1
  fi
) || fail=1

step "pi-prose-style.js"
# Checks the pi extension against the checker, with a stand-in for pi.
(
  set -e
  mkdir -p "$tmp/bin"
  ln -sf "$SCRIPT_DIR/check-prose-style.sh" "$tmp/bin/check-prose-style"
  PATH="$tmp/bin:$PATH" node tests/test_pi_prose_style.mjs
) || fail=1

step "pi-next-steps.js"
mkdir "$tmp/next-steps"
node tests/test_pi_next_steps.mjs "$tmp/next-steps" || fail=1

step "check-prose-style.sh self-test"
# Runs sample hook inputs through check-prose-style.sh and checks that
# each is allowed or denied as expected (see test-check-prose-style.sh).
bash -n test-check-prose-style.sh || failed "test-check-prose-style.sh (bash -n)"
shellcheck -x test-check-prose-style.sh || fail=1
./test-check-prose-style.sh || fail=1

echo
if [ "$fail" -eq 0 ]; then
  echo "All checks passed."
else
  echo "One or more checks FAILED (see above)." >&2
  exit 1
fi
