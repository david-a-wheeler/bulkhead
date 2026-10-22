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
trap 'rm -rf "$tmp"' EXIT

fail=0
step() {
  echo
  echo "== $1 =="
}

# Plain scripts: no @@VAR@@ templating, safe to check as-is.
PLAIN_SCRIPTS="config.sh common.sh host-backend.sh host-models.sh host-setup.sh infer-check.sh add-model.sh vm-setup.sh host-secrets.sh infer-access.sh rotate-github-pat.sh rotate-heroku-key.sh anon-access heroku-session gh-session vm-git-helper noclaude check-prose-style.sh git-commit-msg git-hook-passthrough tests/sleep-test.sh"

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
for f in secrets-client secrets-server.py; do
  if ! python3 -m py_compile "$tmp/$f"; then
    echo "FAILED: $f (py_compile)" >&2
    fail=1
  fi
done

INFER_DEFAULT_MODEL=qwen3.8-27b
render_template nopi.template.sh "$tmp/nopi" INFER_DEFAULT_MODEL
render_template infer-logs.template.sh "$tmp/infer-logs" INFER_PORT
render_template infer-watch-hook.template.sh "$tmp/infer-watch-hook" \
  INFER_PORT INFER_KEY_FILE INFER_LABEL INFER_LOW_POWER_BELOW INFER_LOW_POWER_UNTIL
for f in nopi infer-logs infer-watch-hook; do
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

step "local AI models (infer-models.yaml)"
. "$SCRIPT_DIR/host-models.sh"
if ! infer_models_ok infer-models.yaml; then
  echo "FAILED: infer-models.yaml breaks its own rules" >&2
  fail=1
fi
# Each file a model's cmd names is one MODEL_DOWNLOADS puts there.
printf '%s\n' "$MODEL_DOWNLOADS" | while read -r url _ _ subdir; do
  model_file "$url" "$subdir"
done > "$tmp/downloaded"
missing="$(grep -o '\${models-dir}/[^ ]*' infer-models.yaml |
  sed 's/^\${models-dir}\///' | grep -vxF -f "$tmp/downloaded")" || true
if [ -n "$missing" ]; then
  echo "FAILED: infer-models.yaml uses files MODEL_DOWNLOADS doesn't download:" >&2
  printf '%s\n' "$missing" >&2
  fail=1
fi
# llama-swap isn't here to check the config, so check what pi and nopi
# need from it: each model's context matches its --ctx-size, max_tokens
# fits in it, and exactly one model is the default.
infer_llama_swap_yaml sk-test /llama-server 8999 /sd-server 8998 infer-models.yaml > "$tmp/llama-swap.yaml"
if ! python3 -I - "$tmp/llama-swap.yaml" <<'EOF'
import re, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
assert cfg["apiKeys"] == ["sk-test"], "the API key isn't ours alone"
assert cfg["captureBuffer"] == 0, "llama-swap must not keep prompts and replies"
assert cfg["globalTTL"] == 86400, "llama-swap should keep an idle model loaded for a day"
defaults = []
for name, m in cfg["models"].items():
    ctx = (m.get("capabilities") or {}).get("context")
    max_tokens = (m.get("metadata") or {}).get("max_tokens")
    if m["cmd"].startswith("${sd-server} "):
        assert m["capabilities"]["out"] == ["image"], f"{name}: needs capabilities.out: [image]"
        assert m["proxy"] == "${specialist-proxy}", f"{name}: a specialist needs its own port"
        assert 0 < m["ttl"] <= 3600, f"{name}: a specialist must unload within an hour"
        continue
    assert m["proxy"] == "${proxy}", f"{name}: a generalist needs the generalist port"
    assert "ttl" not in m, f"{name}: a generalist should stay loaded (globalTTL)"
    size = re.search(r"--ctx-size (\d+)", m["cmd"])
    assert isinstance(ctx, int) and size and int(size.group(1)) == ctx, \
        f"{name}: capabilities.context must match --ctx-size"
    assert isinstance(max_tokens, int) and 0 < max_tokens <= ctx, \
        f"{name}: metadata.max_tokens must be a number up to the context"
    if (m.get("metadata") or {}).get("default") is True:
        defaults.append(name)
assert len(defaults) == 1, f"exactly one model needs metadata.default: true, not {defaults}"
# One group per role, which swaps within itself and leaves the other
# alone, and every model in one; otherwise llama-swap's default group
# would evict both.
groups = cfg["routing"]["router"]["settings"]["groups"]
assert cfg["routing"]["router"]["use"] == "group" and set(groups) == {"generalists", "specialists"}
for g in groups.values():
    assert g["swap"] is True and g["exclusive"] is False, "each role must swap only within itself"
roles = {n: "specialists" if m["cmd"].startswith("${sd-server} ") else "generalists"
         for n, m in cfg["models"].items()}
for gname, g in groups.items():
    assert sorted(g["members"] or []) == sorted(n for n, r in roles.items() if r == gname), \
        f"{gname}: members {g['members']} don't match the models' roles"
macros = cfg["macros"]
assert "--port 8999 " in macros["llama-server"] and macros["proxy"] == "http://127.0.0.1:8999"
assert macros["sd-server"].endswith("--listen-port 8998") and macros["specialist-proxy"] == "http://127.0.0.1:8998"
EOF
then
  echo "FAILED: the models in infer-models.yaml (above)" >&2
  fail=1
fi
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
    proxy: ${proxy}'; do
  printf 'models:\n%s\n%s\n' "$good" "$bad" > "$tmp/bad-models.yaml"
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
printf 'models:\n%s\n%s\n' "$good" "$good_sd" > "$tmp/good-models.yaml"
infer_models_ok "$tmp/good-models.yaml" ||
  { echo "FAILED: infer_models_ok rejected a good entry" >&2; fail=1; }
