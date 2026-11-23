# shellcheck shell=sh
# host-backend.sh: the host-side calls that are specific to *how* this
# particular host stores secrets and enumerates guests, named after *what*
# they do rather than how: store_secret(), retrieve_secret(),
# secret_exists(), delete_secret(), enumerate_guests(). Today there's
# exactly one implementation of each (macOS Keychain via "security"; UTM
# guests via "utmctl"); see architecture.md's "Currently supported" note.
# Isolating them here, rather than inlining "security"/"utmctl" calls into
# host-secrets.sh and host-setup.sh directly, is what would let a second
# backend (a different secret store, a different hypervisor) replace just
# this file later. Not building a second backend speculatively; this is
# scoped to the rename/wrap only.
#
# Host-only (macOS today), like host-setup.sh and host-secrets.sh. Source
# this after config.sh/common.sh:
#   . "$(dirname "$0")/host-backend.sh"

# Usage: store_secret <keychain-service-name> <value>
# Adds or updates <value> under <keychain-service-name>. Callers apply
# whatever naming convention (prefix, "@vm-hostname", trailing "!") first;
# this only ever sees the final, already-resolved service name.
store_secret() {
  security add-generic-password -U -a "$USER" -s "$1" -w "$2"
}

# Usage: retrieve_secret <keychain-service-name>
# Prints the stored secret to stdout, or fails if it's not stored.
retrieve_secret() {
  security find-generic-password -s "$1" -w
}

# Usage: secret_exists <keychain-service-name>
secret_exists() {
  security find-generic-password -s "$1" >/dev/null 2>&1
}

# Usage: delete_secret <keychain-service-name>
delete_secret() {
  security delete-generic-password -s "$1" >/dev/null 2>&1
}

# Usage: enumerate_guests
# Prints one "<name> <ip>" line per currently-running guest VM, via UTM's
# utmctl (already installed with the app; $UTMCTL from config.sh). Only
# lists VMs utmctl reports as "started" with a resolvable IP: a stopped
# VM has no guest agent to answer "ip-address" anyway. Callers loop over
# this rather than querying utmctl directly, so a second hypervisor
# backend only has to reimplement this one function.
enumerate_guests() {
  [ -x "$UTMCTL" ] || return 1
  utm_list_output="$("$UTMCTL" list 2>&1)" || return 1
  printf '%s\n' "$utm_list_output" \
    | awk 'NR > 1 && $2 == "started" { print $NF }' \
    | while IFS= read -r vm_name; do
        vm_ip="$("$UTMCTL" ip-address "$vm_name" 2>/dev/null | head -1)"
        [ -n "$vm_ip" ] && echo "$vm_name $vm_ip"
      done
}
