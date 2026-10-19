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
trap 'rm -rf "$tmp"' EXIT

fail=0
step() {
  echo
  echo "== $1 =="
}

# Plain scripts: no @@VAR@@ templating, safe to check as-is.
PLAIN_SCRIPTS="config.sh common.sh host-backend.sh host-setup.sh vm-setup.sh host-secrets.sh infer-access.sh rotate-github-pat.sh rotate-heroku-key.sh anon-access heroku-session gh-session vm-git-helper noclaude check-prose-style.sh git-commit-msg git-hook-passthrough"

step "shellcheck (plain scripts)"
# shellcheck disable=SC2086
if ! shellcheck -x $PLAIN_SCRIPTS; then
  fail=1
fi

step "dash -n (plain scripts)"
for f in $PLAIN_SCRIPTS; do
  if ! dash -n "$f"; then
    echo "FAILED: $f" >&2
    fail=1
  fi
done

step "rendering and checking templates"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# No shebang (sourced into ~/.bash_aliases, never run directly), so it
# needs an explicit "shellcheck -s bash" rather than joining
# PLAIN_SCRIPTS above, which relies on each file's own shebang for shell
# detection. (No comment line may start with the word "shellcheck", or
# that tool parses the line as a directive.)
if ! dash -n vm-bash-aliases-block.sh; then
  echo "FAILED: vm-bash-aliases-block.sh (dash -n)" >&2
  fail=1
fi
if ! bash -n vm-bash-aliases-block.sh; then
  echo "FAILED: vm-bash-aliases-block.sh (bash -n)" >&2
  fail=1
fi
if ! shellcheck -x -s bash vm-bash-aliases-block.sh; then
  fail=1
fi

render_template secrets-client.template.py "$tmp/secrets-client" SECRETS_SERVER_PORT
render_template secrets-server.template.py "$tmp/secrets-server.py" \
  SECRETS_SERVER_PORT KEYCHAIN_PREFIX UTMCTL
for f in secrets-client secrets-server.py; do
  if ! python3 -m py_compile "$tmp/$f"; then
    echo "FAILED: $f (py_compile)" >&2
    fail=1
  fi
done

INFER_DEFAULT_MODEL="${INFER_MODELS%% *}"
render_template pi-local.template.sh "$tmp/pi-local" INFER_DEFAULT_MODEL
render_template infer-logs.template.sh "$tmp/infer-logs" INFER_PORT
for f in pi-local infer-logs; do
  if ! dash -n "$tmp/$f" || ! shellcheck "$tmp/$f"; then
    echo "FAILED: $f" >&2
    fail=1
  fi
done
INFER_LABEL=test.label MACOS_INFER_USER=_infer INFER_PROFILE=/p SWAP_BIN=/b INFER_CONFIG=/c
render_template infer.template.plist "$tmp/infer.plist" \
  INFER_LABEL MACOS_INFER_USER INFER_PROFILE SWAP_BIN INFER_CONFIG INFER_PORT
INFER_TUNNEL_LABEL=test.tunnel INFER_TUNNEL_VM=testvm
render_template infer-tunnel.template.plist "$tmp/infer-tunnel.plist" \
  INFER_TUNNEL_LABEL INFER_TUNNEL_VM INFER_PORT
for f in infer.plist infer-tunnel.plist; do
  if ! python3 -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' "$tmp/$f" ||
      grep -q '@@' "$tmp/$f"; then
    echo "FAILED: $f" >&2
    fail=1
  fi
done

step "local AI model lists (INFER_MODELS)"
# llama-swap's config and pi's models.json must list the same models.
if ! infer_llama_swap_yaml sk-test /llama-server 8999 > "$tmp/llama-swap.yaml"; then
  echo "FAILED: infer_llama_swap_yaml rejected config.sh's INFER_MODELS" >&2
  fail=1
fi
yaml_models="$(sed -n 's/^  "\([^"]*\)":$/\1/p' "$tmp/llama-swap.yaml")"
pi_models="$(infer_pi_models_json | jq -r '.providers["mac-local"].models[].id')"
config_models="$(printf '%s\n' "$INFER_MODELS" | cut -d ' ' -f 1)"
if [ "$yaml_models" != "$config_models" ] || [ "$pi_models" != "$config_models" ]; then
  echo "FAILED: model names differ: config.sh: $config_models; llama-swap: $yaml_models; pi: $pi_models" >&2
  fail=1
fi
if (INFER_MODELS='bad Bad.gguf 4096 512 A "quoted" name'
    infer_llama_swap_yaml k /s 1 >/dev/null); then
  echo "FAILED: infer_llama_swap_yaml accepted a description with quotes" >&2
  fail=1
fi

step "python unit tests (tests/)"
# tests/render_helper.py renders a template in memory and imports it as a
# real module, so these exercise the actual logic (not a reimplementation
# of it) without needing a macOS host, Keychain, or network. Add new test
# files under tests/ named test_*.py and this picks them up automatically.
if ! python3 -m unittest discover -s "$SCRIPT_DIR/tests" -v; then
  fail=1
fi

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
if [ "$result" != "OLD-1111-1111-1111-111111111111" ]; then
  echo "FAILED: expected only the old entry's ID, got:" >&2
  echo "$result" >&2
  fail=1
fi

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
if ! bash -n test-check-prose-style.sh; then
  echo "FAILED: test-check-prose-style.sh (bash -n)" >&2
  fail=1
fi
if ! shellcheck -x test-check-prose-style.sh; then
  fail=1
fi
if ! ./test-check-prose-style.sh; then
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "All checks passed."
else
  echo "One or more checks FAILED (see above)." >&2
  exit 1
fi
