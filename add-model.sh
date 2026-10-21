#!/bin/sh
# add-model.sh: add a local AI model to MODELS_DIR, or update the ones
# you have when their publishers change them. Run it where the engine
# runs (the Mac today). POSIX sh, like host-setup.sh, and nothing in it
# is macOS-specific. It doesn't use sudo.
#
# Usage:
#   ./add-model.sh [--serve NAME] [--dir SUBDIR] [--ctx N] [--max N]
#                  [--desc TEXT] [--sha256 HEX] [--license ID] URL
#   ./add-model.sh --check
#   ./add-model.sh --update FILE [--force]
#
# Adding downloads URL into MODELS_DIR (with host-models.sh's checks) and
# appends it to MODEL_DOWNLOADS in config.local.sh, so host-setup.sh
# downloads it on a fresh Mac too. For a Hugging Face URL (a file page's
# link or its download link), the SHA-256 and license come from Hugging
# Face's API. Other URLs must use https and need --sha256. When there's
# no license to record, it's recorded as NOASSERTION (SPDX's term for
# "unknown"), and you should check the license yourself.
# --dir puts the file in a subdirectory of MODELS_DIR, for a model made
# of several files (an image model, or a text model split into shards):
# add each file with the same --dir. --serve NAME also appends an entry
# for it to infer-models.local.yaml (starting that file from
# infer-models.yaml if needed), so once you rerun host-setup.sh (and
# vm-setup.sh on each VM, for pi), harnesses can request NAME. --ctx (the context
# window) defaults to the one Hugging Face reports for the repository's
# GGUF files, --max (the most tokens one reply may use) to 16384 (or the
# context window, if smaller), and --desc to the file name.
#
# URLs stay on the branch you gave (normally main). The SHA-256 in
# MODEL_DOWNLOADS is what pins each file, and SOURCES.tsv records the
# commit it came from. --check lists the Hugging Face models whose files
# have changed since. --update FILE downloads FILE's new version,
# replaces the old one only once the new one passes every check, and
# changes its SHA-256 in config.local.sh or config.sh (whichever has it).
# Like host-setup.sh with engine releases, it refuses a change newer than
# INFER_COOLING_DAYS, so others have had time to notice a bad or
# malicious one; --force overrides that.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/host-models.sh"

usage() {
  sed -n '/^# Usage:/,/^#$/s/^# \{0,1\}//p' "$0" >&2
  echo "For details, run: $0 --help" >&2
  exit 2
}

# help: prints this file's opening comment.
help() {
  sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"
  exit 0
}

HF="https://huggingface.co"

# hf_parse URL: if URL is on Hugging Face, sets hf_repo (OWNER/NAME),
# hf_rev (e.g., main), hf_path (the file's path in the repository), and
# hf_url (its download link), and succeeds. Accepts a file page's link
# (.../blob/...) or its download link (.../resolve/...).
hf_parse() {
  case "$1" in "$HF"/*) ;; *) return 1 ;; esac
  hp_rest="${1#"$HF"/}"
  hp_rest="${hp_rest%%\?*}"
  hf_repo="$(printf '%s\n' "$hp_rest" | cut -d / -f 1-2)"
  hp_kind="$(printf '%s\n' "$hp_rest" | cut -d / -f 3)"
  hf_rev="$(printf '%s\n' "$hp_rest" | cut -d / -f 4)"
  hf_path="$(printf '%s\n' "$hp_rest" | cut -d / -f 5-)"
  case "$hp_kind" in blob | resolve) ;; *) die "$1 isn't a link to a file in a Hugging Face model." ;; esac
  case "$hf_repo" in */*) ;; *) die "$1 isn't a link to a file in a Hugging Face model." ;; esac
  for hp_part in "$hf_repo" "$hf_rev" "$hf_path"; do
    case "$hp_part" in
      "" | *[!A-Za-z0-9._/-]* | . | .. | ./* | ../* | */./* | */../* | */. | */..)
        die "$1 has characters I don't accept in a Hugging Face link."
        ;;
    esac
  done
  hf_url="$HF/$hf_repo/resolve/$hf_rev/$hf_path"
}

