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
PLAIN_SCRIPTS="config.sh common.sh host-backend.sh host-setup.sh vm-setup.sh host-secrets.sh rotate-github-pat.sh rotate-heroku-key.sh anon-access heroku-session gh-session vm-git-helper noclaude"

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

# No shebang (sourced into ~/.bash_aliases, never run directly), so
# shellcheck needs an explicit "-s bash" rather than joining PLAIN_SCRIPTS
# above, which relies on each file's own shebang for shell detection.
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

# Also bash-only (heredoc <<<, process substitution <(...)), so it gets the
# same bash -n treatment as vm-bash-aliases-block.sh above rather than
# joining PLAIN_SCRIPTS's dash -n loop; unlike that file it does have its
# own shebang, so shellcheck needs no "-s bash" to pick the right dialect.
if ! bash -n check-prose-style.sh; then
  echo "FAILED: check-prose-style.sh (bash -n)" >&2
  fail=1
fi
if ! shellcheck -x check-prose-style.sh; then
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

echo
if [ "$fail" -eq 0 ]; then
  echo "All checks passed."
else
  echo "One or more checks FAILED (see above)." >&2
  exit 1
fi
