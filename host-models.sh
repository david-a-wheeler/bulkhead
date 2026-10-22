# shellcheck shell=sh
# host-models.sh: downloading local AI models into MODELS_DIR, and the
# list of models the engine serves (infer-models.yaml). Shared by
# host-setup.sh and add-model.sh, so the checks that keep a bad file out
# of MODELS_DIR, and a bad entry out of llama-swap's config, exist only
# once.
#
# Nothing here is macOS-specific except keeping MODELS_DIR out of Time
# Machine, which it skips elsewhere. Source this after
# config.sh/common.sh (it needs SCRIPT_DIR, the repo's top directory):
#   . "$(dirname "$0")/host-models.sh"

SOURCES_HEADER="$(printf 'file\tsource_url\tlicense\tadded\tcommit')"

# Usage: prepare_models_dir
# Creates MODELS_DIR (readable by everyone, so by MACOS_INFER_USER, but
# writable only by you), keeps it out of Time Machine on macOS, and
# starts SOURCES.tsv, or adds the commit column to an older one.
prepare_models_dir() {
  mkdir -p "$MODELS_DIR"
  chmod 755 "$MODELS_DIR"
  if command -v tmutil >/dev/null 2>&1; then
    tmutil addexclusion "$MODELS_DIR"
  fi
  if [ ! -f "$MODELS_DIR/SOURCES.tsv" ]; then
    printf '%s\n' "$SOURCES_HEADER" > "$MODELS_DIR/SOURCES.tsv"
  elif [ "$(head -n 1 "$MODELS_DIR/SOURCES.tsv")" = "$(printf 'file\tsource_url\tlicense\tadded')" ]; then
    { printf '%s\n' "$SOURCES_HEADER"; tail -n +2 "$MODELS_DIR/SOURCES.tsv"; } > "$MODELS_DIR/SOURCES.tsv.new"
    mv "$MODELS_DIR/SOURCES.tsv.new" "$MODELS_DIR/SOURCES.tsv"
  fi
}

# Usage: model_file <url> [<subdir>]
# Prints the model's path relative to MODELS_DIR: the URL's last part,
# without any query (e.g., "?download=true"). A multi-file model (e.g.,
# an image model) names a subdirectory.
model_file() {
  printf '%s\n' "${2:+$2/}$(basename "${1%%\?*}")"
}

# Usage: download_model <url> <sha256> <license> [<subdir>]
# Downloads one model file into MODELS_DIR unless it's already there.
download_model() {
  [ -f "$MODELS_DIR/$(model_file "$1" "${4:-}")" ] ||
    fetch_model "$1" "$2" "$3" "${4:-}"
}

# Usage: fetch_model <url> <sha256> <license> [<subdir>]
# Downloads one model file into MODELS_DIR, replacing any older copy only
# once the new one passes every check. It goes to FILE.partial first
# (rerunning resumes it), so an unfinished or wrong download never looks
# like a model. A checksum mismatch removes it and stops. Files are
# read-only; SHA256SUMS and SOURCES.tsv record each one's checksum,
# source, and (from Hugging Face) the repository's commit when downloaded.
#
# Only formats that can't run code when loaded are allowed: GGUF and
# safetensors, both just a header plus raw numbers. Pickle-based formats
# (PyTorch's .bin, .pt, .pth, and .ckpt, and plain .pkl) can run
# arbitrary code when loaded, so a URL with one of those extensions is
# refused before downloading, and every download's first bytes must show
# GGUF (the bytes "GGUF") or safetensors (an 8-byte header length, then
# the JSON header's "{"); anything else is removed and stops the script.
fetch_model() {
  fm_file="$(model_file "$1" "${4:-}")"
  case "$fm_file" in
    *.bin | *.pt | *.pth | *.ckpt | *.pkl | *.pickle)
      die "$fm_file is a pickle-based format, which can run code when loaded; refusing to download it."
      ;;
  esac
  if [ -n "${4:-}" ]; then
    mkdir -p "$MODELS_DIR/$4"
    chmod 755 "$MODELS_DIR/$4"
  fi
  echo "Downloading $fm_file"
  curl -fL -C - -D "$MODELS_DIR/$fm_file.headers" -o "$MODELS_DIR/$fm_file.partial" "$1"
  # Hugging Face names the commit it served; keep it only if it looks
  # like one.
  fm_commit="$(tr -d '\r' < "$MODELS_DIR/$fm_file.headers" |
    sed -n 's/^[Xx]-[Rr]epo-[Cc]ommit: *\([0-9a-f]\{40\}\)$/\1/p' | tail -n 1)"
  rm -f "$MODELS_DIR/$fm_file.headers"
  if [ "$(shasum -a 256 "$MODELS_DIR/$fm_file.partial" | cut -d ' ' -f 1)" != "$2" ]; then
    rm -f "$MODELS_DIR/$fm_file.partial"
    die "$fm_file doesn't match its SHA-256; removed it."
  fi
  # The first 9 bytes as hex: 18 digits.
  case "$(head -c 9 "$MODELS_DIR/$fm_file.partial" | od -An -tx1 | tr -d ' \n')" in
    47475546*) ;;          # GGUF
    ????????????????7b) ;; # safetensors
    *)
      rm -f "$MODELS_DIR/$fm_file.partial"
      die "$fm_file is neither GGUF nor safetensors; removed it."
      ;;
  esac
  chmod 444 "$MODELS_DIR/$fm_file.partial"
  mv -f "$MODELS_DIR/$fm_file.partial" "$MODELS_DIR/$fm_file"
  remove_model_records "$fm_file"
  printf '%s  %s\n' "$2" "$fm_file" >> "$MODELS_DIR/SHA256SUMS"
  printf '%s\t%s\t%s\t%s\t%s\n' "$fm_file" "$1" "$3" "$(date +%Y-%m-%d)" "$fm_commit" >> "$MODELS_DIR/SOURCES.tsv"
}

