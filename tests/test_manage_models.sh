#!/bin/sh
# test_manage_models.sh: run manage-models.sh end to end, without the
# network. It works on copies of the scripts it needs, each with its own
# MODELS_DIR, a small initial-models.yaml, and a stand-in curl that
# answers like Hugging Face's API and serves small local files. One copy
# starts as a new host: it syncs, adds, updates, removes, and prunes,
# and checks that bad requests change nothing. Another starts as a host
# set up by the old add-model.sh, and checks that migrating it
# downloads nothing. Run by ci.sh; SHOW=1 also shows each bad request's
# error.
set -eu

TESTS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS/.." && pwd)"
mkdir -p "$REPO/.tmp"
work="$(mktemp -d "$REPO/.tmp/test-manage-models.XXXXXX")"
trap 'rm -rf "${work:?}"' EXIT

fail=0
failed() {
  echo "FAILED: $1" >&2
  fail=1
}

# The files the stand-in Hugging Face serves, by name: GGUF starts with
# "GGUF", and safetensors with an 8-byte header length, then "{".
F="$work/files"
mkdir "$F"
printf 'GGUF initial' > "$F/i.gguf"
printf 'GGUF generalist' > "$F/g.gguf"
printf 'GGUF diffusion' > "$F/d.gguf"
printf '\002\000\000\000\000\000\000\000{}' > "$F/v.safetensors"
printf 'GGUF changed in transit' > "$F/corrupt.gguf.served"
printf 'GGUF published' > "$F/corrupt.gguf"
printf 'GGUF text encoder' > "$F/t.gguf"
printf 'GGUF changed in transit' > "$F/t.gguf.served"
printf 'GGUF another' > "$F/n.gguf"
printf 'GGUF old' > "$F/o.gguf"
printf 'GGUF unused' > "$F/u.gguf"
printf 'GGUF sees' > "$F/w.gguf"
printf 'GGUF projector' > "$F/m.gguf"
printf 'GGUF sees more' > "$F/x.gguf"
printf 'GGUF sees less' > "$F/y.gguf"
printf 'GGUF F16 projector' > "$F/mmproj-F16.gguf"
printf 'GGUF BF16 projector' > "$F/mmproj-BF16.gguf"
sha() {
  sha256sum "$1" | cut -d ' ' -f 1
}

# The stand-in curl (stand-in-curl.sh): paths-info gives a file's
# SHA-256, size, and date; a repository's info says it's not gated, and
# its license and context length; a download link writes the file and
# headers. It serves NAME.served instead of NAME, if that exists, to
# fake a bad download, and logs each download to curl.log.
mkdir "$work/bin"
cat > "$work/bin/curl" <<EOF
#!/bin/sh
F="$F" LOG="$work/curl.log" exec "$TESTS/stand-in-curl.sh" "\$@"
EOF
chmod +x "$work/bin/curl"
: > "$work/curl.log"
# A shasum that logs each file it hashes to hash.log, so the test can
# check that a file already recorded isn't hashed again.
cat > "$work/bin/shasum" <<EOF
#!/bin/sh
for a in "\$@"; do f="\$a"; done
echo "\$f" >> "$work/hash.log"
exec "$(command -v shasum)" "\$@"
EOF
chmod +x "$work/bin/shasum"
: > "$work/hash.log"

HF=https://huggingface.co
# new_repo DIR: a copy of the scripts in DIR, with MODELS_DIR inside it,
# and an initial-models.yaml naming one generalist, i1, the default.
new_repo() {
  mkdir "$1"
  for f in manage-models.sh config.sh common.sh host-models.sh host-models-check.awk manage-models-set-default.awk; do
    cp "$REPO/$f" "$1/"
  done
  echo "MODELS_DIR=\"$1/models\"" > "$1/config.local.sh"
  cat > "$1/initial-models.yaml" <<EOF
# initial-models.yaml: the test's.
#
# The rules.
models:
  i1:
    # file: i.gguf $(sha "$F/i.gguf") apache-2.0 $HF/o/i/resolve/main/i.gguf
    name: "I1"
    cmd: \${llama-server} --model \${models-dir}/i.gguf --ctx-size 8192
    proxy: \${proxy}
    capabilities:
      context: 8192
    metadata:
      max_tokens: 4096
      default: true
EOF
}
# mm DIR ARG...: run DIR's manage-models.sh, with its output in out.
mm() {
  mm_dir="$1"
  shift
  PATH="$work/bin:$PATH" sh "$mm_dir/manage-models.sh" "$@" > "$work/out" 2>&1 < /dev/null
}
# downloads: how many downloads there have been.
downloads() {
  wc -l < "$work/curl.log" | tr -d ' '
}
# in_repo DIR COMMAND...: run a host-models.sh function on DIR's list.
in_repo() (
  SCRIPT_DIR="$1"
  shift
  . "$SCRIPT_DIR/config.sh"
  . "$SCRIPT_DIR/common.sh"
  . "$SCRIPT_DIR/host-models.sh"
  "$@" "$INFER_MODELS"
)

