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
# model behind the flags in ${llama-server} or ${sd-server}: each FILE
# has only a "models:" section; each model's name is alone on its line,
# indented two spaces, and no other FILE uses it; and each model has
# exactly one cmd and one proxy, indented four spaces, where the cmd
# starts with ${llama-server} (and doesn't change --host, --port,
# --cors-origins, or --api-key) or with ${sd-server} (and doesn't change
# -l, --listen-ip, or --listen-port). A model's role (see
# infer_model_roles) follows from that cmd, and each role has its own
# backend port: a generalist's proxy is ${proxy}, and its
# capabilities.out (if any) includes text, so pi lists it; a
# specialist's proxy is ${specialist-proxy}, its capabilities.out is
# [image], and it sets a ttl of at most an hour, so it unloads soon after
# use. A model may not set its own macros, since llama-swap lets those
# override ours.
# Being this strict about layout means YAML's other ways of writing a cmd
# (e.g., a flow mapping like "{cmd: ...}") can't slip past it. It catches
# mistakes, such as a pasted --host 0.0.0.0, not a deliberate attacker:
# anyone who can write these files can change host-setup.sh too. Reports
# each problem and fails if there's any. llama-swap checks the rest when
# host-setup.sh validates the config.
infer_models_ok() {
  awk '
    function bad(msg) {
      printf "%s:%d: %s\n", FILENAME, FNR, msg > "/dev/stderr"
      failed = 1
    }
    function model_bad(msg) {
      printf "%s: %s: %s\n", where, model, msg > "/dev/stderr"
      failed = 1
    }
    # Checks the model that just ended, if any.
    function end_model() {
      if (model != "" && (cmds != 1 || proxies != 1)) {
        model_bad("needs exactly one cmd and one proxy, each indented four spaces")
      } else if (backend == "llama-server") {
        if (proxy != "${proxy}")
          model_bad("a generalist (a ${llama-server} model) needs proxy: ${proxy}")
        if (out != "" && out !~ /^\[(.*, *)?text *(,.*)?\]$/)
          model_bad("a generalist (a ${llama-server} model) outputs text, so capabilities.out must include text")
      } else if (backend == "sd-server") {
        if (proxy != "${specialist-proxy}")
          model_bad("a specialist (an ${sd-server} model) needs proxy: ${specialist-proxy}")
        if (out != "[image]")
          model_bad("a specialist (an ${sd-server} model) needs capabilities.out: [image]")
        if (ttl == "" || ttl > 3600)
          model_bad("a specialist (an ${sd-server} model) needs a ttl of at most 3600 seconds")
      }
      model = backend = proxy = out = ttl = section = ""
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
    # The setting this line is in, e.g., "capabilities".
    /^    [^ ]/ { section = $1; sub(/:.*/, "", section) }
    /^    macros:/ { bad("a model must not set its own macros") }
    /^    cmd:/ {
      cmds++
      if ($0 ~ /^    cmd: \$\{llama-server\} /) {
        backend = "llama-server"
        if ($0 ~ /--(host|port|cors-origins|api-key)([ =]|$)/)
          bad("cmd must not set --host, --port, --cors-origins, or --api-key")
      } else if ($0 ~ /^    cmd: \$\{sd-server\} /) {
        backend = "sd-server"
        if ($0 ~ / (-l|--listen-ip|--listen-port)([ =]|$)/)
          bad("cmd must not set -l, --listen-ip, or --listen-port")
      } else
        bad("cmd must start with ${llama-server} or ${sd-server}")
    }
    /^    proxy:/ {
      proxies++
      proxy = $0
      sub(/^    proxy: */, "", proxy)
      gsub(/"/, "", proxy)
    }
    /^    ttl:/ {
      if ($0 ~ /^    ttl: [1-9][0-9]*$/) ttl = $2 + 0
      else bad("ttl must be a whole number of seconds, more than 0")
    }
    section == "capabilities" && /^      out:/ {
      out = $0
      sub(/^      out: */, "", out)
    }
    END {
      end_model()
      if (models == 0) bad("lists no models")
      exit failed
    }' "$@"
}

# Usage: infer_model_roles FILE...
# Prints each model in the models FILEs (which infer_models_ok accepts)
# and its role, one per line: "NAME generalist" for a ${llama-server}
# model, which can chat, and "NAME specialist" for an ${sd-server}
# model, which makes images. Usually the generalist stays loaded, and a
# specialist loads beside it only when needed.
infer_model_roles() {
  awk '
    /^  [^ #]/ { model = $0; gsub(/^  "?|"?:$/, "", model) }
    /^    cmd: \$\{llama-server\} / { print model, "generalist" }
    /^    cmd: \$\{sd-server\} / { print model, "specialist" }' "$@"
}

# Usage: infer_llama_swap_yaml <api-key> <llama-server-path> <generalist-port> <sd-server-path> <specialist-port> <models-file>...
# Prints llama-swap's config: our settings, then the models in each
# <models-file> (see infer-models.yaml), as one "models:" section, then
# a group for each role (see infer_model_roles). Each group runs at most
# one of its models (swap: true), and loading it leaves the other group
# alone (exclusive: false), so a specialist can run beside the
# generalist, but loading another generalist swaps out the current one.
# Every model must be in a group, or llama-swap puts it in a default
# group that evicts both. The macros hold the flags every model needs.
# Each role has its own fixed backend port, since at most one of its
# models runs at a time, and the sandbox allows connecting to just
# those two ports. The backend has no API key of its own, so --cors-origins names an origin no
# web page can have (.invalid is reserved): otherwise any page open in a
# browser on the Mac could query it directly and read the replies.
# sd-server has neither an API key nor such a flag (it allows any
# origin), so while an image model is loaded, any process or web page on
# the Mac can use it directly, and can see other callers' images: a live
# preview of each /sdapi/v1/txt2img or img2img request (from
# /sdapi/v1/progress), and each /sdcpp/v1/img_gen job's results for 10
# minutes (from /sdcpp/v1/jobs/ID, with guessable IDs). As of
# master-964-1d0a58a, /v1/images/generations and /v1/images/edits keep
# neither, so use those for anything private. I accept this for now; see
# local-ai-plan.md's "Image generation" for why, and what's left to check.
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
# globalTTL unloads a model only after a day without requests, since
# unloading discards its KV cache, and then the next turn reprocesses the
# whole conversation (minutes for a long one). Sleep, a mode switch, and
# a request for another model still unload it sooner.
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
globalTTL: 86400
includeAliasesInList: true
apiKeys:
  - "$1"
macros:
  llama-server: "$2 --host 127.0.0.1 --port $3 -ngl 99 -fa on --parallel 1 --no-slots --cache-ram 0 --cors-origins http://cors.invalid"
  sd-server: "$4 --listen-ip 127.0.0.1 --listen-port $5"
  models-dir: "$MODELS_DIR"
  proxy: "http://127.0.0.1:$3"
  specialist-proxy: "http://127.0.0.1:$5"
EOF
  shift 5
  roles="$(infer_model_roles "$@")"
  cat "$1"
  shift
  for f in "$@"; do
    sed '/^models:$/d' "$f"
  done
  cat <<EOF
routing:
  router:
    use: group
    settings:
      groups:
EOF
  for role in generalist specialist; do
    cat <<EOF
        ${role}s:
          swap: true
          exclusive: false
          members:
EOF
    printf '%s\n' "$roles" | awk -v role="$role" '$2 == role { print "            - \"" $1 "\"" }'
  done
}

# Usage: infer_model_ok <name> <description> <file>...
# True if these fields of a new model (from add-model.sh) are safe to put
# in infer-models.local.yaml: a plain name, a description with no
# quotes, backslashes, "$" (llama-swap's macros start with it), or
# control characters (e.g., a newline would start another line), and at
# least one file, each a relative path inside MODELS_DIR.
infer_model_ok() {
  case "$1" in "" | *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$2" in "" | *'"'* | *\\* | *'$'* | *[[:cntrl:]]*) return 1 ;; esac
  shift 2
  [ $# -gt 0 ] || return 1
  for f do
    case "$f" in "" | *[!A-Za-z0-9._/-]* | /* | */../* | ../* | */.. | ..) return 1 ;; esac
  done
}
