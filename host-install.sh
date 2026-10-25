# shellcheck shell=sh
# host-install.sh: what host-setup.sh and install-models.sh share to
# install the local AI engine's files root-owned (with sudo): where they
# go, and the staging that checks each one before it replaces the
# running engine's. manage-models.sh doesn't source this, since it never
# uses sudo. macOS only. Source this after config.sh, common.sh, and
# host-models.sh:
#   . "$(dirname "$0")/host-install.sh"

INFER_ETC=/usr/local/etc/infer
INFER_PROFILE="$INFER_ETC/infer.sb"
INFER_CONFIG="$INFER_ETC/llama-swap.yaml"
INFER_PLIST="/Library/LaunchDaemons/$INFER_LABEL.plist"
INFER_SUDOERS=/etc/sudoers.d/infer
# The backends listen here: the generalist (a llama-server) on one port
# and the specialist (an sd-server) on the other, at most one of each at
# a time (see infer_llama_swap_yaml in host-models.sh).
INFER_GENERALIST_PORT=8999
INFER_SPECIALIST_PORT=8998
# Each release goes in its own root-owned directory under these, and a
# "current" symlink in each names what's installed.
LLAMA_OPT=/opt/llama.cpp
SWAP_OPT=/opt/llama-swap
SD_OPT=/opt/stable-diffusion.cpp

# Every run of the engine's programs is as _infer, never as you or
# root, from a directory it can enter.
as_infer() {
  (cd /var/empty && sudo -u "$MACOS_INFER_USER" "$@")
}

# check_config FILE: llama-swap ($SWAP_BIN) accepts FILE.
check_config() {
  as_infer "$SWAP_BIN" -config "$1" -validate
}

# Usage: render_engine_config OUT
# Writes llama-swap's config for the models in models.local.yaml to OUT,
# using LLAMA_SERVER, SD_SERVER, and infer_key. Stops if the list breaks
# its rules, or MODELS_DIR doesn't have its files yet.
render_engine_config() {
  [ -f "$INFER_MODELS" ] ||
    die "there's no models.local.yaml yet; run ./manage-models.sh init."
  infer_models_ok "$INFER_MODELS" ||
    die "models.local.yaml breaks the rules in initial-models.yaml's opening comment (above)."
  infer_models_synced "$INFER_MODELS" ||
    die "MODELS_DIR doesn't have every file models.local.yaml names (above)."
  [ -n "$(infer_models_default "$INFER_MODELS")" ] ||
    echo "WARNING: no model is the default, so vm-setup.sh will stop; set one with ./manage-models.sh default NAME." >&2
  infer_llama_swap_yaml "$infer_key" "$LLAMA_SERVER" "$INFER_GENERALIST_PORT" \
    "$SD_SERVER" "$INFER_SPECIALIST_PORT" "$INFER_MODELS" > "$1"
}

# Stage each file, check it, and only then put them all in place, so a
# failed check leaves the running engine as it was, and the next run
# tries again. A file is checked where it will live (e.g., _infer must
# be able to read the config), as DEST.new: sudo ignores sudoers.d
# files whose names contain a dot, so a broken rule can't lock you out
# of sudo.
# stage SRC DEST GROUP MODE CHECK...: install SRC root-owned as DEST.new
# and run CHECK... DEST.new, stopping if it fails; then, if it's the
# same as DEST, discard it. $staged lists each DEST left to put in place.
staged=""
stage() {
  src="$1"
  dest="$2"
  group="$3"
  mode="$4"
  shift 4
  sudo install -o root -g "$group" -m "$mode" "$src" "$dest.new"
  if ! "$@" "$dest.new"; then
    for f in $staged "$dest"; do
      sudo rm -f "$f.new"
    done
    die "$dest.new failed its check ($1); left $dest as it was."
  fi
  if sudo cmp -s "$dest.new" "$dest"; then
    sudo rm -f "$dest.new"
  else
    staged="$staged $dest"
  fi
}
# The config holds the API key, so only _infer can read it.
stage_config() {
  stage "$1" "$INFER_CONFIG" "$MACOS_INFER_USER" 640 check_config
}

# wait_for_engine: wait until the engine answers, with the key.
wait_for_engine() {
  if ! retry 30 infer_engine_answers "$infer_key"; then
    echo "To see why, run it by hand: sudo -u $MACOS_INFER_USER /usr/bin/sandbox-exec -f $INFER_PROFILE $SWAP_BIN -config $INFER_CONFIG -listen 127.0.0.1:$INFER_PORT" >&2
    die "llama-swap didn't start (its output goes to /dev/null)."
  fi
}
