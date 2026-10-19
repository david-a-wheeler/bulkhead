#!/bin/sh
# host-secrets.sh: manage the named secrets secrets-server.py serves out of
# macOS Keychain. Run on the host only; VMs never store secrets.
# MUST be on MacOS. POSIX sh throughout.
#
# Every secret name here is a short logical name (like "GH_TOKEN")
# spelled like the environment variable it stands in if one exists.
# Every Keychain-touching command below applies config.sh's KEYCHAIN_PREFIX
# to mark it as a secret managed here (anything else is not visible).
#
# To lock a secret to one specific VM instead of leaving it available to
# any VM, just append "@<vm-hostname>" as part of the name you give below
# (e.g. "HEROKU_API_KEY@mytux"). secrets-server.py resolves which VM is
# asking and only serves an "@vm"-suffixed name to that VM specifically.
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/host-backend.sh"

# Host-only (Keychain via "security" doesn't exist on Linux).
macos_only "host-secrets.sh"

usage() {
  cat <<EOF >&2
Usage: $0 list
       $0 set <name>[@vm-hostname] # set secret <name> from stdin
       $0 get <name>[@vm-hostname] # print secret <name> to stdout
       $0 delete <name>[@vm-hostname] # delete secret <name>

Run "$0 list" to see every currently servable secret.
EOF
  exit 1
}

# Every function below takes a short logical name (the same one you'd pass
# on the command line, "@vm-hostname" suffix and all), applies
# KEYCHAIN_PREFIX itself, and calls through to host-backend.sh's
# storage-agnostic seam (store_secret/retrieve_secret/secret_exists/
# delete_secret): callers never need to think about the prefix or about
# which backend actually holds the secret.
named_secret_exists() {
  secret_exists "${KEYCHAIN_PREFIX}$1"
}

cmd_list() {
  # List secrets with prefix ${KEYCHAIN_PREFIX}
  # This is not a privileged operations, because
  # "security dump-keychain" (no "-d") lists item attributes only, never
  # secret values: the closest thing security(1) has to "list by prefix",
  # since find-generic-password only does an exact -s match. "svce" is
  # Keychain's own attribute name for the service string
  # add-generic-password -s/find-generic-password -s operate on. Capture
  # the output separately (rather than piping it directly) so a failure
  # here is visible instead of silently producing an empty list under
  # set -e (same reasoning as host-setup.sh's utm_list_output).
  dump_output="$(security dump-keychain 2>&1)" || {
    echo "  WARNING: 'security dump-keychain' failed; can't list these:" >&2
    echo "$dump_output" >&2
    dump_output=""
  }
  printf '%s\n' "$dump_output" \
    | grep -o '"svce"<blob>="[^"]*"' \
    | sed -e 's/^"svce"<blob>="//' -e 's/"$//' \
    | grep "^${KEYCHAIN_PREFIX}" \
    | sed -e "s/^${KEYCHAIN_PREFIX}//" \
    | sort -u
}

cmd_get() {
  retrieve_secret "${KEYCHAIN_PREFIX}$1"
}

cmd_set() {
  name="$1"
  existed=false
  named_secret_exists "$name" && existed=true
  min_length=9
  if [ -t 0 ]; then
    # Interactive: mask input, retry on a too-short paste. A bare Enter
    # leaves an already-existing secret unchanged (rotating several
    # secrets in one script run, skipping the ones that haven't actually
    # expired, is the motivating case); a name that doesn't exist yet has
    # nothing to "leave unchanged", so empty input there still just
    # retries like any other too-short paste. A failing "read" (Ctrl-D)
    # isn't guarded, so "set -e" exits right here, still running the
    # EXIT trap below to restore echo.
    trap 'stty echo' EXIT
    trap 'stty echo; exit 1' INT TERM HUP
    while :; do
      if [ "$existed" = true ]; then
        printf '%s' "Paste the secret for $name (Enter to leave unchanged): "
      else
        printf '%s' "Paste the secret for $name: "
      fi
      stty -echo
      read -r token
      stty echo
      echo
      if [ -z "$token" ] && [ "$existed" = true ]; then
        echo "Leaving $name unchanged."
        trap - EXIT INT TERM HUP
        return 0
      fi
      [ "${#token}" -ge "$min_length" ] && break
      echo "Too short (${#token} chars); try again (Ctrl-C to cancel)." >&2
    done
    trap - EXIT INT TERM HUP
  else
    # Piped: exactly one line, no retrying possible.
    read -r token
    if [ -z "$token" ] && [ "$existed" = true ]; then
      echo "Leaving $name unchanged."
      return 0
    fi
    [ "${#token}" -ge "$min_length" ] || die "secret too short (${#token} chars)."
  fi
  # store_secret updates an existing item in place instead of erroring on
  # a duplicate; no separate delete step needed.
  store_secret "${KEYCHAIN_PREFIX}${name}" "$token"
  echo "Stored $name in Keychain."
}

cmd_delete() {
  name="$1"
  if ! named_secret_exists "$name"; then
    echo "$name isn't in Keychain; nothing to delete."
    return 0
  fi
  delete_secret "${KEYCHAIN_PREFIX}${name}"
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
  list)
    cmd_list
    ;;
  get)
    [ $# -ge 1 ] || usage
    cmd_get "$1"
    ;;
  set)
    [ $# -ge 1 ] || usage
    cmd_set "$1"
    ;;
  delete)
    [ $# -ge 1 ] || usage
    cmd_delete "$1"
    ;;
  *)
    usage
    ;;
esac
