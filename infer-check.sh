#!/bin/sh
# infer-check.sh: check that the local AI engine really serves its
# models. Run it on the Mac after host-setup.sh (or whenever a model
# misbehaves). It asks each text model for a few tokens and each image
# model for one small image, so it loads every model in turn, which
# takes a while for big ones. On a failure it shows the HTTP status and
# reply, the end of that model's log in llama-swap (the backend's own
# output), and the sandbox's recent denials for the engine's programs.
#
# Only you can tell whether an image is right (e.g., a VAE mismatch can
# give noise), so it saves each one as ,infer-check-MODEL.png in the
# current directory for you to look at.
#
# Usage: ./infer-check.sh [MODEL...]   (default: every model it serves)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

url="http://127.0.0.1:$INFER_PORT"
[ -s "$INFER_KEY_FILE" ] || die "no API key in $INFER_KEY_FILE; run host-setup.sh first."
# The key reaches curl on its stdin, not its command line, which any
# process here can read.
auth() { printf 'Authorization: Bearer %s\n' "$(cat "$INFER_KEY_FILE")"; }
listing="$(auth | curl -sS -m 10 -H @- "$url/v1/models")" ||
  die "couldn't reach the engine at $url."
# Each model and what it outputs, as "ID image" or "ID text"; the same
# rule as pi's filter in common.sh.
kinds="$(printf '%s\n' "$listing" | jq -er '.data[]
  | "\(.id) \(if (.architecture.output_modalities // ["text"]) | any(. == "image")
               then "image" else "text" end)"')" ||
  die "the engine's model listing isn't what I expect: $listing"
# shellcheck disable=SC2046 # model IDs have no spaces
[ $# -gt 0 ] || set -- $(printf '%s\n' "$kinds" | cut -d' ' -f1)

# report MODEL STATUS REPLY: show why MODEL failed.
report() {
  echo "FAIL: $1: HTTP $2: $(printf '%s' "$3" | head -c 500)"
  echo "  The end of $1's log in llama-swap:"
  # The log endpoint streams after the history, so cut it off.
  auth | curl -s -m 3 -H @- "$url/logs/stream/$1" | tail -n 30 | sed 's/^/    /'
  if [ "$(uname -s)" = Darwin ]; then
    echo "  Sandbox denials for the engine in the last 15 minutes:"
    /usr/bin/log show --last 15m --style compact --predicate 'sender == "Sandbox"' 2>/dev/null |
      grep -E 'llama-swap|llama-server|sd-server' | tail -n 20 | sed 's/^/    /'
  fi
}

failed=0
for model do
  kind="$(printf '%s\n' "$kinds" | awk -v m="$model" '$1 == m { print $2 }')"
  case "$kind" in
    text)
      body="$(jq -nc --arg m "$model" \
        '{model: $m, max_tokens: 8, messages: [{role: "user", content: "Say hello."}]}')"
      path=/v1/chat/completions
      ;;
    image)
      # 512x512 keeps it quick; klein's own size is 1024x1024.
      body="$(jq -nc --arg m "$model" '{model: $m, prompt: "a red apple on a table", size: "512x512"}')"
      path=/v1/images/generations
      ;;
    *)
      echo "FAIL: $model: the engine doesn't serve it"
      failed=1
      continue
      ;;
  esac
  echo "Checking $model ($kind); loading it can take minutes..."
  png=",infer-check-$model.png"
  rm -f "$png"
  reply="$(auth | curl -sS -m 1200 -w '\n%{http_code}' -H @- -H 'Content-Type: application/json' \
    -d "$body" "$url$path")" || {
    report "$model" "none (curl failed)" "$reply"
    failed=1
    continue
  }
  status="$(printf '%s\n' "$reply" | tail -n 1)"
  reply="$(printf '%s\n' "$reply" | sed '$d')"
  if [ "$status" != 200 ]; then
    report "$model" "$status" "$reply"
    failed=1
  elif [ "$kind" = text ]; then
    # A thinking model may spend all its tokens on reasoning.
    if text="$(printf '%s\n' "$reply" |
      jq -er '.choices[0].message | (.reasoning_content // "") + (.content // "")')" &&
      [ -n "$text" ]; then
      echo "ok: $model said: $(printf '%s' "$text" | tr '\n' ' ' | head -c 80)"
    else
      report "$model" "$status, but no text" "$reply"
      failed=1
    fi
  else
    # sd-server answers 200 with no image if it couldn't encode one.
    if printf '%s\n' "$reply" | jq -er '.data[0].b64_json' | base64 --decode > "$png" 2>/dev/null &&
      [ "$(head -c 4 "$png" | od -An -tx1 | tr -d ' ')" = 89504e47 ]; then
      echo "ok: $model made an image; look at $png to see whether it's right"
    else
      rm -f "$png"
      report "$model" "$status, but no PNG" "$reply"
      failed=1
    fi
  fi
done
# A specialist runs beside the generalist, so after the checks the last
# generalist and (until its ttl runs out) the last specialist are loaded.
echo "Loaded now: $(auth | curl -s -m 10 -H @- "$url/running" | jq -c '[.running[].model]')"
exit "$failed"
