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
# down, so the answer is untrusted: this fails unless each name uses only
# letters, digits, ".", "_", ":", and "-", each model that outputs text
# has a context window and a maximum reply length, and at most one model
# is the default. jq writes the JSON, so the listing can't inject
# anything into it.
set -eu

URL="http://127.0.0.1:@@INFER_PORT@@/v1"
KEY_FILE="$HOME/.config/bulkhead/infer-api-key"

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

printf '%s' "$listing" | jq --arg url "$URL" '
  def plain: type == "string" and test("^[A-Za-z0-9._:-]+$");
  def number: type == "number" and . > 0;
  def modalities: type == "array" and all(.[]; type == "string");
  [.data[] | {
    id,
    name: (if (.name | type) == "string" and .name != "" then .name else .id end),
    variant_of: (if .meta.llamaswap.type == "alias" then .meta.llamaswap.modelID else null end),
    default: (.meta.llamaswap.default == true and .meta.llamaswap.type != "alias"),
    context: .context_length,
    max_tokens: .meta.llamaswap.max_tokens,
    input: (.architecture.input_modalities // ["text"]),
    output: (.architecture.output_modalities // ["text"])
  }
  | if (.id | plain | not) then error("bad model name: \(.id)")
    elif .variant_of != null and (.variant_of | plain | not) then error("\(.id) is a variant of a bad model name")
    elif (.input | modalities | not) or (.output | modalities | not) then error("\(.id) has bad modalities")
    elif (.output | any(. == "text")) and ((.context | number | not) or (.max_tokens | number | not))
    then error("\(.id) lacks capabilities.context or metadata.max_tokens")
    elif (.output | any(. == "text") | not) then .context = null | .max_tokens = null
    else . end]
  | [.[] | select(.default) | .id] as $defaults
  | if ($defaults | length) > 1 then error("more than one default: \($defaults | join(", "))") else . end
  | {url: $url, default: ($defaults[0] // null), models: map(del(.default))}'
