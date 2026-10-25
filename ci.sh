#!/bin/sh
# ci.sh: runs every check this repo has (shellcheck, syntax checks, a
# couple of logic tests). Run it locally before committing; .github/
# workflows/ci.yml just calls this same script, so local and CI runs are
# always identical, never two checklists that can drift apart.
#
# Usage: ./ci.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT

fail=0
step() {
  echo
  echo "== $1 =="
}

step "awk lint (gawk --posix --lint)"
# Each .awk program must parse, with no lint warnings, using only POSIX
# awk (macOS's awk runs them). A problem here stops ci.sh at once, since
# every later test that runs the program would fail less clearly. -o
# pretty-prints the program instead of running it.
if command -v gawk > /dev/null; then
  for f in *.awk tests/*.awk; do
    [ -f "$f" ] || continue
    if ! out="$(gawk --posix --lint -o/dev/null -f "$f" 2>&1)" || [ -n "$out" ]; then
      printf '%s\n' "$out" >&2
      echo "FAILED: awk lint of $f (above); stopping." >&2
      exit 1
    fi
  done
else
  echo "Skipping the awk lint check: gawk isn't installed."
fi

# Plain scripts: no @@VAR@@ templating, safe to check as-is.
PLAIN_SCRIPTS="config.sh common.sh host-backend.sh host-models.sh host-install.sh host-setup.sh infer-check.sh manage-models.sh install-models.sh vm-setup.sh nopi my-gen-image host-secrets.sh infer-access.sh rotate-github-pat.sh rotate-heroku-key.sh anon-access heroku-session gh-session vm-git-helper noclaude check-prose-style.sh git-commit-msg git-hook-passthrough tests/sleep-test.sh"

step "shellcheck (plain scripts)"
# shellcheck disable=SC2086
if ! shellcheck -x $PLAIN_SCRIPTS; then
  fail=1
fi

step "dash -n (plain scripts)"
for f in $PLAIN_SCRIPTS; do
  if ! dash -n "$f"; then
    echo "FAILED: $f" >&2
    fail=1
  fi
done

step "rendering and checking templates"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# No shebang (sourced into ~/.bash_aliases, never run directly), so it
# needs an explicit "shellcheck -s bash" rather than joining
# PLAIN_SCRIPTS above, which relies on each file's own shebang for shell
# detection. (No comment line may start with the word "shellcheck", or
# that tool parses the line as a directive.)
if ! dash -n vm-bash-aliases-block.sh; then
  echo "FAILED: vm-bash-aliases-block.sh (dash -n)" >&2
  fail=1
fi
if ! bash -n vm-bash-aliases-block.sh; then
  echo "FAILED: vm-bash-aliases-block.sh (bash -n)" >&2
  fail=1
fi
if ! shellcheck -x -s bash vm-bash-aliases-block.sh; then
  fail=1
fi

render_template secrets-client.template.py "$tmp/secrets-client" SECRETS_SERVER_PORT
render_template secrets-server.template.py "$tmp/secrets-server.py" \
  SECRETS_SERVER_PORT KEYCHAIN_PREFIX UTMCTL
for f in "$tmp/secrets-client" "$tmp/secrets-server.py" extract-chat-template.py tests/check_llama_swap_config.py; do
  if ! python3 -m py_compile "$f"; then
    echo "FAILED: $f (py_compile)" >&2
    fail=1
  fi
done

render_template infer-models.template.sh "$tmp/infer-models.installed" INFER_PORT
sed "s|^FILTER=.*|FILTER=\"$SCRIPT_DIR/infer-models.jq\"|" "$tmp/infer-models.installed" > "$tmp/infer-models"
render_template infer-logs.template.sh "$tmp/infer-logs" INFER_PORT
render_template infer-watch-hook.template.sh "$tmp/infer-watch-hook" \
  INFER_PORT INFER_KEY_FILE INFER_LABEL INFER_LOW_POWER_BELOW INFER_LOW_POWER_UNTIL
for f in infer-models infer-logs infer-watch-hook; do
  if ! dash -n "$tmp/$f" || ! shellcheck "$tmp/$f"; then
    echo "FAILED: $f" >&2
    fail=1
  fi
done
INFER_LABEL=test.label MACOS_INFER_USER=_infer INFER_PROFILE=/p SWAP_BIN=/b INFER_CONFIG=/c
render_template infer.template.plist "$tmp/infer.plist" \
  INFER_LABEL MACOS_INFER_USER INFER_PROFILE SWAP_BIN INFER_CONFIG INFER_PORT
INFER_TUNNEL_LABEL=test.tunnel INFER_TUNNEL_VM=testvm
render_template infer-tunnel.template.plist "$tmp/infer-tunnel.plist" \
  INFER_TUNNEL_LABEL INFER_TUNNEL_VM INFER_PORT
render_template infer-watch.template.plist "$tmp/infer-watch.plist" INFER_WATCH_LABEL HOME
for f in infer.plist infer-tunnel.plist infer-watch.plist; do
  if ! python3 -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' "$tmp/$f" ||
      grep -q '@@' "$tmp/$f"; then
    echo "FAILED: $f" >&2
    fail=1
  fi
done

step "local AI models (initial-models.yaml)"
. "$SCRIPT_DIR/host-models.sh"
if ! infer_models_ok initial-models.yaml; then
  echo "FAILED: initial-models.yaml breaks its own rules" >&2
  fail=1
fi
# llama-swap isn't here to check the config, so check what pi and nopi
# need from it (tests/check_llama_swap_config.py).
infer_llama_swap_yaml sk-test /llama-server 8999 /sd-server 8998 initial-models.yaml > "$tmp/llama-swap.yaml"
if ! python3 -I tests/check_llama_swap_config.py "$tmp/llama-swap.yaml"; then
  echo "FAILED: the models in initial-models.yaml (above)" >&2
  fail=1
fi
# with_files: copies a models file, adding a well-formed "# file:" line
# after each cmd for each file it names ("# generated:" for a .jinja
# file), so a test entry breaks only the rule it's meant to.
with_files() {
  awk '{ print }
    /^    cmd:/ {
      rest = $0
      while (match(rest, /\$\{models-dir\}\/[^ "]+/)) {
        f = substr(rest, RSTART + 14, RLENGTH - 14)
        leaf = f
        sub(/.*\//, "", leaf)
        if (f ~ /\.jinja$/)
          printf "    # generated: %s\n", f
        else
          printf "    # file: %s %064d apache-2.0 https://example.com/%s\n", f, 0, leaf
        rest = substr(rest, RSTART + RLENGTH)
      }
    }'
}
# Entries infer_models_ok must refuse, each after a good one.
good='  m:
    cmd: ${llama-server} --model ${models-dir}/m.gguf --ctx-size 4096
    proxy: ${proxy}'
for bad in 'apiKeys:
  - "sk-x"' \
  '  n:
    cmd: /bin/sh -c evil
    proxy: ${proxy}' \
  '  n:
    cmd: ${llama-server} --model ${models-dir}/n.gguf --host 0.0.0.0
    proxy: ${proxy}' \
  '  n:
    cmd: ${llama-server} --model ${models-dir}/n.gguf' \
  '  n:
    cmd: ${llama-server} --model ${models-dir}/n.gguf
    proxy: http://127.0.0.1:1234' \
  "$(printf '  n:\n\tcmd: ${llama-server}\n    proxy: ${proxy}')" \
  '  n: {cmd: /bin/sh -c evil, proxy: ${proxy}}' \
  '  n:
    "cmd": /bin/sh -c evil
    proxy: ${proxy}' \
  '  n:
      cmd: /bin/sh -c evil
    proxy: ${proxy}' \
  '  n:
    cmd: ${llama-server} --model ${models-dir}/n.gguf
    cmd: ${llama-server} --model ${models-dir}/n.gguf
    proxy: ${proxy}' \
  '  m:
    cmd: ${llama-server} --model ${models-dir}/m.gguf
    proxy: ${proxy}' \
  '  n:
    cmd: ${sd-server} --diffusion-model ${models-dir}/n.gguf -l 0.0.0.0
    proxy: ${specialist-proxy}
    ttl: 600
    capabilities:
      out: [image]' \
  '  n:
    macros:
      sd-server: /bin/sh -c evil
    cmd: ${sd-server} --diffusion-model ${models-dir}/n.gguf
    proxy: ${specialist-proxy}
    ttl: 600
    capabilities:
      out: [image]' \
  '  n:
    cmd: ${sd-server} --diffusion-model ${models-dir}/n.gguf
    proxy: ${proxy}
    ttl: 600
    capabilities:
      out: [image]' \
  '  n:
    cmd: ${sd-server} --diffusion-model ${models-dir}/n.gguf
    proxy: ${specialist-proxy}
    capabilities:
      out: [image]' \
  '  n:
    cmd: ${sd-server} --diffusion-model ${models-dir}/n.gguf
    proxy: ${specialist-proxy}
    ttl: 7200
    capabilities:
      out: [image]' \
  '  n:
    cmd: ${sd-server} --diffusion-model ${models-dir}/n.gguf
    proxy: ${specialist-proxy}
    ttl: 0
    capabilities:
      out: [image]' \
  '  n:
    cmd: ${sd-server} --diffusion-model ${models-dir}/n.gguf
    proxy: ${specialist-proxy}
    ttl: 600' \
  '  n:
    cmd: ${sd-server} --diffusion-model ${models-dir}/n.gguf
    proxy: ${specialist-proxy}
    ttl: 600
    metadata:
      out: [image]' \
  '  n:
    cmd: ${llama-server} --model ${models-dir}/n.gguf
    proxy: ${specialist-proxy}' \
  '  n:
    cmd: ${llama-server} --model ${models-dir}/n.gguf
    proxy: ${proxy}
    capabilities:
      out: [image]' \
  '  n:
    cmd: ${other} --model ${models-dir}/n.gguf
    proxy: ${proxy}' \
  'models:
  n:
    cmd: ${llama-server} --model ${models-dir}/n.gguf
    proxy: ${proxy}' \
  '  n:
    cmd: ${sd-server} --diffusion-model ${models-dir}/n.gguf
    proxy: ${specialist-proxy}
    ttl: 600
    capabilities:
      out: [image]
    metadata:
      default: true' \
  '  n:
    cmd: ${llama-server} --model ${models-dir}/n.gguf
    proxy: ${proxy}
    metadata:
      default: true
  o:
    cmd: ${llama-server} --model ${models-dir}/o.gguf
    proxy: ${proxy}
    metadata:
      default: true'; do
  printf 'models:\n%s\n%s\n' "$good" "$bad" | with_files > "$tmp/bad-models.yaml"
  if infer_models_ok "$tmp/bad-models.yaml" 2>/dev/null; then
    echo "FAILED: infer_models_ok accepted:" >&2
    cat "$tmp/bad-models.yaml" >&2
    fail=1
  fi
done
good_sd='  m-img:
    cmd: ${sd-server} --diffusion-model ${models-dir}/m.gguf --vae ${models-dir}/vae.gguf
    proxy: "${specialist-proxy}"
    ttl: 300
    capabilities:
      in: [text]
      out: [image]
  m-vision:
    cmd: ${llama-server} --model ${models-dir}/v.gguf
    proxy: ${proxy}
    capabilities:
      in: [text, image]
      out: [text]'
printf 'models:\n%s\n%s\n' "$good" "$good_sd" | with_files > "$tmp/good-models.yaml"
infer_models_ok "$tmp/good-models.yaml" ||
  { echo "FAILED: infer_models_ok rejected a good entry" >&2; fail=1; }
got="$(infer_model_roles "$tmp/good-models.yaml" | tr '\n' ' ')"
[ "$got" = "m generalist m-img specialist m-vision generalist " ] ||
  { echo "FAILED: infer_model_roles gave '$got'" >&2; fail=1; }
[ -z "$(infer_models_default "$tmp/good-models.yaml")" ] ||
  { echo "FAILED: infer_models_default found a default where there's none" >&2; fail=1; }
# "# file:" lines infer_models_ok must refuse: each replaces the good
# entry's line. Then a file listed by two models, in two ways, and a
# model whose files and cmd don't match.
z64="$(printf '%064d' 0)"
for bad in "m.gguf $z64 apache-2.0" \
  "m.gguf $z64 apache-2.0 http://example.com/m.gguf" \
  "m.gguf $z64 apache-2.0 https://example.com/other.gguf" \
  "m.gguf ${z64}0 apache-2.0 https://example.com/m.gguf" \
  "m.gguf $(printf '%064d' 0 | tr 0 A) apache-2.0 https://example.com/m.gguf" \
  "m.gguf $z64 apache\"2 https://example.com/m.gguf" \
  "m.gguf $z64 apache-2.0 https://example.com/m.gguf?x=\$y" \
  "m.bin $z64 apache-2.0 https://example.com/m.bin" \
  "../m.gguf $z64 apache-2.0 https://example.com/m.gguf" \
  "a/b/m.gguf $z64 apache-2.0 https://example.com/m.gguf" \
  "m.gguf  $z64 apache-2.0 https://example.com/m.gguf"; do
  printf 'models:\n%s\n' "$good" | with_files |
    B="    # file: $bad" awk '/^    # file:/ { $0 = ENVIRON["B"] } { print }' > "$tmp/bad-models.yaml"
  if infer_models_ok "$tmp/bad-models.yaml" 2>/dev/null; then
    echo "FAILED: infer_models_ok accepted the file line: $bad" >&2
    fail=1
  fi
done
printf 'models:\n%s\n' "$good" | with_files > "$tmp/m.yaml"
for bad in "$(printf '%s\n  n:\n    # file: m.gguf %064d mit https://example.com/m.gguf\n    cmd: ${llama-server} --model ${models-dir}/m.gguf\n    proxy: ${proxy}' "$(sed 1d "$tmp/m.yaml")" 0)" \
  "$(printf '%s\n    # file: x.gguf %064d mit https://example.com/x.gguf' "$(sed 1d "$tmp/m.yaml")" 0)" \
  "$(printf '%s\n' "$good")" \
  "$(printf '    # file: m.gguf %064d mit https://example.com/m.gguf\n%s' 0 "$(sed 1d "$tmp/m.yaml")")"; do
  printf 'models:\n%s\n' "$bad" > "$tmp/bad-models.yaml"
  if infer_models_ok "$tmp/bad-models.yaml" 2>/dev/null; then
    echo "FAILED: infer_models_ok accepted:" >&2
    cat "$tmp/bad-models.yaml" >&2
    fail=1
  fi
done
# The same file in two models, listed the same way, is fine.
printf '%s\n  n:\n%s\n    cmd: ${llama-server} --model ${models-dir}/m.gguf\n    proxy: ${proxy}\n' \
  "$(cat "$tmp/m.yaml")" "$(grep '# file:' "$tmp/m.yaml")" > "$tmp/shared.yaml"
infer_models_ok "$tmp/shared.yaml" ||
  { echo "FAILED: infer_models_ok rejected a file two models share" >&2; fail=1; }
[ "$(infer_model_files "$tmp/shared.yaml" | wc -l)" -eq 1 ] ||
  { echo "FAILED: infer_model_files listed a shared file twice" >&2; fail=1; }
# A .jinja chat template a model's cmd uses, listed as "# generated:"
# (this host writes it; nothing downloads it): refuse a cmd that uses
# one without the line, a line naming a non-.jinja file or a path
# outside MODELS_DIR, a line with more than a path, a line outside a
# model, and a line the cmd never uses; accept the good one.
gen_good='  g:
    # file: g.gguf %064d apache-2.0 https://example.com/g.gguf
    # generated: g.chat-template.jinja
    cmd: ${llama-server} --model ${models-dir}/g.gguf --jinja --chat-template ${models-dir}/g.chat-template.jinja --ctx-size 4096
    proxy: ${proxy}'
printf "models:\n$gen_good\n" 0 > "$tmp/g.gen.yaml"
infer_models_ok "$tmp/g.gen.yaml" ||
  { echo "FAILED: infer_models_ok rejected a good # generated: entry" >&2; fail=1; }
for bad in "$(grep -v '# generated:' "$tmp/g.gen.yaml")" \
  "$(sed 's|# generated: g.chat-template.jinja|# generated: g.gguf|' "$tmp/g.gen.yaml")" \
  "$(sed 's|# generated: g.chat-template.jinja|# generated: ../g.chat-template.jinja|' "$tmp/g.gen.yaml")" \
  "$(sed 's|# generated: g.chat-template.jinja|# generated: g.chat-template.jinja x|' "$tmp/g.gen.yaml")" \
  "$(awk 'NR == 1 { print; print "    # generated: g.chat-template.jinja"; next } 1' "$tmp/g.gen.yaml")" \
  "$(sed 's|--chat-template ${models-dir}/g.chat-template.jinja ||' "$tmp/g.gen.yaml")"; do
  printf '%s\n' "$bad" > "$tmp/bad-models.yaml"
  if infer_models_ok "$tmp/bad-models.yaml" 2>/dev/null; then
    echo "FAILED: infer_models_ok accepted a bad # generated: entry:" >&2
    cat "$tmp/bad-models.yaml" >&2
    fail=1
  fi
done
infer_llama_swap_yaml sk-test /llama-server 8999 /sd-server 8998 "$tmp/good-models.yaml" > "$tmp/both.yaml"
got="$(python3 -I -c 'import sys, yaml; print(" ".join(yaml.safe_load(open(sys.argv[1]))["models"]))' "$tmp/both.yaml")"
if [ "$got" != "m m-img m-vision" ]; then
  echo "FAILED: the config for a list has models '$got', not 'm m-img m-vision'" >&2
  fail=1
fi
# render_engine_config (host-install.sh), which host-setup.sh and
# install-models.sh use: it refuses a list whose files aren't in
# MODELS_DIR (by SHA256SUMS), and renders one whose files are.
if ! (
  . "$SCRIPT_DIR/host-install.sh"
  MODELS_DIR="$tmp/models" INFER_MODELS="$tmp/good-models.yaml"
  infer_key=sk-test LLAMA_SERVER=/llama-server SD_SERVER=/sd-server
  if (render_engine_config "$tmp/r.yaml") 2>/dev/null; then
    echo "FAILED: render_engine_config accepted a list whose files are missing" >&2
    exit 1
  fi
  mkdir -p "$MODELS_DIR"
  infer_model_files "$INFER_MODELS" | while read -r f sha256 _; do
    : > "$MODELS_DIR/$f"
    printf '%s  %s\n' "$sha256" "$f"
  done > "$MODELS_DIR/SHA256SUMS"
  render_engine_config "$tmp/r.yaml" 2>/dev/null
  infer_llama_swap_yaml sk-test /llama-server 8999 /sd-server 8998 "$INFER_MODELS" | cmp -s - "$tmp/r.yaml"
  # A list that also uses a generated file renders only once that file
  # is in MODELS_DIR too.
  : > "$MODELS_DIR/g.gguf"
  printf '%s  %s\n' "$(printf '%064d' 0)" "g.gguf" >> "$MODELS_DIR/SHA256SUMS"
  if (INFER_MODELS="$tmp/g.gen.yaml" render_engine_config "$tmp/r2.yaml") 2>/dev/null; then
    echo "FAILED: render_engine_config accepted a list whose generated file is missing" >&2
    exit 1
  fi
  : > "$MODELS_DIR/g.chat-template.jinja"
  if ! INFER_MODELS="$tmp/g.gen.yaml" render_engine_config "$tmp/r2.yaml" 2>/dev/null; then
    echo "FAILED: render_engine_config refused a list whose generated file is there" >&2
    exit 1
  fi
); then
  echo "FAILED: render_engine_config (above)" >&2
  fail=1
fi
# infer-models and pi-models.jq, from llama-swap v265's real listing
# for initial-models.yaml (trimmed to the fields we use). A variant (type
# "alias") repeats its model's metadata, and comes first here, so picking
# it as the default would show. The image model, and qwen3.8-27b's
# capabilities.in (which its alias shares), are added as llama-swap's
# api.go would list them: the image model must not reach pi, and pi must
# learn which models take images.
listing='{"data": [{"id": "flux2-klein-4b", "name": "FLUX.2-klein 4B Q8_0 (images)", "architecture": {"input_modalities": ["text"], "output_modalities": ["image"], "modality": "text->image"}, "meta": {"llamaswap": {"type": "model"}}}, {"id": "qwen3.8-27b:instruct", "name": "Qwen3.8-27B Q8_0", "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"], "modality": "text+image->text"}, "context_length": 262144, "meta": {"llamaswap": {"default": true, "max_tokens": 16384, "modelID": "qwen3.8-27b", "type": "alias"}, "n_ctx": 262144}}, {"id": "qwen3-0.6b", "name": "Qwen3-0.6B Q4_0 (tests)", "context_length": 32768, "meta": {"llamaswap": {"max_tokens": 4096, "type": "model"}, "n_ctx": 32768}}, {"id": "qwen3.8-27b", "name": "Qwen3.8-27B Q8_0", "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"], "modality": "text+image->text"}, "context_length": 262144, "meta": {"llamaswap": {"aliases": ["qwen3.8-27b:instruct"], "default": true, "max_tokens": 16384, "type": "model"}, "n_ctx": 262144}}]}'
infer_models_stdin() {
  sh "$tmp/infer-models" --stdin
}
got="$(printf '%s' "$listing" | infer_models_stdin |
  jq -c '[.url, .default, [.models[] | [.id, .variant_of, .context, .max_tokens, .input, .output]]]')"
want='["http://127.0.0.1:'"$INFER_PORT"'/v1","qwen3.8-27b",[["flux2-klein-4b",null,null,null,["text"],["image"]],["qwen3.8-27b:instruct","qwen3.8-27b",262144,16384,["text","image"],["text"]],["qwen3-0.6b",null,32768,4096,["text"],["text"]],["qwen3.8-27b",null,262144,16384,["text","image"],["text"]]]]'
if [ "$got" != "$want" ]; then
  echo "FAILED: infer-models gave $got, not $want" >&2
  fail=1
fi
got="$(printf '%s' "$listing" | infer_models_stdin | jq -f pi-models.jq |
  jq -c '[.providers["mac-local"].models[] | [.id, .name, .contextWindow, .maxTokens, .input]]')"
want='[["qwen3.8-27b:instruct","Qwen3.8-27B Q8_0 (qwen3.8-27b:instruct)",262144,16384,["text","image"]],["qwen3-0.6b","Qwen3-0.6B Q4_0 (tests)",32768,4096,["text"]],["qwen3.8-27b","Qwen3.8-27B Q8_0",262144,16384,["text","image"]]]'
if [ "$got" != "$want" ]; then
  echo "FAILED: pi-models.jq gave $got, not $want" >&2
  fail=1
fi
got="$(printf '%s' "$listing" | infer_models_stdin | jq -f pi-models.jq | jq -c '.providers["mac-local"] |
  [.baseUrl, .apiKey, .compat.thinkingTokenBudgetField, ([.models[].thinkingLevelMap.off] | unique)]')"
want='["http://127.0.0.1:'"$INFER_PORT"'/v1","${INFER_API_KEY}","thinking_budget_tokens",["none"]]'
if [ "$got" != "$want" ]; then
  echo "FAILED: pi-models.jq's provider settings are $got, not $want" >&2
  fail=1
fi
got="$(printf '%s' '{"data": [{"id": "a", "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1}}}]}' |
  infer_models_stdin | jq -c .default)"
[ "$got" = null ] || { echo "FAILED: infer-models gave a default ($got) for a listing with none" >&2; fail=1; }
for bad in '{"data": [{"id": "a b", "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1}}}]}' \
  '{"data": [{"id": "a", "context_length": 1}]}' \
  '{"data": [{"id": "a", "context_length": "1", "meta": {"llamaswap": {"max_tokens": 1}}}]}' \
  '{"data": [{"id": "a", "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1, "type": "alias", "modelID": "b c"}}}]}' \
  '{"data": [{"id": "a", "architecture": {"input_modalities": "text"}, "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1}}}]}' \
  '{"data": [{"id": "a", "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1, "default": true}}}, {"id": "b", "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1, "default": true}}}]}' \
  'not JSON'; do
  if printf '%s' "$bad" | infer_models_stdin >/dev/null 2>&1; then
    echo "FAILED: infer-models accepted $bad" >&2
    fail=1
  fi
done
# manage-models.sh relies on infer_model_ok to reject these before it
# appends an entry to models.local.yaml.
infer_model_ok m-1.5 "A model" sub/M.gguf ||
  { echo "FAILED: infer_model_ok rejected a valid entry" >&2; fail=1; }
infer_model_ok img "An image model" img/a.gguf img/vae.safetensors ||
  { echo "FAILED: infer_model_ok rejected a valid multi-file entry" >&2; fail=1; }
while IFS='|' read -r name desc file; do
  if infer_model_ok "$name" "$desc" "$file"; then
    echo "FAILED: infer_model_ok accepted: $name|$desc|$file" >&2
    fail=1
  fi
done <<'EOF'
a b|ok|M.gguf
m|ok|/abs/M.gguf
m|ok|../M.gguf
m|ok|a/../M.gguf
m|ok|a/..
m|ok|
m||M.gguf
m|back\slash|M.gguf
m|A "quoted" name|M.gguf
m|a ${macro}|M.gguf
EOF
if infer_model_ok m ok; then
  echo "FAILED: infer_model_ok accepted a model with no files" >&2
  fail=1
fi
if infer_model_ok m ok M.gguf ../x.gguf; then
  echo "FAILED: infer_model_ok accepted a bad second file" >&2
  fail=1
fi
if infer_model_ok m "$(printf 'two\nlines')" M.gguf; then
  echo "FAILED: infer_model_ok accepted a description with a newline" >&2
  fail=1
fi

step "release archive checks (archive_names_ok, unpacked_tree_ok)"
# install_release in host-setup.sh lists each release's archive with
# "tar tzf" and checks the names, then unpacks it and checks the tree.
if ! printf '%s\n' llama-b1/ llama-b1/libllama.dylib ./x a..b/c..d | archive_names_ok; then
  echo "FAILED: archive_names_ok refused good names" >&2
  fail=1
fi
for bad in /etc/x ../x a/../../x a/.. ..; do
  if printf '%s\n' good "$bad" | archive_names_ok 2>/dev/null; then
    echo "FAILED: archive_names_ok accepted $bad" >&2
    fail=1
  fi
done
# Tarballs: one like llama.cpp's (a directory, a file, and a version
# symlink beside it), then one per thing unpacked_tree_ok must refuse.
python3 -I - "$tmp/tars" <<'EOF'
import io, os, sys, tarfile
out = sys.argv[1]
os.mkdir(out)
def tar(name, *members):
    with tarfile.open(os.path.join(out, name + ".tar.gz"), "w:gz") as t:
        for path, kind, target in members:
            m = tarfile.TarInfo(path)
            m.type = kind
            if kind == tarfile.DIRTYPE:
                m.mode = 0o755
            elif kind == tarfile.REGTYPE:
                m.size = len(b"x")
            elif target is not None:
                m.linkname = target
            t.addfile(m, io.BytesIO(b"x") if kind == tarfile.REGTYPE else None)
good = [("r/", tarfile.DIRTYPE, None), ("r/lib.0.dylib", tarfile.REGTYPE, None),
        ("r/lib.dylib", tarfile.SYMTYPE, "lib.0.dylib")]
tar("good", *good)
tar("bad-abs-link", *good, ("r/sd-server", tarfile.SYMTYPE, "/bin/sh"))
tar("bad-up-link", *good, ("r/up", tarfile.SYMTYPE, "../outside"))
tar("bad-dotdot-link", *good, ("r/up", tarfile.SYMTYPE, ".."))
tar("bad-subdir-link", *good, ("r/s", tarfile.SYMTYPE, "sub/x"))
tar("bad-hard-link", *good, ("r/h", tarfile.LNKTYPE, "r/lib.0.dylib"))
tar("bad-fifo", *good, ("r/p", tarfile.FIFOTYPE, None))
EOF
for t in "$tmp"/tars/*.tar.gz; do
  name="$(basename "$t" .tar.gz)"
  rm -rf "${tmp:?}/unpack"
  mkdir "$tmp/unpack"
  tar xzf "$t" -C "$tmp/unpack"
  if ! tar tzf "$t" | archive_names_ok; then
    echo "FAILED: archive_names_ok refused $name's names" >&2
    fail=1
  fi
  case "$name" in
    good) unpacked_tree_ok "$tmp/unpack" ||
      { echo "FAILED: unpacked_tree_ok refused $name" >&2; fail=1; } ;;
    *) ! unpacked_tree_ok "$tmp/unpack" 2>/dev/null ||
      { echo "FAILED: unpacked_tree_ok accepted $name" >&2; fail=1; } ;;
  esac
done
# stable-diffusion.cpp's release is a zip, listed with "unzip -Z1": one
# with a ".." name, and one with a symlink out.
python3 -I - "$tmp" <<'EOF'
import os, stat, sys, zipfile
def z(name, path, data, mode):
    with zipfile.ZipFile(os.path.join(sys.argv[1], name + ".zip"), "w") as f:
        i = zipfile.ZipInfo(path)
        i.create_system = 3
        i.external_attr = mode << 16
        f.writestr(i, data)
z("up", "../x", "x", stat.S_IFREG | 0o644)
z("link", "sd-server", "/bin/sh", stat.S_IFLNK | 0o777)
EOF
if unzip -Z1 "$tmp/up.zip" | archive_names_ok 2>/dev/null; then
  echo "FAILED: archive_names_ok accepted a zip's ../x" >&2
  fail=1
fi
rm -rf "${tmp:?}/unpack"
unzip -q "$tmp/link.zip" -d "$tmp/unpack"
if unpacked_tree_ok "$tmp/unpack" 2>/dev/null; then
  echo "FAILED: unpacked_tree_ok accepted a zip's symlink to /bin/sh" >&2
  fail=1
fi

step "python unit tests (tests/)"
# tests/render_helper.py renders a template in memory and imports it as a
# real module, so these exercise the actual logic (not a reimplementation
# of it) without needing a macOS host, Keychain, or network. Add new test
# files under tests/ named test_*.py and this picks them up automatically.
if ! python3 -m unittest discover -s "$SCRIPT_DIR/tests" -v; then
  fail=1
fi

step "infer-watch.c (tests/test_infer_watch.sh)"
# Builds the sleep watcher against stand-ins for Apple's headers, with
# strict gcc warnings and -fanalyzer, then runs it under the sanitizers.
if ! shellcheck -x tests/test_infer_watch.sh || ! tests/test_infer_watch.sh; then
  fail=1
fi

step "manage-models.sh (tests/test_manage_models.sh)"
# Starts and migrates a list, adds and removes a generalist and a
# specialist, and updates, syncs, and prunes, on a copy of the repo with
# a stand-in for Hugging Face; and checks that bad requests change
# nothing.
if ! shellcheck -x tests/test_manage_models.sh || ! tests/test_manage_models.sh; then
  fail=1
fi

step "tests/sleep-test.sh runs"
# It only runs on the Mac, so run both phases here with stand-ins for
# the Mac's commands. This catches mistakes that static checks can't
# see, such as a variable config.sh needs that's never set.
# (The shell ignores set -e in a subshell followed by ||, so each step
# here checks for failure itself.)
(
  mkdir -p "$tmp/sleep/bin" "$tmp/sleep/home/.config/bulkhead" \
    "$tmp/sleep/home/Library/Logs" || exit 1
  for cmd in launchctl pmset curl ioreg; do
    printf '#!/bin/sh\necho "fake %s $*"\n' "$cmd" > "$tmp/sleep/bin/$cmd" &&
      chmod +x "$tmp/sleep/bin/$cmd" || exit 1
  done
  # Except that the engine lists one default model.
  printf '#!/bin/sh\ncase "$*" in\n  */v1/models) echo %s ;;\n  *) echo "fake curl $*" ;;\nesac\n' \
    "'{\"data\": [{\"id\": \"m\", \"meta\": {\"llamaswap\": {\"default\": true}}}]}'" \
    > "$tmp/sleep/bin/curl" || exit 1
  echo sk-test > "$tmp/sleep/home/.config/bulkhead/infer-api-key" || exit 1
  echo "x infer-watch: watching for sleep, wake, and power changes" \
    > "$tmp/sleep/home/Library/Logs/infer-watch.log" || exit 1
  for phase in before after; do
    if ! HOME="$tmp/sleep/home" PATH="$tmp/sleep/bin:$PATH" \
        SLEEP_TEST_OUT="$tmp/sleep/out" tests/sleep-test.sh "$phase" \
        > "$tmp/sleep/stdout" 2>&1; then
      cat "$tmp/sleep/stdout" >&2
      echo "FAILED: tests/sleep-test.sh $phase" >&2
      exit 1
    fi
  done
  if grep -E 'unbound variable|parameter not set|not found|WARNING' "$tmp/sleep/out" >&2 ||
      [ "$(grep -c '^===== ' "$tmp/sleep/out")" != 2 ]; then
    echo "FAILED: tests/sleep-test.sh's output (above, if any)" >&2
    exit 1
  fi
) || fail=1