# hf_file_info: sets hf_sha256, hf_size, and hf_date (when the file last
# changed, as YYYY-MM-DDTHH:MM:SS UTC) for hf_path at hf_rev in hf_repo.
# They're empty if there's no such file, or Hugging Face publishes no
# SHA-256 for it (it does for every file stored with Git LFS, which
# model files are).
hf_file_info() {
  hf_json="$(curl -fsS --data-urlencode "paths=$hf_path" -d expand=true \
    "$HF/api/models/$hf_repo/paths-info/$hf_rev")" ||
    die "couldn't get $hf_path's details from Hugging Face (does $hf_repo exist?)."
  hf_sha256="$(printf '%s' "$hf_json" | jq -r '.[0].lfs.oid // empty')"
  hf_size="$(printf '%s' "$hf_json" | jq -r '.[0].size // empty')"
  hf_date="$(printf '%s' "$hf_json" | jq -r '.[0].lastCommit.date // empty' | cut -c 1-19)"
}

# hf_repo_info: sets hf_gated ("false" unless you must accept terms
# first), hf_license, and hf_ctx (a GGUF model's context length) for
# hf_repo.
hf_repo_info() {
  hf_json="$(curl -fsSg "$HF/api/models/$hf_repo?expand[]=gguf&expand[]=cardData&expand[]=gated")" ||
    die "couldn't get $hf_repo's details from Hugging Face (does it exist?)."
  hf_gated="$(printf '%s' "$hf_json" | jq -r '.gated')"
  hf_license="$(printf '%s' "$hf_json" | jq -r '.cardData.license // empty')"
  hf_ctx="$(printf '%s' "$hf_json" | jq -r '.gguf.context_length // empty')"
}

# too_new DATE: true if DATE (from hf_file_info) is after the cooling
# cutoff, or unknown.
too_new() {
  [ -n "$1" ] || return 0
  [ "$(printf '%s' "$1" | tr -dc 0-9)" -gt "$(printf '%s' "$cutoff" | tr -dc 0-9)" ]
}

mode=add
url="" serve="" subdir="" ctx="" max="" desc="" sha256="" license=""
update_file="" force=false
while [ $# -gt 0 ]; do
  case "$1" in
    --serve | --dir | --ctx | --max | --desc | --sha256 | --license | --update)
      [ $# -ge 2 ] || usage
      case "$1" in
        --serve) serve="$2" ;;
        --dir) subdir="$2" ;;
        --ctx) ctx="$2" ;;
        --max) max="$2" ;;
        --desc) desc="$2" ;;
        --sha256) sha256="$2" ;;
        --license) license="$2" ;;
        --update) mode=update update_file="$2" ;;
      esac
      shift 2
      ;;
    --check) mode=check && shift ;;
    --force) force=true && shift ;;
    -h | --help) help ;;
    -*) usage ;;
    *)
      [ -z "$url" ] || usage
      url="$1"
      shift
      ;;
  esac
done
cutoff="$(cooling_cutoff)" ||
  die "config.sh's INFER_COOLING_DAYS isn't a number of days."

case "$mode" in
  check)
    if [ -n "$url$serve$subdir$ctx$max$desc$sha256$license" ] || $force; then usage; fi
    while read -r m_url m_sha256 m_license m_subdir; do
      [ -n "$m_url" ] || continue
      m_file="$(model_file "$m_url" "$m_subdir")"
      if ! hf_parse "$m_url"; then
        echo "$m_file: not from Hugging Face, so I can't check it."
        continue
      fi
      hf_file_info
      if [ -z "$hf_sha256" ]; then
        echo "$m_file: GONE; $hf_url no longer exists (or has no SHA-256)."
      elif [ "$hf_sha256" = "$m_sha256" ]; then
        echo "$m_file: up to date."
      elif too_new "$hf_date"; then
        echo "$m_file: changed $hf_date, less than $INFER_COOLING_DAYS days ago; wait to update it."
      else
        echo "$m_file: UPDATE AVAILABLE (changed $hf_date); run ./add-model.sh --update $m_file"
      fi
    done <<EOF
$MODEL_DOWNLOADS
EOF
    exit 0
    ;;
  update)
    [ -z "$url$serve$subdir$ctx$max$desc$sha256$license" ] || usage
    u_url=""
    while read -r m_url m_sha256 m_license m_subdir; do
      [ -n "$m_url" ] || continue
      if [ "$(model_file "$m_url" "$m_subdir")" = "$update_file" ]; then
        u_url="$m_url" u_sha256="$m_sha256" u_license="$m_license" u_subdir="$m_subdir"
      fi
    done <<EOF
