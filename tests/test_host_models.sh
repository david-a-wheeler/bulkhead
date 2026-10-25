#!/bin/sh
# test_host_models.sh: check host-models.sh and the programs it uses: that
# initial-models.yaml follows the list's rules, and llama-swap's config
# from it has what pi and nopi need; that infer_models_ok refuses each
# kind of bad entry; that render_engine_config (host-install.sh) wants
# every file a list names; and that infer-models and pi-models.jq handle
# llama-swap's real listing, and infer-models refuses bad ones. Run by
# ci.sh.
# shellcheck disable=SC2016 # entries hold literal ${llama-server} etc.
set -eu

TESTS="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$TESTS/.." && pwd)"
cd "$SCRIPT_DIR"
mkdir -p .tmp
tmp="$(mktemp -d "$SCRIPT_DIR/.tmp/test-host-models.XXXXXX")"
trap 'rm -rf "${tmp:?}"' EXIT
. ./config.sh
. ./common.sh
. ./host-models.sh

fail=0
failed() {
  echo "FAILED: $1" >&2
  fail=1
}
# refuses_list WHAT: infer_models_ok must refuse the list on stdin, WHAT.
refuses_list() {
  cat > "$tmp/bad-models.yaml"
  if infer_models_ok "$tmp/bad-models.yaml" 2>/dev/null; then
    failed "infer_models_ok accepted $1:"
    cat "$tmp/bad-models.yaml" >&2
  fi
}
# infer-models, with its filter from the repo, not where vm-setup.sh
# installs it.
render_template infer-models.template.sh "$tmp/infer-models.installed" INFER_PORT
sed "s|^FILTER=.*|FILTER=\"$SCRIPT_DIR/infer-models.jq\"|" "$tmp/infer-models.installed" > "$tmp/infer-models"

infer_models_ok initial-models.yaml || failed "initial-models.yaml breaks its own rules"
# llama-swap isn't here to check the config, so check what pi and nopi
# need from it (tests/check_llama_swap_config.py).
infer_llama_swap_yaml sk-test /llama-server 8999 /sd-server 8998 initial-models.yaml \
  > "$tmp/llama-swap.yaml"
python3 -I tests/check_llama_swap_config.py "$tmp/llama-swap.yaml" ||
  failed "the models in initial-models.yaml (above)"
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
  printf 'models:\n%s\n%s\n' "$good" "$bad" | with_files | refuses_list "a bad entry"
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
  failed "infer_models_ok rejected a good entry"
got="$(infer_model_roles "$tmp/good-models.yaml" | tr '\n' ' ')"
[ "$got" = "m generalist m-img specialist m-vision generalist " ] ||
  failed "infer_model_roles gave '$got'"
[ -z "$(infer_models_default "$tmp/good-models.yaml")" ] ||
  failed "infer_models_default found a default where there's none"
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
    B="    # file: $bad" awk '/^    # file:/ { $0 = ENVIRON["B"] } { print }' |
    refuses_list "a bad file line"
done
printf 'models:\n%s\n' "$good" | with_files > "$tmp/m.yaml"
for bad in "$(printf '%s\n  n:\n    # file: m.gguf %064d mit https://example.com/m.gguf\n    cmd: ${llama-server} --model ${models-dir}/m.gguf\n    proxy: ${proxy}' "$(sed 1d "$tmp/m.yaml")" 0)" \
  "$(printf '%s\n    # file: x.gguf %064d mit https://example.com/x.gguf' "$(sed 1d "$tmp/m.yaml")" 0)" \
  "$(printf '%s\n' "$good")" \
  "$(printf '    # file: m.gguf %064d mit https://example.com/m.gguf\n%s' 0 "$(sed 1d "$tmp/m.yaml")")"; do
  printf 'models:\n%s\n' "$bad" | refuses_list "files that don't match"
done
# The same file in two models, listed the same way, is fine.
printf '%s\n  n:\n%s\n    cmd: ${llama-server} --model ${models-dir}/m.gguf\n    proxy: ${proxy}\n' \
  "$(cat "$tmp/m.yaml")" "$(grep '# file:' "$tmp/m.yaml")" > "$tmp/shared.yaml"
infer_models_ok "$tmp/shared.yaml" ||
  failed "infer_models_ok rejected a file two models share"
[ "$(infer_model_files "$tmp/shared.yaml" | wc -l)" -eq 1 ] ||
  failed "infer_model_files listed a shared file twice"
# A .jinja chat template a model's cmd uses, listed as "# generated:"
# (this host writes it; nothing downloads it): refuse a cmd that uses
# one without the line, a line naming a non-.jinja file or a path
# outside MODELS_DIR, a line with more than a path, a line outside a
# model, and a line the cmd never uses; accept the good one.
gen_good='  g:
    cmd: ${llama-server} --model ${models-dir}/g.gguf --jinja --chat-template ${models-dir}/g.chat-template.jinja --ctx-size 4096
    proxy: ${proxy}'
