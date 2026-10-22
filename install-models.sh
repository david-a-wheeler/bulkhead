#!/bin/sh
# install-models.sh: have the local AI engine serve the models in
# models.local.yaml, after ./manage-models.sh changes them. It checks the
# list, renders llama-swap's config from it, has llama-swap check that,
# installs it root-owned (readable only by _infer, since it holds the API
# key), and restarts the engine if the config changed. It never
# downloads; if a file the list names is missing, it says to run
# ./manage-models.sh sync. host-setup.sh installs the same config, along
# with the engine itself, so you only need this between its runs.
#
# Usage:
#   ./install-models.sh [--no-restart]
#
# It uses sudo, with your password: there's deliberately no
# passwordless rule for it, since that would let any process running as
# you change what _infer runs. The restart stops any loaded model,
# discarding its KV cache; --no-restart installs the config without
# restarting, so the engine uses it from its next restart (e.g., by
# ./infer-access.sh or the sleep watcher, or
# "sudo launchctl kickstart -k system/local.infer"). Run host-setup.sh
# first, since this uses the engine release it installed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/host-models.sh"
. "$SCRIPT_DIR/host-install.sh"

macos_only "install-models.sh"

restart=true
case "${1:-}" in
  "") ;;
  --no-restart) restart=false ;;
  -h | --help)
    sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  *)
    echo "Usage: $0 [--no-restart]" >&2
    exit 2
    ;;
esac
[ $# -le 1 ] || { echo "Usage: $0 [--no-restart]" >&2; exit 2; }

# The release host-setup.sh installed: what each "current" link names.
for d in "$LLAMA_OPT" "$SWAP_OPT" "$SD_OPT"; do
  [ -L "$d/current" ] || die "$d/current is missing; run ./host-setup.sh first."
done
[ -f "$INFER_PLIST" ] || die "the engine isn't installed; run ./host-setup.sh first."
LLAMA_SERVER="$LLAMA_OPT/$(readlink "$LLAMA_OPT/current")/llama-server"
SWAP_BIN="$SWAP_OPT/$(readlink "$SWAP_OPT/current")/llama-swap"
SD_SERVER="$SD_OPT/$(readlink "$SD_OPT/current")/sd-server"
[ -s "$INFER_KEY_FILE" ] || die "there's no API key in $INFER_KEY_FILE; run ./host-setup.sh first."
infer_key="$(cat "$INFER_KEY_FILE")"

infer_tmp="$SCRIPT_DIR/.tmp/install-models"
rm -rf "${infer_tmp:?}"
mkdir -p "$infer_tmp"
trap 'rm -rf "${infer_tmp:?}"' EXIT
render_engine_config "$infer_tmp/llama-swap.yaml"
stage_config "$infer_tmp/llama-swap.yaml"
if [ -z "$staged" ]; then
  echo "The engine's config is up to date."
  exit 0
fi
sudo mv "$INFER_CONFIG.new" "$INFER_CONFIG"
if ! $restart; then
  echo "Installed the new config; the engine uses it from its next restart."
  exit 0
fi
sudo /bin/launchctl kickstart -k "system/$INFER_LABEL"
wait_for_engine
echo "Installed the new config and restarted the engine."
echo "Each VM's clients (e.g., nopi) see the change the next time they start."