step "jq revoke-filter logic (rotate-heroku-key.sh's auto-revoke query)"
# This is the trickiest logic in the repo, and it had a real bug once
# (matching by description instead of created_at silently revoked
# nothing on any routine same-VM rotation, since the old and new
# authorizations share an identical description). This fixture
# reproduces exactly that: two entries with the same description, one
# older, plus an unrelated third entry that must never be touched.
cat > "$tmp/fake_authorizations.json" <<'EOF'
[
  {"id": "OLD-1111-1111-1111-111111111111", "description": "bulkhead: lftux", "created_at": "2026-01-15T10:00:00-00:00"},
  {"id": "NEW-2222-2222-2222-222222222222", "description": "bulkhead: lftux", "created_at": "2026-08-28T14:30:00-00:00"},
  {"id": "OTHER-333-333-333-333333333333", "description": "Heroku Dashboard", "created_at": "2026-08-28T14:31:00-00:00"}
]
EOF
result="$(jq -r '
  [.[] | select(.description | startswith("bulkhead"))] |
  sort_by(.created_at) | reverse | .[1:] | .[] | .id
' "$tmp/fake_authorizations.json")"
if [ "$result" != "OLD-1111-1111-1111-111111111111" ]; then
  echo "FAILED: expected only the old entry's ID, got:" >&2
  echo "$result" >&2
  fail=1