# Usage: remove_model_records FILE
# Removes the lines for FILE (relative to MODELS_DIR) from SHA256SUMS and
# SOURCES.tsv. File names have no spaces or tabs.
remove_model_records() {
  touch "$MODELS_DIR/SHA256SUMS"
  awk -v f="$1" '$2 != f' "$MODELS_DIR/SHA256SUMS" > "$MODELS_DIR/SHA256SUMS.new"
  mv "$MODELS_DIR/SHA256SUMS.new" "$MODELS_DIR/SHA256SUMS"
  if [ -f "$MODELS_DIR/SOURCES.tsv" ]; then
    awk -F '\t' -v f="$1" '$1 != f' "$MODELS_DIR/SOURCES.tsv" > "$MODELS_DIR/SOURCES.tsv.new"
    mv "$MODELS_DIR/SOURCES.tsv.new" "$MODELS_DIR/SOURCES.tsv"
  fi
}

# Usage: with_infer_models COMMAND [ARG...]
# Runs COMMAND ARG... followed by the files listing the models the
# engine serves: the repo's infer-models.yaml, then your
# infer-models.local.yaml (the models you've added) if it exists.
with_infer_models() {
  if [ -f "$SCRIPT_DIR/infer-models.local.yaml" ]; then
    "$@" "$SCRIPT_DIR/infer-models.yaml" "$SCRIPT_DIR/infer-models.local.yaml"
  else
    "$@" "$SCRIPT_DIR/infer-models.yaml"
  fi
}

