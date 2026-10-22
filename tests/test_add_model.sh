#!/bin/sh
# test_add_model.sh: run add-model.sh end to end, without the network.
# It works on a copy of the scripts it needs, with MODELS_DIR inside
# that copy, and a stand-in curl that answers like Hugging Face's API
# and serves small local files. It adds and removes a generalist and a
# specialist, and checks that bad requests change nothing. Run by ci.sh;
# SHOW=1 also shows each bad request's error.
set -eu

TESTS="$(cd "$(dirname "$0")" && pwd)"
REPO="$TESTS/.."
mkdir -p "$REPO/.tmp"
work="$(mktemp -d "$REPO/.tmp/test-add-model.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail=0
failed() {
  echo "FAILED: $1" >&2
  fail=1
}

# The copy of the repo, with MODELS_DIR inside it.
T="$work/repo"
mkdir "$T"
for f in add-model.sh config.sh common.sh host-models.sh infer-models.yaml; do
  cp "$REPO/$f" "$T/"
done
echo "MODELS_DIR=\"$T/models\"" > "$T/config.local.sh"

# The files the stand-in Hugging Face serves, by name: GGUF starts with
# "GGUF", and safetensors with an 8-byte header length, then "{".
F="$work/files"
mkdir "$F"
printf 'GGUF generalist' > "$F/g.gguf"
printf 'GGUF diffusion' > "$F/d.gguf"
printf '\002\000\000\000\000\000\000\000{}' > "$F/v.safetensors"
printf 'GGUF changed in transit' > "$F/corrupt.gguf.served"
printf 'GGUF published' > "$F/corrupt.gguf"
printf 'GGUF text encoder' > "$F/e.gguf"
printf 'GGUF changed in transit' > "$F/e.gguf.served"
printf 'GGUF another' > "$F/n.gguf"

# The stand-in curl: paths-info gives a file's SHA-256, size, and date;
# a repository's info says it's not gated, and its license and context
# length; a download link writes the file and headers. It serves
# NAME.served instead of NAME, if that exists, to fake a bad download.
mkdir "$work/bin"
cat > "$work/bin/curl" <<EOF
#!/bin/sh
F="$F"
EOF
cat >> "$work/bin/curl" <<'EOF'
out="" headers="" path="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -D) headers="$2"; shift ;;
    --data-urlencode) path="${2#paths=}"; shift ;;
    -C | -d) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
