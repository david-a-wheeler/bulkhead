#!/bin/sh
# infer-access.sh: choose which VMs can reach the Mac's local AI engine
# (see local-ai-plan.md, "Reaching the engine and switching access").
# Run it on the Mac as yourself:
#
#   ./infer-access.sh secure   # only INFER_SECURE_VM
#   ./infer-access.sh shared   # every other running VM, but NOT INFER_SECURE_VM
#   ./infer-access.sh off      # no VM
#   ./infer-access.sh status   # the recorded mode and the tunnels
#
# The engine listens only on the Mac's 127.0.0.1; a VM reaches it only
# through an SSH reverse tunnel this opens, each one a per-user launchd
# agent (see infer-tunnel.template.plist). Those reconnect after a VM
# reboot or the Mac's sleep, and come back after the Mac reboots.
#
# Each mode change closes every tunnel, then resets the engine
# (launchctl kickstart -k, which host-setup.sh's sudoers rule allows
# without a password), discarding everything in it (the KV cache,
# prompt cache, slots, in-flight requests, and llama-swap's in-memory
# log), and only then opens the new mode's tunnels. So nothing from the
# secure VM is left in the engine when other VMs gain access, or the
# reverse. "shared" uses the VMs running now: rerun it after starting
# another one.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/host-backend.sh"
macos_only "infer-access.sh"

TUNNEL_PREFIX=local.infer-tunnel.
AGENTS="$HOME/Library/LaunchAgents"
STATE_FILE="$HOME/.config/bulkhead/infer-access-mode"
uid="$(id -u)"
# Any ssh forwarding the engine's port, whether one of ours or one
# started by hand (e.g., ssh -N -R 8089:127.0.0.1:8089 mytux).
TUNNEL_PATTERN="ssh .*-R *[^ ]*$INFER_PORT:127\.0\.0\.1:$INFER_PORT"

# tunnel_labels: print the label of each tunnel agent we've installed.
tunnel_labels() {
  for plist in "$AGENTS/$TUNNEL_PREFIX"*.plist; do
    if [ -f "$plist" ]; then
      basename "$plist" .plist
    fi
  done
}
no_tunnels() {
  ! pgrep -f "$TUNNEL_PATTERN" >/dev/null
}
# close_tunnels: close every tunnel to the engine, and wait until no
# ssh is forwarding its port.
close_tunnels() {
  for label in $(tunnel_labels); do
    launchctl bootout "gui/$uid/$label" 2>/dev/null || true
    rm -f "$AGENTS/$label.plist"
  done
  if ! retry 10 no_tunnels; then
    pgrep -fl "$TUNNEL_PATTERN" >&2
    die "the tunnels above, not started by infer-access.sh, still reach the engine; stop them and rerun this."
  fi
}
# reset_engine: restart the engine, discarding everything in it.
reset_engine() {
  [ -s "$INFER_KEY_FILE" ] || die "there's no $INFER_KEY_FILE (host-setup.sh creates it)."
  key="$(cat "$INFER_KEY_FILE")"
  if sudo -n /bin/launchctl kickstart -k "system/$INFER_LABEL" 2>/dev/null; then
    retry 30 infer_engine_answers "$key" || die "the engine didn't come back after its reset."
  elif infer_engine_answers "$key"; then
    die "couldn't reset the engine (is host-setup.sh's sudoers rule installed?), so not opening any tunnels."
  else
    echo "WARNING: the engine isn't running (host-setup.sh starts it), so there's nothing to reset." >&2
  fi
}
# open_tunnel VM: open a tunnel from VM to the engine.
open_tunnel() {
  INFER_TUNNEL_VM="$1"
  INFER_TUNNEL_LABEL="$TUNNEL_PREFIX$1"
  plist="$AGENTS/$INFER_TUNNEL_LABEL.plist"
  render_template "$SCRIPT_DIR/infer-tunnel.template.plist" "$plist" \
    INFER_TUNNEL_LABEL INFER_TUNNEL_VM INFER_PORT
  plutil -lint -s "$plist"
  launchctl bootstrap "gui/$uid" "$plist"
  echo "Opened a tunnel from $1."
}
# switch_to MODE VM...: close every tunnel, reset the engine, record
# MODE, and open a tunnel from each VM.
switch_to() {
  mode="$1"
  shift
  for vm in "$@"; do
    # It goes into a launchd label and a plist.
    case "$vm" in
      "" | *[!A-Za-z0-9._-]*) die "can't use the VM name \"$vm\"; rename it with only letters, digits, '.', '_', and '-'." ;;
    esac
  done
  close_tunnels
  reset_engine
  mkdir -p "$(dirname "$STATE_FILE")"
  echo "$mode" > "$STATE_FILE"
  mkdir -p "$AGENTS"
  for vm in "$@"; do
    open_tunnel "$vm"
  done
  echo "Mode: $mode."
}

status() {
  echo "Mode: $(cat "$STATE_FILE" 2>/dev/null || echo "off (never set)")"
  for label in $(tunnel_labels); do
    state="$(launchctl print "gui/$uid/$label" 2>/dev/null | awk '$1 == "state" { print $3; exit }')"
    echo "Tunnel from ${label#"$TUNNEL_PREFIX"}: ${state:-not loaded}"
  done
  echo "ssh processes forwarding the engine's port:"
  pgrep -fl "$TUNNEL_PATTERN" || echo "  none"
}

case "${1:-}" in
  secure)
    [ -n "$INFER_SECURE_VM" ] ||
      die "config.sh's INFER_SECURE_VM isn't set (there's no secure VM yet)."
    switch_to secure "$INFER_SECURE_VM"
    ;;
  shared)
    # Ask before closing anything, so a failure here changes nothing.
    guests="$(enumerate_guests)" || die "couldn't list the running VMs (is UTM running?)."
    vms="$(printf '%s\n' "$guests" | awk -v secure="$INFER_SECURE_VM" '$1 != secure { print $1 }')"
    [ -n "$vms" ] || echo "WARNING: no VMs other than the secure VM are running." >&2
    # One name per line, and names can't contain spaces (see switch_to).
    # shellcheck disable=SC2086
    switch_to shared $vms
    ;;
  off)
    switch_to off
    ;;
  status)
    status
    ;;
  *)
    echo "Usage: $0 secure|shared|off|status" >&2
    exit 2
    ;;
esac
