#!/bin/sh
# Tests make-git-safety-env: that systemd's environment.d parser and sh
# read its output the same way, and that the settings beat what a
# repository's own config plants (core.fsmonitor, core.hooksPath, an
# ext:: remote, and a credential helper), while your own
# credential helpers still run.
#
# Usage: tests/test_git_safety_env.sh (from the repository's top)
set -eu
# shellcheck source=SCRIPTDIR/report.sh
. "$(dirname "$0")/report.sh"
report_begin test_git_safety_env.sh "$(dirname "$0")/.."

top="$(pwd -P)"
tmp="$(mktemp -d)"
trap 'report_on_exit; report_clean "${tmp:?}"' EXIT
fail=0
failed() {
  echo "FAILED: $1" >&2
  fail=$((fail + 1))
}

GIT_CONFIG_GLOBAL="$tmp/gitconfig"
GIT_CONFIG_NOSYSTEM=1
HOME="$tmp/home"
XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM HOME XDG_CONFIG_HOME
unset GIT_CONFIG_COUNT SSH_ASKPASS GIT_SSH
mkdir -p "$HOME" "$tmp/hooks" "$XDG_CONFIG_HOME/environment.d"
# Your own credential helper records each call, so we can see it ran.
cat > "$tmp/mine" <<EOF
#!/bin/sh
echo "\$1" >> "$tmp/mine.log"
EOF
cat > "$tmp/evil" <<EOF
#!/bin/sh
echo "\$*" >> "$tmp/evil.log"
EOF
chmod +x "$tmp/mine" "$tmp/evil"
git config --global user.name Test
git config --global user.email test@example.com
git config --global core.hooksPath "$tmp/hooks"
git config --global 'credential.https://github.com.helper' "$tmp/mine"

conf="$XDG_CONFIG_HOME/environment.d/50-bulkhead-git-safety.conf"
"$top/make-git-safety-env" > "$conf"

# Both parsers must agree on every variable the file sets.
# shellcheck disable=SC2016 # the inner sh expands $1
sh_vars="$(env -i sh -c 'set -a; . "$1"; set +a; env' sh "$conf" |
  grep '^GIT_' | sort)"
gen=/usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator
if [ -x "$gen" ]; then
  # The generator quotes values with spaces; sh's env doesn't.
  gen_vars="$(env -i XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$gen" 2>&1 |
    grep '^GIT_' | sed 's/^\([^=]*\)="\(.*\)"$/\1=\2/' | sort)"
  [ "$sh_vars" = "$gen_vars" ] ||
    failed "environment.d and sh read $conf differently:
sh:
$sh_vars
environment.d:
$gen_vars"
else
  echo "Skipping the environment.d comparison: no $gen."
fi

set -a
# shellcheck disable=SC1090
. "$conf"
set +a

git init -q "$tmp/repo"
cd "$tmp/repo"
echo a > f
git add f
git commit -q -m 'Add f.'

# Planted local config: none of these may run.
git config core.fsmonitor "$tmp/evil fsmonitor"
echo b > f
git status --short > /dev/null 2>&1 || true

mkdir "$tmp/evil-hooks"
printf '#!/bin/sh\necho hook >> "%s"\n' "$tmp/evil.log" > "$tmp/evil-hooks/pre-commit"
chmod +x "$tmp/evil-hooks/pre-commit"
git config core.hooksPath "$tmp/evil-hooks"
git commit -q -am 'Change f.'

git config protocol.ext.allow always
git remote add evil "ext::$tmp/evil ext"
git fetch -q evil > /dev/null 2>&1 || true

git config credential.helper "$tmp/evil"
printf 'protocol=https\nhost=github.com\nusername=u\npassword=p\n\n' |
  git credential approve

if [ -e "$tmp/evil.log" ]; then
  failed "a repository's own config ran a command:
$(cat "$tmp/evil.log")"
fi
grep -qx store "$tmp/mine.log" 2>/dev/null ||
  failed "your own credential helper didn't run"

report_end "$fail"