$MODEL_DOWNLOADS
EOF
    [ -n "$u_url" ] || die "$update_file isn't in MODEL_DOWNLOADS."
    hf_parse "$u_url" ||
      die "$update_file isn't from Hugging Face, so I can't update it; change its line in MODEL_DOWNLOADS by hand."
    hf_file_info
    [ -n "$hf_sha256" ] || die "$hf_url no longer exists (or has no SHA-256)."
    if [ "$hf_sha256" = "$u_sha256" ]; then
      echo "$update_file is up to date."
      exit 0
    fi
    if too_new "$hf_date" && ! $force; then
      die "$update_file changed $hf_date, less than INFER_COOLING_DAYS ($INFER_COOLING_DAYS) days ago. Wait, or rerun with --force."
    fi
    prepare_models_dir
    fetch_model "$u_url" "$hf_sha256" "$u_license" "$u_subdir"
    # Change the SHA-256 wherever its line is. awk's index() matches the
    # URL literally, whatever characters it has.
    changed=""
    for f in "$SCRIPT_DIR/config.local.sh" "$SCRIPT_DIR/config.sh"; do
      if [ ! -f "$f" ] || ! grep -qF "$u_url $u_sha256" "$f"; then continue; fi
      OLD="$u_url $u_sha256" NEW="$u_url $hf_sha256" awk '{
        i = index($0, ENVIRON["OLD"])
        if (i) $0 = substr($0, 1, i - 1) ENVIRON["NEW"] substr($0, i + length(ENVIRON["OLD"]))
        print
      }' "$f" > "$f.new"
      cat "$f.new" > "$f"
      rm -f "$f.new"
      changed="$changed $(basename "$f")"
    done
    echo "Updated $update_file to the version from $hf_date."
    hf_repo_info
    if [ -n "$hf_license" ] && [ "$hf_license" != "$u_license" ]; then
      echo "WARNING: $hf_repo's license is now $hf_license, not $u_license; check it, and change its line by hand." >&2
    fi
    [ -n "$changed" ] || echo "WARNING: didn't find its line to change its SHA-256; change it by hand." >&2
    case "$changed " in
      *" config.sh "*) echo "Changed its SHA-256 in config.sh; commit that." ;;
    esac
    echo "A model that's loaded keeps using the old file until llama-swap unloads it"
    echo "(after 30 idle minutes)."
    if command -v launchctl >/dev/null 2>&1; then
      echo "To switch now: sudo launchctl kickstart -k system/$INFER_LABEL"
    fi
    exit 0
    ;;
esac

# Adding a model.
if [ -z "$url" ] || $force; then usage; fi
[ -n "$serve" ] || [ -z "$ctx$max$desc" ] || die "--ctx, --max, and --desc only make sense with --serve."
size=""
if hf_parse "$url"; then
  url="$hf_url"
  hf_repo_info
  [ "$hf_gated" = false ] ||
    die "$hf_repo is gated (you must accept its terms on Hugging Face first), and this script doesn't handle Hugging Face tokens."
  hf_file_info
  [ -n "$hf_sha256" ] ||
    die "Hugging Face has no file $hf_path in $hf_repo at $hf_rev, or publishes no SHA-256 for it."
  if [ -n "$sha256" ] && [ "$sha256" != "$hf_sha256" ]; then
    die "--sha256 doesn't match the SHA-256 Hugging Face publishes ($hf_sha256)."
  fi
  sha256="$hf_sha256"
  license="${license:-$hf_license}"
  ctx="${ctx:-$hf_ctx}"
  size="$hf_size"
else
  case "$url" in https://*) ;; *) die "the URL must use https." ;; esac
  [ -n "$sha256" ] || die "for a URL outside Hugging Face, give --sha256 (from its publisher)."
fi
license="${license:-NOASSERTION}"

# Everything here goes into config.local.sh inside double quotes, so
# allow nothing the shell would treat specially there.
case "$url" in *[!A-Za-z0-9._~:/%+=-]*) die "the URL has characters I won't put in config.local.sh." ;; esac
case "$sha256" in *[!0-9a-f]*) die "the SHA-256 must be 64 lowercase hex digits." ;; esac
[ "${#sha256}" -eq 64 ] || die "the SHA-256 must be 64 lowercase hex digits."
case "$license" in
  *[!A-Za-z0-9._+-]*) die "\"$license\" isn't a license ID; give one with --license (e.g., apache-2.0)." ;;
esac
case "$subdir" in
  . | .. | *[!A-Za-z0-9._-]*) die "--dir must be one directory name (letters, digits, '.', '_', and '-')." ;;
esac
file="$(model_file "$url" "$subdir")"
case "$file" in
  *.gguf | *.safetensors) ;;
  *) die "$file isn't a .gguf or .safetensors file." ;;
esac
while read -r m_url m_sha256 m_license m_subdir; do
  [ -n "$m_url" ] || continue
  [ "$(model_file "$m_url" "$m_subdir")" != "$file" ] ||
    die "$file is already in MODEL_DOWNLOADS (to get a newer version, use --update)."