# A new host: sync starts the list and downloads its files; a second
# sync downloads nothing.
T="$work/new"
L="$T/models.local.yaml"
new_repo "$T"
mm "$T" sync || { cat "$work/out" >&2; failed "the first sync"; }
[ -f "$L" ] || failed "sync didn't start models.local.yaml"
head -n 1 "$L" | grep -q '^# models.local.yaml: ' || failed "models.local.yaml's opening comment"
grep -q 'the test' "$L" && failed "models.local.yaml kept initial-models.yaml's first paragraph"
grep -q '^# The rules' "$L" || failed "models.local.yaml lost initial-models.yaml's rules"
[ "$(cat "$T/models/i.gguf")" = "GGUF initial" ] || failed "sync didn't download i.gguf"
grep -qx "$(sha "$F/i.gguf")  i.gguf" "$T/models/SHA256SUMS" || failed "SHA256SUMS doesn't list i.gguf"
n="$(downloads)"
mm "$T" sync || { cat "$work/out" >&2; failed "the second sync"; }
[ "$(downloads)" = "$n" ] || failed "the second sync downloaded something"
mm "$T" check || { cat "$work/out" >&2; failed "check"; }
mm "$T" default && [ "$(cat "$work/out")" = i1 ] || failed "default didn't print i1"

# A generalist.
mm "$T" add g1 "$HF/o/g/blob/main/g.gguf" || { cat "$work/out" >&2; failed "adding a generalist"; }
# shellcheck disable=SC2016 # a literal cmd line
grep -qx '    cmd: ${llama-server} --model ${models-dir}/g.gguf --ctx-size 8192' "$L" ||
  failed "the generalist's cmd"
grep -qx "    # file: g.gguf $(sha "$F/g.gguf") apache-2.0 $HF/o/g/resolve/main/g.gguf" "$L" ||
  failed "the generalist's file line"
[ -f "$T/models/g.gguf" ] || failed "the generalist's file wasn't downloaded"

# A specialist, with two files from two repositories.
args="--diffusion-model $HF/o/d/blob/main/d.gguf --vae $HF/o/v/resolve/main/vae/v.safetensors --cfg-scale 1.0 --steps 4"
mm "$T" add s1 --sd-args "$args" || { cat "$work/out" >&2; failed "adding a specialist"; }
# shellcheck disable=SC2016 # a literal cmd line
grep -qx '    cmd: ${sd-server} --diffusion-model ${models-dir}/s1/d.gguf --vae ${models-dir}/s1/v.safetensors --cfg-scale 1.0 --steps 4' \
  "$L" || failed "the specialist's cmd"
grep -qx '    ttl: 600' "$L" || failed "the specialist's ttl"
[ -f "$T/models/s1/d.gguf" ] && [ -f "$T/models/s1/v.safetensors" ] ||
  failed "the specialist's files weren't downloaded into its directory"

# Another generalist sharing g1's file, as the new default: nothing to
# download, and the file keeps the line it has (here, its license).
n="$(downloads)"
mm "$T" add g2 --default --license mit "$HF/o/g/resolve/main/g.gguf" ||
  { cat "$work/out" >&2; failed "adding a model that shares a file"; }