printf 'models:\n%s\n' "$gen_good" | with_files > "$tmp/g.gen.yaml"
infer_models_ok "$tmp/g.gen.yaml" ||
  failed "infer_models_ok rejected a good # generated: entry"
for bad in "$(grep -v '# generated:' "$tmp/g.gen.yaml")" \
  "$(sed 's|# generated: g.chat-template.jinja|# generated: g.gguf|' "$tmp/g.gen.yaml")" \
  "$(sed 's|# generated: g.chat-template.jinja|# generated: ../g.chat-template.jinja|' "$tmp/g.gen.yaml")" \
  "$(sed 's|# generated: g.chat-template.jinja|# generated: g.chat-template.jinja x|' "$tmp/g.gen.yaml")" \
  "$(awk 'NR == 1 { print; print "    # generated: g.chat-template.jinja"; next } 1' "$tmp/g.gen.yaml")" \
  "$(sed 's|--chat-template ${models-dir}/g.chat-template.jinja ||' "$tmp/g.gen.yaml")"; do
  printf '%s\n' "$bad" | refuses_list "a bad # generated: entry"
done
infer_llama_swap_yaml sk-test /llama-server 8999 /sd-server 8998 "$tmp/good-models.yaml" > "$tmp/both.yaml"
got="$(python3 -I -c 'import sys, yaml; print(" ".join(yaml.safe_load(open(sys.argv[1]))["models"]))' "$tmp/both.yaml")"
[ "$got" = "m m-img m-vision" ] || failed "the config for a list has models '$got', not 'm m-img m-vision'"
# render_engine_config (host-install.sh), which host-setup.sh and
# install-models.sh use: it refuses a list whose files aren't in
# MODELS_DIR (by SHA256SUMS), and renders one whose files are.
(
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
) || failed "render_engine_config (above)"
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
[ "$got" = "$want" ] || failed "infer-models gave $got, not $want"
got="$(printf '%s' "$listing" | infer_models_stdin | jq -f pi-models.jq |
  jq -c '[.providers["mac-local"].models[] | [.id, .name, .contextWindow, .maxTokens, .input]]')"
want='[["qwen3.8-27b:instruct","Qwen3.8-27B Q8_0 (qwen3.8-27b:instruct)",262144,16384,["text","image"]],["qwen3-0.6b","Qwen3-0.6B Q4_0 (tests)",32768,4096,["text"]],["qwen3.8-27b","Qwen3.8-27B Q8_0",262144,16384,["text","image"]]]'
[ "$got" = "$want" ] || failed "pi-models.jq gave $got, not $want"
got="$(printf '%s' "$listing" | infer_models_stdin | jq -f pi-models.jq | jq -c '.providers["mac-local"] |
  [.baseUrl, .apiKey, .compat.thinkingTokenBudgetField, ([.models[].thinkingLevelMap.off] | unique)]')"
want='["http://127.0.0.1:'"$INFER_PORT"'/v1","${INFER_API_KEY}","thinking_budget_tokens",["none"]]'
[ "$got" = "$want" ] || failed "pi-models.jq's provider settings are $got, not $want"
got="$(printf '%s' '{"data": [{"id": "a", "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1}}}]}' |
  infer_models_stdin | jq -c .default)"
[ "$got" = null ] || failed "infer-models gave a default ($got) for a listing with none"
for bad in '{"data": [{"id": "a b", "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1}}}]}' \
  '{"data": [{"id": "a", "context_length": 1}]}' \
  '{"data": [{"id": "a", "context_length": "1", "meta": {"llamaswap": {"max_tokens": 1}}}]}' \
  '{"data": [{"id": "a", "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1, "type": "alias", "modelID": "b c"}}}]}' \
  '{"data": [{"id": "a", "architecture": {"input_modalities": "text"}, "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1}}}]}' \
  '{"data": [{"id": "a", "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1, "default": true}}}, {"id": "b", "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1, "default": true}}}]}' \
  'not JSON'; do
  printf '%s' "$bad" | infer_models_stdin >/dev/null 2>&1 && failed "infer-models accepted $bad"
done
# manage-models.sh relies on infer_model_ok to reject these before it
# appends an entry to models.local.yaml.
infer_model_ok m-1.5 "A model" sub/M.gguf ||
  failed "infer_model_ok rejected a valid entry"
infer_model_ok img "An image model" img/a.gguf img/vae.safetensors ||
  failed "infer_model_ok rejected a valid multi-file entry"
while IFS='|' read -r name desc file; do
  infer_model_ok "$name" "$desc" "$file" && failed "infer_model_ok accepted: $name|$desc|$file"
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
infer_model_ok m ok && failed "infer_model_ok accepted a model with no files"
infer_model_ok m ok M.gguf ../x.gguf && failed "infer_model_ok accepted a bad second file"
infer_model_ok m "$(printf 'two\nlines')" M.gguf && failed "infer_model_ok accepted a description with a newline"

[ "$fail" -eq 0 ] && echo "host models: all checks passed."
exit "$fail"