case "$url" in
  */paths-info/*)
    f="$F/$(basename "$path")"
    if [ -f "$f" ]; then
      printf '[{"lfs": {"oid": "%s"}, "size": %s, "lastCommit": {"date": "2020-01-01T00:00:00.000Z"}}]\n' \
        "$(sha256sum "$f" | cut -d ' ' -f 1)" "$(wc -c < "$f")"
    else
      echo '[]'
    fi
    ;;
  */api/models/*)
    echo '{"gated": false, "cardData": {"license": "apache-2.0"}, "gguf": {"context_length": 8192}}'
    ;;
  */resolve/*)
    f="$F/$(basename "$url")"
    [ -f "$f.served" ] && f="$f.served"
    [ -f "$f" ] || exit 22
    printf 'HTTP/2 200\r\nx-repo-commit: %s\r\n' 0123456789abcdef0123456789abcdef01234567 > "$headers"
    cat "$f" > "$out"
    ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$work/bin/curl"

HF=https://huggingface.co
add_model() {
  PATH="$work/bin:$PATH" sh "$T/add-model.sh" "$@" > "$work/out" 2>&1
}
# snapshot: the files add-model.sh may change, to compare before and
# after a request that should change nothing.
snapshot() {
  (cd "$T" && cat config.local.sh infer-models.local.yaml 2>/dev/null; find models -type f 2>/dev/null | sort)
}
# models_ok: the models it serves pass host-setup.sh's checks.
models_ok() {
  (
    SCRIPT_DIR="$T"
    . "$T/config.sh"
    . "$T/common.sh"
    . "$T/host-models.sh"
    with_infer_models infer_models_ok
  )
}
# roles: each model and its role, as host-setup.sh would derive them.
roles() {
  (
    SCRIPT_DIR="$T"
    . "$T/config.sh"
    . "$T/common.sh"
    . "$T/host-models.sh"
    with_infer_models infer_model_roles | tr '\n' ' '
  )
}

# A generalist.
add_model --serve g1 "$HF/o/g/blob/main/g.gguf" ||
  { cat "$work/out" >&2; failed "adding a generalist"; }
# shellcheck disable=SC2016 # a literal cmd line
grep -qx '    cmd: ${llama-server} --model ${models-dir}/g.gguf --ctx-size 8192' "$T/infer-models.local.yaml" ||
  failed "the generalist's cmd"
[ -f "$T/models/g.gguf" ] || failed "the generalist's file wasn't downloaded"
grep -qF "$HF/o/g/resolve/main/g.gguf " "$T/config.local.sh" ||
  failed "the generalist's file isn't in config.local.sh"

# A specialist, with two files from two repositories.
args="--diffusion-model $HF/o/d/blob/main/d.gguf --vae $HF/o/v/resolve/main/vae/v.safetensors --cfg-scale 1.0 --steps 4"
add_model --serve s1 --sd-args "$args" ||
  { cat "$work/out" >&2; failed "adding a specialist"; }
# shellcheck disable=SC2016 # a literal cmd line
grep -qx '    cmd: ${sd-server} --diffusion-model ${models-dir}/s1/d.gguf --vae ${models-dir}/s1/v.safetensors --cfg-scale 1.0 --steps 4' \
  "$T/infer-models.local.yaml" || failed "the specialist's cmd"
grep -qx '    ttl: 600' "$T/infer-models.local.yaml" || failed "the specialist's ttl"
[ -f "$T/models/s1/d.gguf" ] && [ -f "$T/models/s1/v.safetensors" ] ||
  failed "the specialist's files weren't downloaded into its directory"
[ "$(grep -c '^}https://.* s1"$' "$T/config.local.sh")" -eq 2 ] ||
  failed "config.local.sh doesn't list both of the specialist's files, in its directory"
models_ok || failed "host-setup.sh's checks refused what add-model.sh added"
got="$(roles)"
case "$got" in
  *" g1 generalist s1 specialist ") ;;
  *) failed "the roles are '$got'" ;;
esac

# Bad requests: each must fail and change nothing.
before="$(snapshot)"
for bad in \
  "--serve s2 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf -l 0.0.0.0" \
  "--serve s2 --sd-args|--diffusion-model https://example.com/d.gguf" \
  "--serve s2 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf --vae \$x" \
  "--serve s2 --sd-args|--cfg-scale 1.0" \
  "--serve s2 --ttl 7200 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf" \
  "--serve s2 --ttl 0 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf" \
  "--serve s2 --ctx 4096 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf" \
  "--serve s2 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf --vae $HF/o/d/blob/main/d.gguf" \
  "--serve s1 --sd-args|--diffusion-model $HF/o/d/blob/main/n.gguf" \
  "--serve s2 --sd-args|--diffusion-model $HF/o/d/blob/main/missing.gguf" \
  "--serve s2 --sd-args|--diffusion-model $HF/o/d/blob/main/corrupt.gguf" \
  "--serve g2 --ttl 60|$HF/o/g/blob/main/g.gguf"; do
  opts="${bad%%|*}" last="${bad#*|}"
  # shellcheck disable=SC2086 # opts is plain words
  if add_model $opts "$last"; then
    failed "add-model.sh accepted: $opts \"$last\""
  fi
  [ -z "${SHOW:-}" ] || { echo "== $opts \"$last\""; tail -n 2 "$work/out"; }
  [ "$(snapshot)" = "$before" ] || failed "add-model.sh $opts \"$last\" changed something before failing"
  # A failed download may leave its .partial to resume; clear it.
  find "$T/models" -name '*.partial' -exec rm -f {} +
done

# If one file of several fails, nothing is recorded, and a rerun once
# it's fixed skips the file already downloaded.
before="$(snapshot)"
args="--diffusion-model $HF/o/d/blob/main/n.gguf --llm $HF/o/e/blob/main/e.gguf"
if add_model --serve s3 --sd-args "$args"; then failed "add-model.sh accepted a bad download"; fi
[ -f "$T/models/s3/n.gguf" ] || failed "the good file before a bad one wasn't kept"
[ "$(snapshot | grep -v 's3/n.gguf$')" = "$before" ] ||
  failed "a failed download recorded something"
rm -f "$F/e.gguf.served" "$T/models/s3/e.gguf.partial"
add_model --serve s3 --sd-args "$args" || { cat "$work/out" >&2; failed "rerunning after a bad download"; }
grep -q '^Downloading s3/n.gguf' "$work/out" && failed "the rerun downloaded n.gguf again"
models_ok || failed "host-setup.sh's checks refused the rerun's specialist"
add_model --remove s3 || { cat "$work/out" >&2; failed "removing s3"; }

# Removing.
add_model --remove s1 || { cat "$work/out" >&2; failed "removing the specialist"; }
[ ! -e "$T/models/s1" ] || failed "removing the specialist left its directory"
! grep -q 's1' "$T/config.local.sh" || failed "removing the specialist left its lines in config.local.sh"
! grep -q 's1' "$T/models/SHA256SUMS" "$T/models/SOURCES.tsv" || failed "removing the specialist left its records"
grep -q '^  g1:$' "$T/infer-models.local.yaml" || failed "removing the specialist removed the generalist"
models_ok || failed "host-setup.sh's checks refused what was left"
add_model --remove g1 || { cat "$work/out" >&2; failed "removing the generalist"; }
[ ! -e "$T/infer-models.local.yaml" ] || failed "removing the last model left infer-models.local.yaml"
[ ! -e "$T/models/g.gguf" ] || failed "removing the generalist left its file"
[ "$(cat "$T/config.local.sh")" = "MODELS_DIR=\"$T/models\"" ] ||
  failed "removing both left config.local.sh changed"
if add_model --remove qwen3-0.6b; then failed "add-model.sh removed a repo model"; fi

exit "$fail"