got="$(infer_model_roles "$tmp/good-models.yaml" | tr '\n' ' ')"
[ "$got" = "m generalist m-img specialist m-vision generalist " ] ||
  { echo "FAILED: infer_model_roles gave '$got'" >&2; fail=1; }
# infer-models.local.yaml adds to infer-models.yaml, without reusing its
# names, and the combined config has both files' models.
infer_models_ok infer-models.yaml "$tmp/good-models.yaml" ||
  { echo "FAILED: infer_models_ok rejected a good local file" >&2; fail=1; }
if infer_models_ok infer-models.yaml infer-models.yaml 2>/dev/null; then
  echo "FAILED: infer_models_ok accepted a model defined twice" >&2
  fail=1
fi
infer_llama_swap_yaml sk-test /llama-server 8999 /sd-server 8998 infer-models.yaml "$tmp/good-models.yaml" > "$tmp/both.yaml"
got="$(python3 -I -c 'import sys, yaml; print(" ".join(yaml.safe_load(open(sys.argv[1]))["models"]))' "$tmp/both.yaml")"
want="$(sed -n 's/^  \([^ #][^:]*\):$/\1/p' infer-models.yaml | tr '\n' ' ')m m-img m-vision"
if [ "$got" != "$want" ]; then
  echo "FAILED: combining infer-models.yaml with a local file gave models '$got', not '$want'" >&2
  fail=1
fi
# pi's models.json and nopi's default, from llama-swap v265's real
# listing for infer-models.yaml (trimmed to the fields we use). A
# variant (type "alias") repeats its model's metadata, and comes first
# here, so picking it as the default would show. The image model, added
# as llama-swap's api.go would list it, must not reach pi.
listing='{"data": [{"id": "flux2-klein-4b", "name": "FLUX.2-klein 4B Q8_0 (images)", "architecture": {"input_modalities": ["text"], "output_modalities": ["image"], "modality": "text->image"}, "meta": {"llamaswap": {"type": "model"}}}, {"id": "qwen3.8-27b:instruct", "name": "Qwen3.8-27B Q8_0", "context_length": 262144, "meta": {"llamaswap": {"default": true, "max_tokens": 16384, "modelID": "qwen3.8-27b", "type": "alias"}, "n_ctx": 262144}}, {"id": "qwen3-0.6b", "name": "Qwen3-0.6B Q4_0 (tests)", "context_length": 32768, "meta": {"llamaswap": {"max_tokens": 4096, "type": "model"}, "n_ctx": 32768}}, {"id": "qwen3.8-27b", "name": "Qwen3.8-27B Q8_0", "context_length": 262144, "meta": {"llamaswap": {"aliases": ["qwen3.8-27b:instruct"], "default": true, "max_tokens": 16384, "type": "model"}, "n_ctx": 262144}}]}'
got="$(printf '%s' "$listing" | infer_pi_models_json |
  jq -c '[.providers["mac-local"].models[] | [.id, .name, .contextWindow, .maxTokens]]')"
want='[["qwen3.8-27b:instruct","Qwen3.8-27B Q8_0 (qwen3.8-27b:instruct)",262144,16384],["qwen3-0.6b","Qwen3-0.6B Q4_0 (tests)",32768,4096],["qwen3.8-27b","Qwen3.8-27B Q8_0",262144,16384]]'
if [ "$got" != "$want" ]; then
  echo "FAILED: infer_pi_models_json gave $got, not $want" >&2
  fail=1
fi
got="$(printf '%s' "$listing" | infer_pi_models_json | jq -c '.providers["mac-local"] |
  [.compat.thinkingTokenBudgetField, ([.models[].thinkingLevelMap.off] | unique)]')"
want='["thinking_budget_tokens",["none"]]'
if [ "$got" != "$want" ]; then
  echo "FAILED: infer_pi_models_json's thinking settings are $got, not $want" >&2
  fail=1
fi
got="$(printf '%s' "$listing" | infer_default_model)"
[ "$got" = qwen3.8-27b ] ||
  { echo "FAILED: infer_default_model gave '$got', not qwen3.8-27b" >&2; fail=1; }
for bad in '{"data": [{"id": "a b", "context_length": 1, "meta": {"llamaswap": {"max_tokens": 1}}}]}' \
  '{"data": [{"id": "a", "context_length": 1}]}'; do
  if printf '%s' "$bad" | infer_pi_models_json >/dev/null 2>&1; then
    echo "FAILED: infer_pi_models_json accepted $bad" >&2
    fail=1
  fi
done
# add-model.sh relies on infer_model_ok to reject these before it
# appends an entry to infer-models.local.yaml.
infer_model_ok m-1.5 sub/M.gguf 4096 512 "A model" ||
  { echo "FAILED: infer_model_ok rejected a valid entry" >&2; fail=1; }
while IFS='|' read -r name file ctx max desc; do
  if infer_model_ok "$name" "$file" "$ctx" "$max" "$desc"; then
    echo "FAILED: infer_model_ok accepted: $name|$file|$ctx|$max|$desc" >&2
    fail=1
  fi
done <<'EOF'
a b|M.gguf|4096|512|ok
m|/abs/M.gguf|4096|512|ok
m|../M.gguf|4096|512|ok
m|a/../M.gguf|4096|512|ok
m|M.gguf||512|ok
m|M.gguf|4096|5x|ok
m|M.gguf|4096|512|
m|M.gguf|4096|512|back\slash
m|M.gguf|4096|512|A "quoted" name
m|M.gguf|4096|512|a ${macro}
EOF
if infer_model_ok m M.gguf 4096 512 "$(printf 'two\nlines')"; then
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
  rm -rf "$tmp/unpack"
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
rm -rf "$tmp/unpack"
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
