#!/bin/sh
# pi-local: run pi against the Mac's local AI models, which llama-swap
# serves through this VM's SSH tunnel (see local-ai-plan.md). pi runs
# under nono (the nolabs-ai/pi profile, through anon-access like
# noclaude), with no automatic network activity of its own (no model
# catalog refresh, version check, or telemetry). The API key comes from a
# file only you can read, and reaches pi only through its environment.
# vm-setup.sh renders and installs this, and generates the models pi
# knows (~/.pi/agent/models.json) from config.sh's INFER_MODELS.
#
# Usage: pi-local [pi arguments...], e.g., pi-local --print "Say hello"
# or pi-local --model qwen3-0.6b (a later --model overrides the default).

set -eu

PI_PREFIX=/usr/local/lib/pi
KEY_FILE="$HOME/.config/bulkhead/infer-api-key"

INFER_API_KEY="$(cat "$KEY_FILE")"
PI_OFFLINE=1
PI_SKIP_VERSION_CHECK=1
PI_TELEMETRY=0
export INFER_API_KEY PI_OFFLINE PI_SKIP_VERSION_CHECK PI_TELEMETRY

exec anon-access nono run --profile nolabs-ai/pi --allow-cwd --read "$PI_PREFIX" -- \
  "$PI_PREFIX/node_modules/.bin/pi" --provider mac-local --model @@INFER_DEFAULT_MODEL@@ "$@"
