# Installed into ~/.bash_aliases (see install_managed_block in common.sh),
# so everything below (BULKHEAD_AUTH_SESSION) is only available from
# bash: a shell that doesn't source ~/.bash_aliases (zsh's default config
# doesn't) won't see it, regardless of whether it happens to also be
# valid dash/POSIX sh. Supporting another shell means installing an
# equivalent for that shell's own startup file, not just installing this
# same file somewhere else. Not done, since bash is the only shell in use
# on these VMs today.
#
# compart, anon-access, heroku-session, gh-session, and secrets-client
# are plain executable files instead, installed straight to
# /usr/local/bin by vm-setup.sh: any shell can run those without this
# file at all, which is the direction new tools should go rather than
# adding a bash function here. Not a template either, unlike this file:
# no @@VAR@@ substitution left here once the Claude Code wrapper moved out.

export VISUAL="vim"
export EDITOR="vim"

# Claude Code's native installer puts the binary here.
export PATH="$PATH:$HOME/.local/bin"

# Human interactive shells get a session handle; compart claude runs through
# anon-access, which strips it (see vm-git-helper and
# secrets-server.template.py for the other half of that) plus
# SSH_AUTH_SOCK, HEROKU_API_KEY, and the GitHub Enterprise tokens - see
# anon-access's own comment for the full list and why it's a blocklist.
#
# Inside a compartment or other nono sandbox (e.g., compart sh, which
# reads your ~/.bashrc), there's no session at all: we unset it, so
# whatever runs there can't get secrets, and secrets-client says it's
# because you're inside a compartment.
if [ -n "${BULKHEAD_COMPARTMENT:-}" ] || [ -n "${NONO_CAP_FILE:-}" ]; then
    unset BULKHEAD_AUTH_SESSION
elif [ -z "$BULKHEAD_AUTH_SESSION" ]; then
    # shellcheck disable=SC2155  # head/xxd failing here just means an
    # empty or malformed session id, which the secrets server already
    # denies cleanly as "missing session" - not worth splitting the
    # declare/assign for.
    export BULKHEAD_AUTH_SESSION="session_$(head -c 16 /dev/urandom | xxd -p)"
fi
