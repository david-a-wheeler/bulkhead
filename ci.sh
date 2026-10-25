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
PLAIN_SCRIPTS="config.sh common.sh host-backend.sh host-models.sh host-install.sh host-setup.sh infer-check.sh manage-models.sh install-models.sh vm-setup.sh nopi my-gen-image host-secrets.sh infer-access.sh rotate-github-pat.sh rotate-heroku-key.sh anon-access heroku-session gh-session vm-git-helper noclaude check-prose-style.sh git-commit-msg git-hook-passthrough tests/sleep-test.sh tests/stand-in-curl.sh"

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
for f in "$tmp/secrets-client" "$tmp/secrets-server.py" extract-chat-template.py tests/check_llama_swap_config.py tests/make_tar_fixtures.py; do
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
    printf '#!/bin/sh\necho "fake %s $*"\n' "$cmd" > "$tmp/sleep/bin/$cmd" &&
      chmod +x "$tmp/sleep/bin/$cmd" || exit 1
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