# Usage: infer_models_ok FILE...
# Checks the rules in infer-models.yaml's opening comment that keep each
# model behind the flags in ${llama-server}: each FILE has only a
# "models:" section; each model's name is alone on its line, indented
# two spaces, and no other FILE uses it; and each model has exactly one
# cmd and one proxy, indented four spaces, where the cmd starts with
# ${llama-server} and doesn't change --host, --port, --cors-origins, or
# --api-key, and the proxy is ${proxy}. Being this strict about layout
# means YAML's other ways of writing a cmd (e.g., a flow mapping like
# "{cmd: ...}") can't slip past it. Reports each problem and fails if
# there's any. llama-swap checks the rest when host-setup.sh validates
# the config.
infer_models_ok() {
  awk '
    function bad(msg) {
      printf "%s:%d: %s\n", FILENAME, FNR, msg > "/dev/stderr"
      failed = 1
    }
    # Checks the model that just ended, if any.
    function end_model() {
      if (model != "" && (cmds != 1 || proxies != 1)) {
        printf "%s: %s needs exactly one cmd and one proxy, each indented four spaces\n", where, model > "/dev/stderr"
        failed = 1
      }
      model = ""
      cmds = proxies = 0
    }
    FNR == 1 { end_model(); started = 0 }
    /^[ \t]*(#|$)/ { next }
    /\t/ { bad("has a tab; indent with spaces"); next }
    /^[^ ]/ {
      if ($0 == "models:" && !started) started = 1
      else bad("only \"models:\" may start at the left margin, once")
      next
    }
    !started { bad("must come after \"models:\""); next }
    /^  [^ ]/ {
      end_model()
      if ($0 !~ /^  ("[A-Za-z0-9._:-]+"|[A-Za-z0-9._-]+):$/) {
        bad("a model name must be alone on its line and use only letters, digits, \".\", \"_\", and \"-\"")
        next
      }
      model = $0
      gsub(/^  "?|"?:$/, "", model)
      where = FILENAME ":" FNR
      if (model in seen) bad(model " is already defined, at " seen[model])
      else seen[model] = where
      models++
      next
    }
    /^( |   )[^ ]/ { bad("indent by two spaces per level"); next }
    model == "" { bad("must be inside a model"); next }
    /^    cmd:/ {
      cmds++
      if ($0 !~ /^    cmd: \$\{llama-server\} /) bad("cmd must start with ${llama-server}")
      else if ($0 ~ /--(host|port|cors-origins|api-key)([ =]|$)/)
        bad("cmd must not set --host, --port, --cors-origins, or --api-key")
    }
    /^    proxy:/ {
      proxies++
      if ($0 !~ /^    proxy: "?\$\{proxy\}"?$/) bad("proxy must be ${proxy}")
    }
    END {
      end_model()
      if (models == 0) bad("lists no models")
      exit failed
    }' "$@"
}

# Usage: infer_llama_swap_yaml <api-key> <llama-server-path> <backend-port> <models-file>...
# Prints llama-swap's config: our settings, then the models in each
# <models-file> (see infer-models.yaml), as one "models:" section. The macros hold the flags every model needs. Every
# model uses the same fixed backend port, since llama-swap runs only one
# at a time and the sandbox allows connecting to just that port. The
# backend has no API key of its own, so --cors-origins names an origin no
# web page can have (.invalid is reserved): otherwise any page open in a
# browser on the Mac could query it directly and read the replies.
# --cache-ram 0 turns off the prompt cache (by default 8192 MiB), which
# keeps earlier prompts' KV state in ordinary, swappable memory. With one
# agent it barely helps, since the slot's own KV cache is reused as each
# turn extends the last. We may raise it later (or use more slots) to
# speed up several agents taking turns, since each switch otherwise
# reprocesses the whole context. captureBuffer 0 turns off llama-swap's
# captures (by default 5 MB of recent requests and replies, i.e., prompts
# and answers, for its web UI's Activity view). They'd be in llama-swap's
# ordinary, swappable memory, and would outlive unloading the model, so
# they'd reach the sleep image; turn them on only while debugging.
# performance is disabled because otherwise llama-swap runs ioreg every 5
# seconds for GPU statistics we don't use, and the sandbox denies each
# run's read of /etc/passwd.
# includeAliasesInList lists each model's variants (setParamsByID), so
# vm-setup.sh can tell pi about them. See local-ai-plan.md for the other
# flags.
infer_llama_swap_yaml() {
  cat <<EOF
healthCheckTimeout: 500
logLevel: info
captureBuffer: 0
performance:
  disabled: true
globalTTL: 1800
includeAliasesInList: true
apiKeys:
  - "$1"
macros:
  llama-server: "$2 --host 127.0.0.1 --port $3 -ngl 99 -fa on --parallel 1 --no-slots --cache-ram 0 --cors-origins http://cors.invalid"
  models-dir: "$MODELS_DIR"
  proxy: "http://127.0.0.1:$3"
EOF
  shift 3
  cat "$1"
  shift
  for f in "$@"; do
    sed '/^models:$/d' "$f"
  done
}

# Usage: infer_model_ok <name> <file> <ctx> <max> <description>
# True if these fields of a new model (from add-model.sh) are safe to put
# in infer-models.local.yaml: a plain name, a relative path inside
# MODELS_DIR, whole numbers, and a description with no quotes,
# backslashes, "$" (llama-swap's macros start with it), or control
# characters (e.g., a newline would start another line).
infer_model_ok() {
  case "$1" in "" | *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$2" in "" | *[!A-Za-z0-9._/-]* | /* | */../* | ../*) return 1 ;; esac
  case "$3" in "" | *[!0-9]*) return 1 ;; esac
  case "$4" in "" | *[!0-9]*) return 1 ;; esac
  case "$5" in "" | *'"'* | *\\* | *'$'* | *[[:cntrl:]]*) return 1 ;; esac
}