done <<EOF
$MODEL_DOWNLOADS
EOF

if [ -n "$serve" ]; then
  case "$file" in *.gguf) ;; *) die "llama-server only serves GGUF files." ;; esac
  case "$ctx" in
    "") die "Hugging Face doesn't say $file's context length; give --ctx." ;;
    *[!0-9]*) die "--ctx must be a whole number." ;;
  esac
  if [ -z "$max" ]; then
    max=16384
    [ "$max" -le "$ctx" ] || max="$ctx"
  fi
  desc="${desc:-$(basename "$file" .gguf)}"
  infer_model_ok "$serve" "$file" "$ctx" "$max" "$desc" ||
    die "--serve NAME may use only letters, digits, '.', '_', and '-'; --ctx and --max must be whole numbers; and --desc can't have quotes, backslashes, \$, or control characters."
  [ "$max" -le "$ctx" ] || die "--max ($max) is more than the context window ($ctx)."
  models_file="$(infer_models_file)"
  if awk -v n="$serve" '$0 == "  " n ":" || $0 == "  \"" n "\":" { found = 1 } END { exit !found }' "$models_file"; then
    die "$models_file already has a model named $serve."
  fi
  # The new list of models, checked now so a bad entry stops us before
  # the download, and put in place only after it.
  new_models="$SCRIPT_DIR/infer-models.local.yaml.new"
  trap 'rm -f "$new_models"' EXIT
  cp "$models_file" "$new_models"
  # Make sure it ends with a newline.
  [ -z "$(tail -c 1 "$new_models")" ] || echo >> "$new_models"
  cat >> "$new_models" <<EOF
  $serve:
    name: "$desc"
    cmd: \${llama-server} --model \${models-dir}/$file --ctx-size $ctx
    proxy: \${proxy}
    capabilities:
      context: $ctx
    metadata:
      max_tokens: $max
    # Sampling defaults from the model card. Without them, llama-server
    # uses the GGUF's own recommendations, if it has any. A key ending in
    # "?" applies only when a request doesn't set it; see
    # infer-models.yaml.
    # filters:
    #   setParams:
    #     temperature?: 0.7
    #     top_p?: 0.8
    #     top_k?: 20
    #     min_p?: 0
EOF
  infer_models_ok "$new_models" || die "the new entry for $serve breaks infer-models.yaml's rules (a bug)."
fi

prepare_models_dir
if [ -f "$MODELS_DIR/$file" ]; then
  [ "$(shasum -a 256 "$MODELS_DIR/$file" | cut -d ' ' -f 1)" = "$sha256" ] ||
    die "$MODELS_DIR/$file already exists, with a different SHA-256; move it away first."
elif [ -n "$size" ]; then
  avail_kb="$(df -Pk "$MODELS_DIR" | awk 'NR == 2 { print $4 }')"
  [ "$((size / 1024))" -lt "$avail_kb" ] ||
    die "$file needs $((size / 1073741824)) GiB, but only $((avail_kb / 1048576)) GiB is free."
fi
download_model "$url" "$sha256" "$license" "$subdir"

local_config="$SCRIPT_DIR/config.local.sh"
[ -f "$local_config" ] ||
  echo "# config.local.sh: your overrides of config.sh (see config.local.sh.example)." > "$local_config"
# shellcheck disable=SC2016
{
  printf '\n# Added by add-model.sh on %s.\n' "$(date +%Y-%m-%d)"
  printf 'MODEL_DOWNLOADS="${MODEL_DOWNLOADS:+$MODEL_DOWNLOADS\n}%s %s %s%s"\n' "$url" "$sha256" "$license" "${subdir:+ $subdir}"
} >> "$local_config"

echo "Added $file to MODEL_DOWNLOADS in config.local.sh."
case "$license" in
  NOASSERTION) echo "WARNING: no license was published, so I recorded NOASSERTION; check the license before you use the model." >&2 ;;
  other) echo "Its license is \"other\"; read it on Hugging Face before you use the model." ;;
esac
if [ -n "$serve" ]; then
  [ -f "$SCRIPT_DIR/infer-models.local.yaml" ] ||
    echo "Started infer-models.local.yaml from infer-models.yaml; host-setup.sh now uses it instead."
  mv "$new_models" "$SCRIPT_DIR/infer-models.local.yaml"
  echo "Added $serve to infer-models.local.yaml; you may want to add its sampling"
  echo "defaults there. To serve it, rerun ./host-setup.sh here, then"
  echo "./vm-setup.sh on each VM so pi lists it."
fi
