#!/bin/sh
# infer-watch-hook: what infer-watch (infer-watch.c) runs, as you, on
# the Mac's sleep, wake, and power changes. Rendered and installed by
# host-setup.sh; see local-ai-plan.md, "Kill on sleep" and "Power and
# cooling". Its output goes to ~/Library/Logs/infer-watch.log.
#
#   infer-watch-hook sleep   # close the tunnels, then unload the model
#   infer-watch-hook wake    # reopen the tunnels infer-access.sh set up
#   infer-watch-hook power   # Low Power Mode while the battery is low
set -u

PORT="@@INFER_PORT@@"
KEY_FILE="@@INFER_KEY_FILE@@"
ENGINE_LABEL="@@INFER_LABEL@@"
LOW_BELOW="@@INFER_LOW_POWER_BELOW@@"
LOW_UNTIL="@@INFER_LOW_POWER_UNTIL@@"
TUNNEL_PREFIX=local.infer-tunnel.
AGENTS="$HOME/Library/LaunchAgents"
# The power modes this replaced with Low ("BATTERY AC"), while it's
# responsible for them, or "manual" after you changed them by hand.
SAVED="$HOME/.config/bulkhead/infer-power-saved"
uid="$(id -u)"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}
# wait_until TENTHS COMMAND...: true once COMMAND succeeds, checking
# every tenth of a second, up to TENTHS times.
wait_until() {
  n="$1"
  shift
  until "$@"; do
    [ "$n" -gt 0 ] || return 1
    sleep 0.1
    n=$((n - 1))
  done
}
no_tunnels() {
  ! pgrep -f "ssh .*-R *[^ ]*$PORT:127\.0\.0\.1:$PORT" >/dev/null
}
no_model() {
  ! pgrep -x llama-server >/dev/null
}

# Before sleep: the model's weights and KV cache are in wired memory,
# which goes into the sleep image, so stop llama-server, which frees
# them. First close the tunnels (leaving infer-access.sh's plists for
# "wake"), so no VM can load a model again before the Mac sleeps.
# infer-watch gives this 25 seconds.
on_sleep() {
  for plist in "$AGENTS/$TUNNEL_PREFIX"*.plist; do
    [ -f "$plist" ] || continue
    launchctl bootout "gui/$uid/$(basename "$plist" .plist)" 2>/dev/null || true
  done
  wait_until 30 no_tunnels ||
    log "Sleep: WARNING: an ssh not started by infer-access.sh still reaches the engine."
  if no_model; then
    log "Sleep: no model loaded."
    return 0
  fi
  curl -sS -m 5 -o /dev/null -X POST -H "Authorization: Bearer $(cat "$KEY_FILE")" \
    "http://127.0.0.1:$PORT/api/models/unload" || log "Sleep: the unload request failed."
  if wait_until 80 no_model; then
    log "Sleep: unloaded the model."
    return 0
  fi
  # Restarting the engine stops llama-server too.
  log "Sleep: the model is still loaded; restarting the engine."
  sudo -n /bin/launchctl kickstart -k "system/$ENGINE_LABEL" >/dev/null
  if wait_until 50 no_model; then
    log "Sleep: restarted the engine, which unloaded the model."
    return 0
  fi
  log "Sleep: ERROR: llama-server is still running, so the model may go into the sleep image."
  return 1
}

# After waking: reopen each tunnel that "sleep" closed.
on_wake() {
  for plist in "$AGENTS/$TUNNEL_PREFIX"*.plist; do
    [ -f "$plist" ] || continue
    label="$(basename "$plist" .plist)"
    launchctl print "gui/$uid/$label" >/dev/null 2>&1 && continue
    if launchctl bootstrap "gui/$uid" "$plist"; then
      log "Wake: reopened the tunnel from ${label#"$TUNNEL_PREFIX"}."
    else
      log "Wake: couldn't reopen the tunnel from ${label#"$TUNNEL_PREFIX"}."
    fi
  done
}

# mode_ok MODE: true if MODE is a power mode we can set (see the
# sudoers rules in host-setup.sh): 0 Automatic, 1 Low, or 2 High.
mode_ok() {
  case "$1" in 0 | 1 | 2) return 0 ;; *) return 1 ;; esac
}
# Below LOW_BELOW percent, on either power source, switch both sources
# to Low Power Mode, saving their modes; at LOW_UNTIL percent or more
# while plugged in, restore them. Only undo our own change: if either
# mode isn't Low any more, you changed it by hand, so forget them, and
# leave the modes alone until the battery is back to LOW_UNTIL percent.
on_power() {
  batt="$(pmset -g batt)"
  percent="$(printf '%s\n' "$batt" | sed -n 's/.*[[:space:]]\([0-9][0-9]*\)%;.*/\1/p' | head -n 1)"
  [ -n "$percent" ] || return 0 # no battery
  case "$batt" in
    *"'AC Power'"*) plugged_in=true ;;
    *) plugged_in=false ;;
  esac
  modes="$(pmset -g custom | awk '
    /^Battery Power:/ { source = "battery" }
    /^AC Power:/ { source = "ac" }
    $1 == "powermode" { mode[source] = $2 }
    END { print mode["battery"], mode["ac"] }')"
  read -r battery_mode ac_mode <<EOF
$modes
EOF
  if [ "$(cat "$SAVED" 2>/dev/null)" = manual ]; then
    [ "$percent" -lt "$LOW_UNTIL" ] || rm -f "$SAVED"
  elif [ -f "$SAVED" ]; then
    if [ "$battery_mode" != 1 ] || [ "$ac_mode" != 1 ]; then
      echo manual > "$SAVED"
      log "Power: the power mode was changed by hand; leaving it alone until the battery is at $LOW_UNTIL%."
    elif [ "$plugged_in" = true ] && [ "$percent" -ge "$LOW_UNTIL" ]; then
      read -r saved_battery saved_ac < "$SAVED"
      if ! mode_ok "$saved_battery" || ! mode_ok "$saved_ac"; then
        rm -f "$SAVED"
        log "Power: ERROR: $SAVED is garbled; leaving Low Power Mode on."
        return 1
      fi
      if ! sudo -n /usr/bin/pmset -b powermode "$saved_battery" ||
          ! sudo -n /usr/bin/pmset -c powermode "$saved_ac"; then
        log "Power: ERROR: couldn't restore the power modes."
        return 1
      fi
      rm -f "$SAVED"
      log "Power: battery at $percent% and plugged in; restored the power modes ($saved_battery on battery, $saved_ac on AC)."
    fi
  elif [ "$percent" -lt "$LOW_BELOW" ] && { [ "$battery_mode" != 1 ] || [ "$ac_mode" != 1 ]; }; then
    if ! mode_ok "$battery_mode" || ! mode_ok "$ac_mode"; then
      log "Power: ERROR: unexpected power modes \"$battery_mode\" and \"$ac_mode\"; not changing them."
      return 1
    fi
    mkdir -p "$(dirname "$SAVED")"
    echo "$battery_mode $ac_mode" > "$SAVED"
    if ! sudo -n /usr/bin/pmset -a powermode 1; then
      rm -f "$SAVED"
      log "Power: ERROR: couldn't switch to Low Power Mode."
      return 1
    fi
    log "Power: battery at $percent%; switched to Low Power Mode."
  fi
}

case "${1:-}" in
  sleep) on_sleep ;;
  wake) on_wake ;;
  power) on_power ;;
  *)
    echo "Usage: $0 sleep|wake|power" >&2
    exit 2
    ;;
esac
