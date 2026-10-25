#!/bin/sh
# infer-models: print the models the Mac's local AI engine serves now, in
# a form any client can use. A client's wrapper (e.g., nopi) runs it each
# time the client starts and turns its answer into the client's own
# configuration, so changing the models on the Mac (see manage-models.sh
# there) needs nothing done on any VM. It asks the engine (llama-swap's
# /v1/models) through this VM's tunnel, with the API key in
# ~/.config/bulkhead/infer-api-key; the client needs that key too.
# vm-setup.sh renders and installs this.
#
# Usage: infer-models           (ask the engine)
#        infer-models --stdin   (read a /v1/models listing instead, e.g., to test)
#
# It prints, e.g.:
#   {"url": "http://127.0.0.1:PORT/v1", "default": "qwen3.8-27b",
#    "models": [{"id": "qwen3.8-27b", "name": "Qwen3.8-27B Q8_0",
#      "variant_of": null, "context": 262144, "max_tokens": 32768,
#      "input": ["text", "image"], "output": ["text"]}, ...]}
# "default" is null when no model is the default. A variant (a llama-swap
# alias, e.g., with other sampling settings) names its model in
# "variant_of". "context" (the context window) and "max_tokens" (the most
# one reply may use) are null for a model that doesn't output text.
#
# Anything on this VM could answer on that port while the tunnel is
# down, so the answer is untrusted: infer-models.jq checks it, and fails
# if it breaks a rule (see that file).
set -eu

URL="http://127.0.0.1:@@INFER_PORT@@/v1"
KEY_FILE="$HOME/.config/bulkhead/infer-api-key"
FILTER=/usr/local/libexec/bulkhead/infer-models.jq

case "$*" in
  "")
    # The key reaches curl on its stdin, not its command line, which any
    # process here can read.
    listing="$(printf 'Authorization: Bearer %s\n' "$(cat "$KEY_FILE")" |
      curl -sf -m 10 -H @- "$URL/models")" || {
      echo "infer-models: the engine didn't answer at $URL (on the Mac, see ./infer-access.sh)." >&2
      exit 1
    }
    ;;
  --stdin) listing="$(cat)" ;;
  *) echo "Usage: infer-models [--stdin]" >&2; exit 2 ;;
esac

printf '%s' "$listing" | jq --arg url "$URL" -f "$FILTER"
