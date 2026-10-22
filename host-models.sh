# shellcheck shell=sh
# host-models.sh: the list of models the engine serves (models.local.yaml,
# which starts as a copy of initial-models.yaml): its rules, and turning
# it into llama-swap's config. Shared by manage-models.sh, which changes
# the list, and install-models.sh and host-setup.sh, which install the
# config, so the checks that keep a bad entry out of llama-swap's config
# exist only once.
#
# Nothing here is macOS-specific. Source this after config.sh/common.sh
# (it needs SCRIPT_DIR, the repo's top directory):
#   . "$(dirname "$0")/host-models.sh"

# The host's list, and the one a new host starts with.
INFER_MODELS="$SCRIPT_DIR/models.local.yaml"
INFER_INITIAL_MODELS="$SCRIPT_DIR/initial-models.yaml"

# Usage: infer_models_ok FILE...
# Checks the rules in initial-models.yaml's opening comment that keep
# each model behind the flags in ${llama-server} or ${sd-server}: each
# FILE has only a "models:" section; each model's name is alone on its
# line, indented two spaces, and no other FILE uses it; and each model has
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
# override ours. Each "# file:" line is well formed, a file listed twice
# is listed the same way, and each model lists exactly the files its cmd
# uses (as ${models-dir}/PATH). At most one model is the default
# (metadata.default: true), and it's a generalist.
# Being this strict about layout means YAML's other ways of writing a cmd
# (e.g., a flow mapping like "{cmd: ...}") can't slip past it. It catches
# mistakes, such as a pasted --host 0.0.0.0, not a deliberate attacker:
# anyone who can write these files can change our scripts too. Reports
# each problem and fails if there's any. llama-swap checks the rest when
# install-models.sh validates the config.
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
    # path_ok(P): P is a model file in MODELS_DIR or one subdirectory.
    function path_ok(p) {
      return p ~ /^([A-Za-z0-9._-]+\/)?[A-Za-z0-9._-]+\.(gguf|safetensors)$/ &&
        ("/" p) !~ /\/\.\.?(\/|$)/
    }
    # Checks the model that just ended, if any.
    function end_model(   i, n, f) {
      n = split(cmd_files, f, " ")
      for (i = 1; i <= n; i++)
        if (!((model SUBSEP f[i]) in listed))
          model_bad("its cmd uses " f[i] ", but it has no \"# file:\" line for it")
      n = split(file_lines, f, " ")
      for (i = 1; i <= n; i++)
        if (!((model SUBSEP f[i]) in used))
          model_bad("its \"# file:\" line names " f[i] ", which its cmd never uses")
      if (is_default && backend != "llama-server")
        model_bad("only a generalist (a ${llama-server} model) can be the default")
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
      model = backend = proxy = out = ttl = section = cmd_files = file_lines = ""
      cmds = proxies = is_default = 0
    }
    FNR == 1 { end_model(); started = 0 }
    /^    # file:/ {
      if (model == "") {
        bad("a \"# file:\" line must be inside a model")
        next
      }
      if ($0 !~ /^    # file: [^ ]+ [^ ]+ [^ ]+ [^ ]+$/ || !path_ok($3) ||
          length($4) != 64 || $4 ~ /[^0-9a-f]/ || $5 !~ /^[A-Za-z0-9._+-]+$/ ||
          $6 !~ /^https:\/\/[A-Za-z0-9._~:\/%+=-]+$/) {
        bad("must be \"# file: PATH SHA256 LICENSE URL\": a .gguf or .safetensors file in MODELS_DIR or one subdirectory of it, its SHA-256 (64 lowercase hex digits), a license ID, and an https URL")
        next
      }
      name = $6
      sub(/.*\//, "", name)
      leaf = $3
      sub(/.*\//, "", leaf)
      if (leaf != name) bad($3 " must have the same file name as its URL")
      if (!($3 in info)) {
        info[$3] = $4 " " $5 " " $6
        info_at[$3] = FILENAME ":" FNR
      } else if (info[$3] != $4 " " $5 " " $6)
        bad($3 " is listed differently at " info_at[$3])
      listed[model SUBSEP $3] = 1
      file_lines = file_lines " " $3
      next
    }
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
      rest = $0
      while (match(rest, /\$\{models-dir\}\/[^ "]+/)) {
        f = substr(rest, RSTART + 14, RLENGTH - 14)
        used[model SUBSEP f] = 1
        cmd_files = cmd_files " " f
        rest = substr(rest, RSTART + RLENGTH)
      }
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
    section == "metadata" && /^      default: true *$/ {
      is_default = 1
      if (++defaults > 1) bad("only one model can be the default (metadata.default: true)")
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

# Usage: infer_model_files FILE...
# Prints each file the models in the FILEs (which infer_models_ok
# accepts) use, once each and sorted by path, from their "# file:" lines:
# "PATH SHA256 LICENSE URL".
infer_model_files() {
  sed -n 's/^    # file: //p' "$@" | LC_ALL=C sort -u
}

# Usage: recorded_sha256 PATH
# Prints the SHA-256 that MODELS_DIR's SHA256SUMS records for PATH (in
# MODELS_DIR), or nothing.
recorded_sha256() {
  [ -f "$MODELS_DIR/SHA256SUMS" ] || return 0
  awk -v f="$1" '$2 == f { s = $1 } END { print s }' "$MODELS_DIR/SHA256SUMS"
}

# Usage: infer_models_synced FILE
# True if MODELS_DIR has each file the models in FILE use, in the
# version FILE names (by SHA256SUMS, which manage-models.sh sync writes
# once each file passes its checks). Reports each one that doesn't.
infer_models_synced() {
  ims_ok=0
  while read -r ims_path ims_sha256 _; do
    [ -n "$ims_path" ] || continue
    if [ ! -f "$MODELS_DIR/$ims_path" ] || [ "$(recorded_sha256 "$ims_path")" != "$ims_sha256" ]; then
      echo "$MODELS_DIR/$ims_path is missing, or isn't the version $(basename "$1") names." >&2
      ims_ok=1
    fi
  done <<EOF
$(infer_model_files "$1")
EOF
  return "$ims_ok"
}

# Usage: infer_models_default FILE
# Prints the name of the default model in FILE (the one with
# metadata.default: true), or nothing if there's none.
infer_models_default() {
  awk '
    /^  [^ #]/ { model = $0; gsub(/^  "?|"?:$/, "", model) }
    /^    [^ #]/ { section = $1; sub(/:.*/, "", section) }
    section == "metadata" && /^      default: true *$/ { print model }' "$1"
}

# Usage: infer_llama_swap_yaml <api-key> <llama-server-path> <generalist-port> <sd-server-path> <specialist-port> <models-file>
# Prints llama-swap's config: our settings, then the models in
# <models-file> (see initial-models.yaml), then
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
# infer-models can tell clients (e.g., pi) about them. See local-ai-plan.md for the other
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
  roles="$(infer_model_roles "$6")"
  cat "$6"
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
# True if these fields of a new model (from manage-models.sh) are safe
# to put in models.local.yaml: a plain name, a description with no
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