fi

step "commit-msg git hook"
# Builds the hooks directory vm-setup.sh installs, in a scratch repo
# with its own global config, and checks that the hook rejects a bad
# message, accepts a good one, ignores a "git commit -v" diff, and still
# runs the repository's own hooks.
(
  set -e
  mkdir -p "$tmp/bin" "$tmp/hooks"
  ln -s "$SCRIPT_DIR/check-prose-style.sh" "$tmp/bin/check-prose-style"
  cp git-commit-msg "$tmp/hooks/commit-msg"
  cp git-hook-passthrough "$tmp/hooks/passthrough"
  ln -s passthrough "$tmp/hooks/pre-commit"
  PATH="$tmp/bin:$PATH"
  GIT_CONFIG_GLOBAL="$tmp/gitconfig"
  GIT_CONFIG_NOSYSTEM=1
  export PATH GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
  git config --global user.name Test
  git config --global user.email test@example.com
  git config --global core.hooksPath "$tmp/hooks"
  # git_config_set leaves ~/.gitconfig alone (same inode) unless a value
  # changes.
  before="$(ls -i "$GIT_CONFIG_GLOBAL")"
  git_config_set user.name Test
  [ "$(ls -i "$GIT_CONFIG_GLOBAL")" = "$before" ] ||
    { echo "FAILED: git_config_set rewrote an unchanged ~/.gitconfig" >&2; exit 1; }
  git_config_set init.defaultbranch main
  [ "$(git config --global --get init.defaultbranch)" = main ] ||
    { echo "FAILED: git_config_set didn't set a new value" >&2; exit 1; }
  git init -q "$tmp/repo"
  cd "$tmp/repo"
  echo a > f
  git add f
  if git commit -q -m 'We leverage this.' 2>/dev/null; then
    echo "FAILED: commit-msg accepted a banned phrase" >&2
    exit 1
  fi
  git commit -q -m 'Add f.'
  printf '#!/bin/sh\ntouch ran-pre-commit\n' > .git/hooks/pre-commit
  printf '#!/bin/sh\ntouch ran-commit-msg\n' > .git/hooks/commit-msg
  chmod +x .git/hooks/pre-commit .git/hooks/commit-msg
  echo 'We leverage this.' >> f
  git add f
  GIT_EDITOR='sed -i 1s/^/Change.f./' git commit -q -v
  if [ ! -e ran-pre-commit ] || [ ! -e ran-commit-msg ]; then
    echo "FAILED: the repository's own hooks didn't run" >&2
    exit 1
  fi
) || fail=1

step "check-prose-style.sh self-test"
# Runs sample hook inputs through check-prose-style.sh and checks that
# each is allowed or denied as expected (see test-check-prose-style.sh).
if ! bash -n test-check-prose-style.sh; then
  echo "FAILED: test-check-prose-style.sh (bash -n)" >&2
  fail=1
fi
if ! shellcheck -x test-check-prose-style.sh; then
  fail=1
fi
if ! ./test-check-prose-style.sh; then
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "All checks passed."
else
  echo "One or more checks FAILED (see above)." >&2
  exit 1
fi