[ "$(downloads)" = "$n" ] || failed "adding a model that shares a file downloaded it again"
[ "$(grep -c "^    # file: g.gguf .* apache-2.0 " "$L")" -eq 2 ] ||
  failed "a shared file didn't keep the line it already had"
mm "$T" default && [ "$(cat "$work/out")" = g2 ] || failed "add --default didn't make g2 the default"
in_repo "$T" infer_models_ok || failed "the list's rules refused what manage-models.sh added"
mm "$T" list || { cat "$work/out" >&2; failed "list"; }
got="$(tr '\n' ',' < "$work/out")"
[ "$got" = "i1 generalist,g1 generalist,s1 specialist,g2 generalist (default)," ] || failed "list printed '$got'"
mm "$T" default i1 || { cat "$work/out" >&2; failed "default i1"; }
[ "$(in_repo "$T" infer_models_default)" = i1 ] || failed "default i1 didn't make i1 the only default"
in_repo "$T" infer_models_ok || failed "the list's rules refused it after default i1"

# A generalist with vision: both files go in its own directory, and it
# says it takes images.
mm "$T" add w1 --mmproj "$HF/o/w/resolve/main/m.gguf" "$HF/o/w/resolve/main/w.gguf" ||
  { cat "$work/out" >&2; failed "adding a model with --mmproj"; }
# shellcheck disable=SC2016 # a literal cmd line
grep -qxF '    cmd: ${llama-server} --model ${models-dir}/w1/w.gguf --mmproj ${models-dir}/w1/m.gguf --ctx-size 8192' "$L" ||
  failed "--mmproj didn't put the projector in w1's cmd"
model_lines_w1="$(awk '/^  w1:$/ { p = 1; next } /^  [^ ]/ { p = 0 } p' "$L")"
printf '%s\n' "$model_lines_w1" | grep -qx '      in: \[text, image\]' ||
  failed "--mmproj didn't say w1 takes images"
printf '%s\n' "$model_lines_w1" | grep -q '^    # file: w1/m.gguf ' ||
  failed "--mmproj didn't list w1/m.gguf"
[ -f "$T/models/w1/w.gguf" ] && [ -f "$T/models/w1/m.gguf" ] || failed "--mmproj didn't download both files"
mm "$T" check || { cat "$work/out" >&2; failed "check after adding w1"; }
mm "$T" remove w1 || { cat "$work/out" >&2; failed "removing w1"; }
for f in w1/w.gguf w1/m.gguf; do
  mm "$T" prune --delete "$f" || { cat "$work/out" >&2; failed "pruning $f"; }
done

# A repository with vision projectors: add uses the F16 one without
# being asked, and a second model from it reuses that copy.
mm "$T" add x1 "$HF/o/vis/resolve/main/x.gguf" || { cat "$work/out" >&2; failed "adding x1"; }
# shellcheck disable=SC2016 # a literal cmd line
grep -qxF '    cmd: ${llama-server} --model ${models-dir}/x1/x.gguf --mmproj ${models-dir}/x1/mmproj-F16.gguf --ctx-size 8192' "$L" ||
  failed "add didn't use the repository's F16 vision projector"
n="$(downloads)"
mm "$T" add x2 "$HF/o/vis/resolve/main/y.gguf" || { cat "$work/out" >&2; failed "adding x2"; }
# shellcheck disable=SC2016 # a literal cmd line
grep -qxF '    cmd: ${llama-server} --model ${models-dir}/x2/y.gguf --mmproj ${models-dir}/x1/mmproj-F16.gguf --ctx-size 8192' "$L" ||
  failed "x2 didn't reuse x1's vision projector"
[ "$(downloads)" = "$((n + 1))" ] || failed "x2 downloaded the vision projector again"
# A file no model uses any more is reused where it is, and --no-mmproj
# leaves out the projector.
for m in x1 x2; do
  mm "$T" remove "$m" || { cat "$work/out" >&2; failed "removing $m"; }
done
mm "$T" sync || { cat "$work/out" >&2; failed "sync after removing x1 and x2"; }
n="$(downloads)"
: > "$work/hash.log"
mm "$T" add x3 --no-mmproj "$HF/o/vis/resolve/main/x.gguf" || { cat "$work/out" >&2; failed "adding x3"; }
# shellcheck disable=SC2016 # a literal cmd line
grep -qxF '    cmd: ${llama-server} --model ${models-dir}/x1/x.gguf --ctx-size 8192' "$L" ||
  failed "x3 didn't reuse x1/x.gguf, or used a projector despite --no-mmproj"
[ "$(downloads)" = "$n" ] || failed "x3 downloaded x.gguf again"
grep -q 'x1/x\.gguf$' "$work/hash.log" && failed "x3 hashed x1/x.gguf again, though SHA256SUMS records it"
grep -q '  x1/mmproj-F16\.gguf$' "$T/models/SHA256SUMS" ||
  failed "SHA256SUMS forgot x1/mmproj-F16.gguf, which no model uses but is still there"
mm "$T" check || { cat "$work/out" >&2; failed "check after adding x3"; }
mm "$T" remove x3 || { cat "$work/out" >&2; failed "removing x3"; }

# Bad requests: each must fail and change nothing.
snapshot() {
  (cd "$T" && cat models.local.yaml models/SHA256SUMS; find models -type f | sort)
}
before="$(snapshot)"
for bad in \
  "add s2 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf -l 0.0.0.0" \
  "add s2 --sd-args|--diffusion-model https://example.com/d.gguf" \
  "add s2 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf --vae \$x" \
  "add s2 --sd-args|--cfg-scale 1.0" \
  "add s2 --ttl 7200 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf" \
  "add s2 --ttl 0 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf" \
  "add s2 --ctx 4096 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf" \
  "add s2 --default --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf" \
  "add s2 --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf --vae $HF/o/d/blob/main/d.gguf" \
  "add s1 --sd-args|--diffusion-model $HF/o/d/blob/main/n.gguf" \
  "add s2 --sd-args|--diffusion-model $HF/o/d/blob/main/missing.gguf" \
  "add s2 --sd-args|--diffusion-model $HF/o/d/blob/main/corrupt.gguf" \
  "add g3 --ttl 60|$HF/o/g/blob/main/n.gguf" \
  "add g3|$HF/o/g/blob/main/n.gguf $HF/o/g/blob/main/t.gguf" \
  "remove|nosuch" \
  "remove|i1" \
  "default|s1" \
  "default|nosuch" \
  "update|nosuch.gguf" \
  "list|i1" \
  "prune --yes|" \
  "prune|s1/d.gguf" \
  "prune --delete|i.gguf" \
  "prune --delete|../models/i.gguf" \
  "prune --delete|nosuch.gguf" \
  "prune --delete s1/d.gguf|i.gguf" \
  "prune --delete --|--yes" \
  "add w2 --mmproj $HF/o/w/resolve/main/w.gguf|$HF/o/w/resolve/main/w.gguf" \
  "add w2 --mmproj $HF/o/v/resolve/main/v.safetensors|$HF/o/w/resolve/main/w.gguf" \
  "add w2 --mmproj https://example.com/m.gguf|$HF/o/w/resolve/main/w.gguf" \
  "add w2 --no-mmproj --mmproj $HF/o/w/resolve/main/m.gguf|$HF/o/w/resolve/main/w.gguf" \
  "add w2 --mmproj $HF/o/w/resolve/main/m.gguf --sd-args|--diffusion-model $HF/o/d/blob/main/d.gguf"; do
  opts="${bad%%|*}" last="${bad#*|}"
  # shellcheck disable=SC2086 # opts is plain words
  if [ -n "$last" ]; then
    mm "$T" $opts "$last" && failed "manage-models.sh accepted: $opts \"$last\""
  else
    mm "$T" $opts && failed "manage-models.sh accepted: $opts"
  fi
  [ -z "${SHOW:-}" ] || { echo "== $opts \"$last\""; tail -n 2 "$work/out"; }
  [ "$(snapshot)" = "$before" ] || failed "manage-models.sh $opts \"$last\" changed something before failing"
  # A failed download may leave its .partial to resume; clear it.
  find "${T:?}/models" -name '*.partial' -exec rm -f {} +
done

# If one file of several fails, nothing is recorded, and a rerun once
# it's fixed skips the file already downloaded. (sync downloads in order
# of their paths, so n.gguf comes first.)
before="$(snapshot)"
args="--diffusion-model $HF/o/d/blob/main/n.gguf --llm $HF/o/t/blob/main/t.gguf"
mm "$T" add s3 --sd-args "$args" && failed "manage-models.sh accepted a bad download"
[ -f "$T/models/s3/n.gguf" ] || failed "the good file before a bad one wasn't kept"
[ "$(snapshot | grep -v 's3/n.gguf$')" = "$before" ] || failed "a failed download changed the list"
rm -f "${F:?}/t.gguf.served" "${T:?}/models/s3/t.gguf.partial"
mm "$T" add s3 --sd-args "$args" || { cat "$work/out" >&2; failed "rerunning after a bad download"; }
grep -q '^Downloading s3/n.gguf' "$work/out" && failed "the rerun downloaded n.gguf again"
mm "$T" check || { cat "$work/out" >&2; failed "check after the rerun"; }

# The publisher changes g.gguf: outdated says so, and update changes
# both models that use it, and the file.
printf 'GGUF generalist, improved' > "$F/g.gguf"
mm "$T" outdated || { cat "$work/out" >&2; failed "outdated"; }
grep -q '^g.gguf: UPDATE AVAILABLE' "$work/out" || failed "outdated didn't see g.gguf's update"
grep -q '^i.gguf: up to date' "$work/out" || failed "outdated didn't say i.gguf is up to date"
mm "$T" update g.gguf || { cat "$work/out" >&2; failed "update"; }
[ "$(grep -c "^    # file: g.gguf $(sha "$F/g.gguf") " "$L")" -eq 2 ] ||
  failed "update didn't change both of g.gguf's lines"
[ "$(cat "$T/models/g.gguf")" = "GGUF generalist, improved" ] || failed "update didn't replace g.gguf"
mm "$T" check || { cat "$work/out" >&2; failed "check after update"; }

# Removing: a file stays until it's pruned, and only once no model uses
# it.
mm "$T" remove s1 || { cat "$work/out" >&2; failed "removing the specialist"; }
grep -q '^  s1:$' "$L" && failed "removing s1 left its entry"
[ -f "$T/models/s1/d.gguf" ] || failed "removing s1 deleted its files"
mm "$T" remove -- g1 || { cat "$work/out" >&2; failed "removing g1 (after \"--\")"; }
# g2 also uses a generated chat template: check wants it there.
# shellcheck disable=SC2016 # a literal cmd line
sed 's|^    cmd: \(${llama-server} --model ${models-dir}/g.gguf\)|    # generated: g.chat-template.jinja\
    cmd: \1 --chat-template ${models-dir}/g.chat-template.jinja|' "$L" > "$L.new"
mv "$L.new" "$L"
mm "$T" check && failed "check accepted a list whose generated file is missing"
printf '{{ messages }}' > "$T/models/g.chat-template.jinja"
mm "$T" check || { cat "$work/out" >&2; failed "check with g2's chat template"; }
mm "$T" prune || { cat "$work/out" >&2; failed "prune"; }
if ! grep -q "^  s1/d.gguf (.*), from $HF/o/d/" "$work/out" ||
  ! grep -q "^  s1/v.safetensors (.*), from $HF/o/v/" "$work/out"; then
  failed "prune didn't list s1's files, with where each came from"
fi
grep -qxF "    To serve it: ./manage-models.sh add NAME --dir s1 $(grep "^s1/d.gguf	" "$T/models/SOURCES.tsv" | cut -f 2)" "$work/out" ||
  failed "prune didn't say how to serve s1/d.gguf"
grep -q 'install-models\.sh' "$work/out" || failed "prune didn't mention install-models.sh"
grep -q 'g.gguf' "$work/out" && failed "prune listed g.gguf, which g2 still uses"
grep -q 'g.chat-template.jinja' "$work/out" && failed "prune listed g2's chat template"
mm "$T" prune --delete g.chat-template.jinja && failed "prune --delete deleted g2's chat template"
[ -f "$T/models/s1/d.gguf" ] || failed "prune deleted without --delete"
mm "$T" prune --delete g.gguf && failed "prune --delete deleted g.gguf, which g2 uses"
mm "$T" prune --delete s1/v.safetensors || { cat "$work/out" >&2; failed "prune --delete FILE"; }
[ ! -e "$T/models/s1/v.safetensors" ] || failed "prune --delete FILE didn't delete it"
grep -q '  s1/v\.safetensors$' "$T/models/SHA256SUMS" && failed "SHA256SUMS still records s1/v.safetensors after prune deleted it"
[ -f "$T/models/s1/d.gguf" ] || failed "prune --delete FILE deleted another file"
mm "$T" prune --delete || { cat "$work/out" >&2; failed "prune --delete"; }
[ ! -e "$T/models/s1" ] || failed "prune --delete left s1's directory"
[ -f "$T/models/g.gguf" ] || failed "prune --delete deleted g.gguf, which g2 still uses"
mm "$T" remove i1 --yes || { cat "$work/out" >&2; failed "removing the default with --yes"; }
mm "$T" default && failed "default printed a default after it was removed"
mm "$T" remove g2 || { cat "$work/out" >&2; failed "removing g2"; }
mm "$T" prune || { cat "$work/out" >&2; failed "prune after removing g2"; }
grep -q '^  g.chat-template.jinja (.*): a chat template' "$work/out" ||
  failed "prune didn't explain g2's unused chat template"
mm "$T" remove s3 && failed "removing the last model without --yes"
mm "$T" remove --yes s3 || { cat "$work/out" >&2; failed "removing the last model with --yes"; }
mm "$T" check && failed "check accepted a list with no models"

# A MODELS_DIR that could reach outside itself is refused, before any
# command runs. This uses prune without --delete, which only lists
# files, so even a regression here can't delete anything.
cp "$T/config.local.sh" "$T/config.local.sh.good"
for bad in "" / "$T/models/" "$T/models/../models" "$T//models" models; do
  { cat "$T/config.local.sh.good"; echo "MODELS_DIR=\"$bad\""; } > "$T/config.local.sh"
  mm "$T" prune && failed "manage-models.sh accepted MODELS_DIR=\"$bad\""
  grep -q '^ERROR: MODELS_DIR' "$work/out" || failed "MODELS_DIR=\"$bad\" wasn't refused for itself"
done
mv "$T/config.local.sh.good" "$T/config.local.sh"

# A host set up by add-model.sh: the repo's list (i1), plus old1 in
# infer-models.local.yaml, whose file is in config.local.sh's
# MODEL_DOWNLOADS; and u.gguf, which no model used. Migrating it keeps
# everything and downloads nothing.
T="$work/old"
L="$T/models.local.yaml"
new_repo "$T"
mkdir "$T/models"
for f in i.gguf o.gguf u.gguf; do
  cp "$F/$f" "$T/models/"
  printf '%s  %s\n' "$(sha "$F/$f")" "$f" >> "$T/models/SHA256SUMS"
done
{
  printf 'file\tsource_url\tlicense\tadded\tcommit\n'
  for f in i.gguf o.gguf u.gguf; do
    printf '%s\t%s\tapache-2.0\t2026-10-21\t\n' "$f" "$HF/o/x/resolve/main/$f"
  done
} > "$T/models/SOURCES.tsv"
cat > "$T/infer-models.local.yaml" <<'EOF'
# infer-models.local.yaml: the models you've added.
models:
  old1:
    name: "Old"
    cmd: ${llama-server} --model ${models-dir}/o.gguf --ctx-size 4096
    proxy: ${proxy}
    capabilities:
      context: 4096
    metadata:
      max_tokens: 1024
EOF
config="MODELS_DIR=\"$T/models\""
{
  echo "$config"
  echo
  echo '# Added by add-model.sh on 2026-10-21.'
  # shellcheck disable=SC2016 # the line add-model.sh wrote
  echo 'MODEL_DOWNLOADS="${MODEL_DOWNLOADS:+$MODEL_DOWNLOADS'
  echo "}$HF/o/x/resolve/main/o.gguf $(sha "$F/o.gguf") apache-2.0\""
} > "$T/config.local.sh"
n="$(downloads)"
mm "$T" sync || { cat "$work/out" >&2; failed "migrating"; }
[ "$(downloads)" = "$n" ] || failed "migrating downloaded something"
if ! grep -q '^  i1:$' "$L" || ! grep -q '^  old1:$' "$L"; then
  failed "the migrated list doesn't have i1 and old1"
fi
grep -qx "    # file: o.gguf $(sha "$F/o.gguf") apache-2.0 $HF/o/x/resolve/main/o.gguf" "$L" ||
  failed "the migrated old1 has no file line"
[ "$(cat "$T/config.local.sh")" = "$config" ] || failed "migrating left config.local.sh as: $(cat "$T/config.local.sh")"
[ -f "$T/config.local.sh.old" ] && [ -f "$T/infer-models.local.yaml.old" ] && [ ! -e "$T/infer-models.local.yaml" ] ||
  failed "migrating didn't keep the old files as .old"
grep -q '^1 files there' "$work/out" || failed "sync didn't mention u.gguf, which no model uses"
in_repo "$T" infer_models_ok || failed "the migrated list breaks the rules"
mm "$T" check || { cat "$work/out" >&2; failed "check after migrating"; }
for f in i.gguf o.gguf u.gguf; do
  [ -f "$T/models/$f" ] || failed "migrating removed $f"
done

exit "$fail"
