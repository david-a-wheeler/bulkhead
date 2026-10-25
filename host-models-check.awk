# host-models-check.awk: the models-list checker, run by host-models.sh
# as: awk -f host-models-check.awk FILE...
# It checks the rules in initial-models.yaml's opening comment (see that
# file, and infer_models_ok's comment, for what they are), reports each
# problem on stderr, one per line, and exits nonzero if there's any.
# It's plain POSIX awk, so macOS's awk runs it.

function bad(msg) {
  printf "%s:%d: %s\n", FILENAME, FNR, msg > "/dev/stderr"
  failed = 1
}
function model_bad(msg) {
  printf "%s: %s: %s\n", where, model, msg > "/dev/stderr"
  failed = 1
}
# name_ok(P): P is a path in MODELS_DIR or one subdirectory of it: one
# or two plain name components (letters, digits, ".", "_", "-"),
# neither of them "." or "..".
function name_ok(p,   i, n, c) {
  n = split(p, c, "/")
  if (n < 1 || n > 2) return 0
  for (i = 1; i <= n; i++)
    if (c[i] == "." || c[i] == ".." || c[i] !~ /^[A-Za-z0-9._-]+$/)
      return 0
  return 1
}
# path_ok(P): P is a downloaded model file: name_ok, and a .gguf or
# .safetensors name.
function path_ok(p) {
  return name_ok(p) && (p ~ /\.gguf$/ || p ~ /\.safetensors$/)
}
# gen_ok(P): P is a file this host generates: name_ok, and a chat
# template's .jinja name.
function gen_ok(p) {
  return name_ok(p) && p ~ /\.jinja$/
}
# Checks the model that just ended, if any.
function end_model(   i, n, f) {
  n = split(cmd_files, f, " ")
  for (i = 1; i <= n; i++)
    if (!((model SUBSEP f[i]) in listed) && !((model SUBSEP f[i]) in generated))
      model_bad("its cmd uses " f[i] ", but it has no \"# file:\" or \"# generated:\" line for it")
  n = split(file_lines, f, " ")
  for (i = 1; i <= n; i++)
    if (!((model SUBSEP f[i]) in used))
      model_bad("its \"# file:\" line names " f[i] ", which its cmd never uses")
  n = split(gen_lines, f, " ")
  for (i = 1; i <= n; i++)
    if (!((model SUBSEP f[i]) in used))
      model_bad("its \"# generated:\" line names " f[i] ", which its cmd never uses")
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
  model = backend = proxy = out = ttl = section = cmd_files = file_lines = gen_lines = ""
  cmds = proxies = is_default = 0
}
FNR == 1 { end_model(); started = 0 }
/^    # generated:/ {
  if (model == "") {
    bad("a \"# generated:\" line must be inside a model")
    next
  }
  if ($0 !~ /^    # generated: [^ ]+$/ || !gen_ok($3))
    bad("must be \"# generated: PATH\": a .jinja chat template in MODELS_DIR or one subdirectory of it, written by a script in this repo, not a download")
  else {
    generated[model SUBSEP $3] = 1
    gen_lines = gen_lines " " $3
  }
  next
}
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
}
