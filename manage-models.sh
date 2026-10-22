#!/bin/sh
# manage-models.sh: manage this host's local AI models: the list of
# models the engine serves (models.local.yaml, gitignored) and their
# files in MODELS_DIR. Run it where the engine runs (the Mac today).
# POSIX sh, like host-setup.sh, and nothing in it is macOS-specific. It
# never uses sudo; ./install-models.sh has the engine serve the result.
#
# Usage:
#   ./manage-models.sh init
#   ./manage-models.sh add NAME [--dir SUBDIR] [--ctx N] [--max N] [--desc TEXT]
#                      [--sha256 HEX] [--license ID] [--default] URL
#   ./manage-models.sh add NAME --sd-args ARGS [--dir SUBDIR] [--ttl N]
#                      [--desc TEXT]
#   ./manage-models.sh remove NAME [--yes]
#   ./manage-models.sh default [NAME]
#   ./manage-models.sh check
#   ./manage-models.sh sync
#   ./manage-models.sh outdated
#   ./manage-models.sh update FILE [--force]
#   ./manage-models.sh prune [--delete]
#
# init starts models.local.yaml as a copy of initial-models.yaml (the
# repo's list for a new host), if there's no list yet. Every other
# command does that first too, and host-setup.sh runs sync. From then
# on, the list is yours: change it with this script, or edit it by hand
# (see initial-models.yaml's opening comment for its rules).
#
# add NAME URL adds a generalist (a llama-server model, which can chat)
# from its GGUF file's URL. For a Hugging Face URL (a file page's link
# or its download link), the SHA-256 and license come from Hugging
# Face's API. Other URLs must use https and need --sha256. When there's
# no license to record, it's recorded as NOASSERTION (SPDX's term for
# "unknown"), and you should check the license yourself. --ctx (the
# context window) defaults to the one Hugging Face reports for the
# repository's GGUF files, --max (the most tokens one reply may use) to
# 32768 (or the context window, if smaller), and --desc to the file
# name. --dir puts the file in a subdirectory of MODELS_DIR. --default
# makes it the default model (see default, below).
#
# add NAME --sd-args ARGS instead adds a specialist (an sd-server model,
# which makes images): ARGS are the sd-server arguments you'd use (e.g.,
# from stable-diffusion.cpp's docs), with each model file written as its
# Hugging Face URL. For example, for FLUX.2-klein 4B:
#   ./manage-models.sh add my-flux --sd-args "--diffusion-model URL1
#     --vae URL2 --llm URL3 --cfg-scale 1.0 --steps 4"
# It downloads each URL into --dir (by default NAME), and the entry names
# each file's local copy instead. --ttl (by default 600) is how many
# seconds without a request before it unloads, at most 3600, and --desc
# defaults to NAME.
#
# Either way, it downloads every file before it changes the list, so if
# a download fails, just rerun it. A file another model already lists is
# shared, not downloaded again, and keeps the line it has (e.g., its
# license).
#
# remove NAME takes NAME out of the list; any model can go, including
# the initial ones. If NAME is the default or the last model, it asks
# first (or, without a terminal, needs --yes). Its files stay in
# MODELS_DIR until you prune them.
#
# default prints the default model's name: the one nopi uses unless you
# give --model. default NAME makes NAME (a generalist) the default
# instead. Each VM learns it from the engine when vm-setup.sh runs, so
# after changing it, run ./install-models.sh here, then ./vm-setup.sh on
# each VM.
#
# check checks the list's rules, and that MODELS_DIR has its files.
# sync downloads each file the list names that's missing, or whose
# SHA-256 differs from the one SHA256SUMS records, to FILE.partial
# first, replacing the old file only once the new one passes every
# check (see fetch_model); then it rewrites SHA256SUMS from the list. It
# rehashes a file only when SHA256SUMS doesn't already say it matches.
#
# URLs stay on the branch you gave (normally main). The SHA-256 in the
# list is what pins each file, and SOURCES.tsv logs where each download
# came from, including the commit. outdated lists the Hugging Face files
# whose publishers have changed them since. update FILE writes FILE's new
# SHA-256 into the list and downloads it, replacing the old file only
# once the new one passes every check. Like host-setup.sh with engine
# releases, it refuses a change newer than INFER_COOLING_DAYS, so others
# have had time to notice a bad or malicious one; --force overrides that.
#
# prune lists the files in MODELS_DIR that no model in the list uses;
# --delete deletes them, so a typo in the list can't cost you a long
# download.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/host-models.sh"

# This deletes files in MODELS_DIR (e.g., prune --delete), so refuse
# anything but a plain absolute path below /, e.g., an empty MODELS_DIR
# in config.local.sh, which would make "$MODELS_DIR/$f" "/$f".
case "$MODELS_DIR" in
  */ | *//* | */./* | */. | */../* | */..)
    die "MODELS_DIR ($MODELS_DIR) must be a plain path: no trailing \"/\", \"//\", \".\", or \"..\"."
    ;;
  /?*) ;;
  *) die "MODELS_DIR (\"$MODELS_DIR\") must be an absolute path below /, e.g., /Users/Shared/models." ;;
esac

usage() {
  awk '/^# Usage:/ { p = 1 } p && /^#$/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
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

# model_lines in|out NAME FILE: prints the lines of model NAME's entry
# in FILE, or ("out") every other line. An entry runs from NAME's line up
# to the next line indented two spaces or less.
model_lines() {
  awk -v want="$1" -v n="$2" '
    /^[^ ]|^ [^ ]|^  [^ ]/ { inside = ($0 == "  " n ":" || $0 == "  \"" n "\":") }
    (want == "in") == inside' "$3"
}

# set_default NAME FILE: prints FILE with NAME as the only model with
# metadata.default: true, adding NAME's metadata section if needed.
set_default() {
  awk -v n="$1" '
    function end_entry() {
      if (model == n && !done) {
        print "    metadata:"
        print "      default: true"
        done = 1
      }
    }
    /^[^ #]|^  [^ #]/ {
      end_entry()
      model = ""
      if (/^  /) { model = $0; gsub(/^  "?|"?:$/, "", model) }
    }
    /^    [^ #]/ { section = $1; sub(/:.*/, "", section) }
    section == "metadata" && /^      default: true *$/ { next }
    { print }
    model == n && /^    metadata:$/ && !done {
      print "      default: true"
      done = 1
    }
    END { end_entry() }' "$2"
}

# Usage: prepare_models_dir
# Creates MODELS_DIR (readable by everyone, so by MACOS_INFER_USER, but
# writable only by you), keeps it out of Time Machine on macOS, and
# starts SOURCES.tsv, or adds the commit column to an older one.
SOURCES_HEADER="$(printf 'file\tsource_url\tlicense\tadded\tcommit')"
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
# without any query (e.g., "?download=true"), maybe in a subdirectory.
model_file() {
  printf '%s\n' "${2:+$2/}$(basename "${1%%\?*}")"
}

# Usage: fetch_model <url> <sha256> <license> <file>
# Downloads one model file to <file> in MODELS_DIR, replacing any older
# copy only once the new one passes every check. It goes to FILE.partial
# first (rerunning resumes it), so an unfinished or wrong download never
# looks like a model. A checksum mismatch removes it and stops. Files
# are read-only. SOURCES.tsv logs each download: its source, license,
# date, and (from Hugging Face) the repository's commit. It's a log, so
# it also has files you've since removed or replaced.
#
# Only formats that can't run code when loaded are allowed: GGUF and
# safetensors, both just a header plus raw numbers. Pickle-based formats
# (PyTorch's .bin, .pt, .pth, and .ckpt, and plain .pkl) can run
# arbitrary code when loaded, so a file with one of those extensions is
# refused before downloading, and every download's first bytes must show
# GGUF (the bytes "GGUF") or safetensors (an 8-byte header length, then
# the JSON header's "{"); anything else is removed and stops the script.
fetch_model() {
  fm_file="$4"
  case "$fm_file" in
    *.bin | *.pt | *.pth | *.ckpt | *.pkl | *.pickle)
      die "$fm_file is a pickle-based format, which can run code when loaded; refusing to download it."
      ;;
  esac
  case "$fm_file" in
    */*)
      mkdir -p "$MODELS_DIR/${fm_file%/*}"
      chmod 755 "$MODELS_DIR/${fm_file%/*}"
      ;;
  esac
  echo "Downloading $fm_file"
  curl -fL -C - -D "$MODELS_DIR/$fm_file.headers" -o "$MODELS_DIR/$fm_file.partial" "$1"
  # Hugging Face names the commit it served; keep it only if it looks
  # like one.
  fm_commit="$(tr -d '\r' < "$MODELS_DIR/$fm_file.headers" |
    sed -n 's/^[Xx]-[Rr]epo-[Cc]ommit: *\([0-9a-f]\{40\}\)$/\1/p' | tail -n 1)"
  rm -f "${MODELS_DIR:?}/${fm_file:?}.headers"
  if [ "$(shasum -a 256 "$MODELS_DIR/$fm_file.partial" | cut -d ' ' -f 1)" != "$2" ]; then
    rm -f "${MODELS_DIR:?}/${fm_file:?}.partial"
    die "$fm_file doesn't match its SHA-256; removed it."
  fi
  # The first 9 bytes as hex: 18 digits.
  case "$(head -c 9 "$MODELS_DIR/$fm_file.partial" | od -An -tx1 | tr -d ' \n')" in
    47475546*) ;;          # GGUF
    ????????????????7b) ;; # safetensors
    *)
      rm -f "${MODELS_DIR:?}/${fm_file:?}.partial"
      die "$fm_file is neither GGUF nor safetensors; removed it."
      ;;
  esac
  chmod 444 "$MODELS_DIR/$fm_file.partial"
  mv -f "$MODELS_DIR/$fm_file.partial" "$MODELS_DIR/$fm_file"
  printf '%s\t%s\t%s\t%s\t%s\n' "$fm_file" "$1" "$3" "$(date +%Y-%m-%d)" "$fm_commit" >> "$MODELS_DIR/SOURCES.tsv"
}

# sync_list FILE: make MODELS_DIR match the list FILE (see sync, above),
# then rewrite SHA256SUMS from it.
sync_list() {
  prepare_models_dir
  while read -r s_path s_sha256 s_license s_url; do
    [ -n "$s_path" ] || continue
    if [ -f "$MODELS_DIR/$s_path" ] &&
        { [ "$(recorded_sha256 "$s_path")" = "$s_sha256" ] ||
          [ "$(shasum -a 256 "$MODELS_DIR/$s_path" | cut -d ' ' -f 1)" = "$s_sha256" ]; }; then
      continue
    fi
    fetch_model "$s_url" "$s_sha256" "$s_license" "$s_path" < /dev/null
  done <<EOF
$(infer_model_files "$1")
EOF
  infer_model_files "$1" | awk '{ print $2 "  " $1 }' > "$MODELS_DIR/SHA256SUMS.new"
  mv "$MODELS_DIR/SHA256SUMS.new" "$MODELS_DIR/SHA256SUMS"
}

# unused_files: prints each file in MODELS_DIR that no model in the
# list uses (except our records, and hidden files like .DS_Store).
unused_files() {
  [ -d "$MODELS_DIR" ] || return 0
  uf_listed="$(infer_model_files "$INFER_MODELS" | awk '{ print $1 }')"
  find "$MODELS_DIR" -type f ! -name '.*' | while IFS= read -r uf; do
    uf="${uf#"$MODELS_DIR"/}"
    case "$uf" in SHA256SUMS | SOURCES.tsv | README.txt) continue ;; esac
    printf '%s\n' "$uf_listed" | grep -qxF -- "$uf" || printf '%s\n' "$uf"
  done | sort
}

# file_record FILE: prints FILE's "# file:" fields (FILE SHA256 LICENSE
# URL), from MODELS_DIR's SHA256SUMS and SOURCES.tsv, for the migration
# below.
file_record() {
  fr_sha256="$(recorded_sha256 "$1")"
  fr_source="$(awk -F '\t' -v f="$1" '$1 == f { s = $3 " " $2 } END { print s }' "$MODELS_DIR/SOURCES.tsv" 2>/dev/null)"
  [ -n "$fr_sha256" ] && [ -n "$fr_source" ] || return 1
  printf '%s %s %s\n' "$1" "$fr_sha256" "$fr_source"
}

# init_list: start models.local.yaml from initial-models.yaml, if
# there's no list yet. Its opening comment's first paragraph, which is
# about initial-models.yaml, becomes one about this list.
#
# The migration: until 2026-10-22, the engine served the repo's list
# plus infer-models.local.yaml (the models add-model.sh added), whose
# files were in config.local.sh's MODEL_DOWNLOADS. Those models join the
# new list, with their "# file:" lines from MODELS_DIR's records, so
# nothing is downloaded again. The old file becomes
# infer-models.local.yaml.old, and the MODEL_DOWNLOADS lines leave
# config.local.sh (keeping a copy as config.local.sh.old). Remove this
# once the Mac has migrated.
init_list() {
  [ ! -f "$INFER_MODELS" ] || return 0
  new="$INFER_MODELS.new"
  {
    cat <<'EOM'
# models.local.yaml: the models this host's engine serves, in
# llama-swap's own config format (its "models:" section). It started as
# a copy of initial-models.yaml, but it's this host's own list
# (gitignored): change it with ./manage-models.sh, or by hand, then run
# ./manage-models.sh check and ./install-models.sh.
#
EOM
    awk 'BEGIN { strip = 1 }
      strip && /^#$/ { strip = 0; next }
      strip && /^#/ { next }
      { strip = 0; print }' "$INFER_INITIAL_MODELS"
  } > "$new"
  old="$SCRIPT_DIR/infer-models.local.yaml"
  migrated=""
  if [ -f "$old" ]; then
    for m in $(infer_model_roles "$old" | cut -d ' ' -f 1); do
      # shellcheck disable=SC2016
      m_files="$(model_lines in "$m" "$old" | sed -n '/^    cmd:/p' |
        grep -o '\${models-dir}/[^ "]*' | sed 's/^\${models-dir}\///' | sort -u)" || true
      m_lines=""
      for f in $m_files; do
        rec="$(file_record "$f")" ||
          die "can't find $f's SHA-256 and source in $MODELS_DIR's SHA256SUMS and SOURCES.tsv, to move $m into models.local.yaml; add $m to $new by hand, then move it to models.local.yaml."
        m_lines="$m_lines    # file: $rec
"
      done
      model_lines in "$m" "$old" | L="$m_lines" awk 'NR == 1 { print; printf "%s", ENVIRON["L"]; next } { print }' >> "$new"
      migrated="$migrated $m"
    done
  fi
  infer_models_ok "$new" ||
    die "the new models.local.yaml (left in $new) breaks the rules (above)."
  local_config="$SCRIPT_DIR/config.local.sh"
  if [ -f "$local_config" ] && grep -q '^# Added by add-model\.sh on ' "$local_config"; then
    cp "$local_config" "$local_config.old"
    # Each one add-model.sh added was a blank line, this comment, and a
    # two-line MODEL_DOWNLOADS assignment.
    awk '
      skip { skip--; next }
      /^# Added by add-model\.sh on / { blank = 0; skip = 2; next }
      blank { print ""; blank = 0 }
      /^$/ { blank = 1; next }
      { print }
      END { if (blank) print "" }' "$local_config.old" > "$local_config"
    echo "Removed add-model.sh's MODEL_DOWNLOADS lines from config.local.sh (the old one is config.local.sh.old)."
  fi
  if [ -f "$local_config" ] && grep -q MODEL_DOWNLOADS "$local_config"; then
    echo "WARNING: config.local.sh still sets MODEL_DOWNLOADS, which nothing uses now; list those files in models.local.yaml instead." >&2
  fi
  mv "$new" "$INFER_MODELS"
  echo "Started models.local.yaml from initial-models.yaml."
  if [ -f "$old" ]; then
    mv "$old" "$old.old"
    echo "Moved in the models from infer-models.local.yaml (now infer-models.local.yaml.old):$migrated"
  fi
}

# confirm MESSAGE: say MESSAGE, and continue only if you agree (or gave
# --yes).
confirm() {
  echo "$1"
  $yes && return 0
  [ -t 0 ] || die "rerun with --yes to do it anyway."
  printf 'Do it anyway? [y/N] '
  read -r answer || answer=""
  case "$answer" in [Yy]*) ;; *) die "left models.local.yaml as it was." ;; esac
}

# offer_install: after a change, offer to run install-models.sh.
offer_install() {
  if [ -t 0 ] && command -v launchctl >/dev/null 2>&1; then
    printf 'Run ./install-models.sh now, so the engine serves this? [y/N] '
    read -r answer || answer=""
    case "$answer" in [Yy]*) exec "$SCRIPT_DIR/install-models.sh" ;; esac
  fi
  echo "To have the engine serve this, run ./install-models.sh."
}

[ $# -gt 0 ] || usage
command="$1"
shift
case "$command" in
  -h | --help) help ;;
  init | add | remove | default | check | sync | outdated | update | prune) ;;
  *) usage ;;
esac
pos1="" pos2="" npos=0 opts=""
subdir="" ctx="" max="" desc="" sha256="" license="" sd_args="" ttl=""
make_default=false yes=false force=false delete=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dir | --ctx | --max | --desc | --sha256 | --license | --sd-args | --ttl)
      [ $# -ge 2 ] || usage
      case "$1" in
        --dir) subdir="$2" ;;
        --ctx) ctx="$2" ;;
        --max) max="$2" ;;
        --desc) desc="$2" ;;
        --sha256) sha256="$2" ;;
        --license) license="$2" ;;
        --sd-args) sd_args="$2" ;;
        --ttl) ttl="$2" ;;
      esac
      opts="$opts $1"
      shift 2
      continue
      ;;
    --default) make_default=true ;;
    --yes) yes=true ;;
    --force) force=true ;;
    --delete) delete=true ;;
    -h | --help) help ;;
    -*) usage ;;
    *)
      npos=$((npos + 1))
      case "$npos" in
        1) pos1="$1" ;;
        2) pos2="$1" ;;
        *) usage ;;
      esac
      shift
      continue
      ;;
  esac
  opts="$opts $1"
  shift
done
# allow N OPTION...: usage unless there are N arguments (besides
# options), and every option given is one of OPTION...
allow() {
  [ "$npos" -eq "$1" ] || usage
  shift
  for o in $opts; do
    case " $* " in *" $o "*) ;; *) usage ;; esac
  done
}
cutoff="$(cooling_cutoff)" ||
  die "config.sh's INFER_COOLING_DAYS isn't a number of days."
trap 'rm -f "${INFER_MODELS:?}.new"' EXIT

case "$command" in
  init)
    allow 0
    if [ -f "$INFER_MODELS" ]; then
      echo "models.local.yaml already exists."
    else
      init_list
    fi
    exit 0
    ;;
  sync)
    allow 0
    init_list
    infer_models_ok "$INFER_MODELS" ||
      die "models.local.yaml breaks the rules in initial-models.yaml's opening comment (above)."
    sync_list "$INFER_MODELS"
    echo "$MODELS_DIR has every file models.local.yaml names."
    n="$(unused_files | wc -l | tr -d ' ')"
    [ "$n" -eq 0 ] ||
      echo "$n files there aren't used by any model; ./manage-models.sh prune lists them."
    exit 0
    ;;
  check)
    allow 0
    init_list
    infer_models_ok "$INFER_MODELS" ||
      die "models.local.yaml breaks the rules in initial-models.yaml's opening comment (above)."
    [ -n "$(infer_models_default "$INFER_MODELS")" ] ||
      echo "WARNING: no model is the default, so vm-setup.sh will stop; set one with ./manage-models.sh default NAME." >&2
    infer_models_synced "$INFER_MODELS" ||
      die "models.local.yaml follows the rules, but MODELS_DIR doesn't have every file it names (above); run ./manage-models.sh sync."
    echo "models.local.yaml follows the rules, and MODELS_DIR has its files."
    exit 0
    ;;
  default)
    init_list
    if [ "$npos" -eq 0 ]; then
      allow 0
      d="$(infer_models_default "$INFER_MODELS")"
      [ -n "$d" ] || die "no model is the default; set one with ./manage-models.sh default NAME."
      printf '%s\n' "$d"
      exit 0
    fi
    allow 1
    infer_model_roles "$INFER_MODELS" | grep -qxF -- "$pos1 generalist" ||
      die "models.local.yaml has no generalist (a \${llama-server} model) named $pos1."
    set_default "$pos1" "$INFER_MODELS" > "$INFER_MODELS.new"
    infer_models_ok "$INFER_MODELS.new" && [ "$(infer_models_default "$INFER_MODELS.new")" = "$pos1" ] ||
      die "couldn't make $pos1 the default; set metadata.default: true for it by hand."
    mv "$INFER_MODELS.new" "$INFER_MODELS"
    echo "$pos1 is now the default. Once the engine serves this, rerun ./vm-setup.sh"
    echo "on each VM, so nopi uses it."
    offer_install
    exit 0
    ;;
  remove)
    allow 1 --yes
    init_list
    [ -n "$(model_lines in "$pos1" "$INFER_MODELS")" ] ||
      die "models.local.yaml has no model named $pos1."
    if [ "$(infer_models_default "$INFER_MODELS")" = "$pos1" ]; then
      confirm "$pos1 is the default model. Without a default, vm-setup.sh stops until you set one (./manage-models.sh default NAME)."
    fi
    if [ "$(infer_model_roles "$INFER_MODELS" | wc -l)" -eq 1 ]; then
      confirm "$pos1 is the last model. With none, install-models.sh refuses to install anything until you add one, so the engine keeps serving what it has."
    fi
    model_lines out "$pos1" "$INFER_MODELS" > "$INFER_MODELS.new"
    mv "$INFER_MODELS.new" "$INFER_MODELS"
    echo "Removed $pos1 from models.local.yaml. Its files stay in MODELS_DIR;"
    echo "./manage-models.sh prune lists the files no model uses."
    offer_install
    exit 0
    ;;
  outdated)
    allow 0
    init_list
    while read -r m_file m_sha256 _ m_url; do
      [ -n "$m_file" ] || continue
      if ! hf_parse "$m_url"; then
        echo "$m_file: not from Hugging Face, so I can't check it."
        continue
      fi
      hf_file_info < /dev/null
      if [ -z "$hf_sha256" ]; then
        echo "$m_file: GONE; $hf_url no longer exists (or has no SHA-256)."
      elif [ "$hf_sha256" = "$m_sha256" ]; then
        echo "$m_file: up to date."
      elif too_new "$hf_date"; then
        echo "$m_file: changed $hf_date, less than $INFER_COOLING_DAYS days ago; wait to update it."
      else
        echo "$m_file: UPDATE AVAILABLE (changed $hf_date); run ./manage-models.sh update $m_file"
      fi
    done <<EOF
$(infer_model_files "$INFER_MODELS")
EOF
    exit 0
    ;;
  update)
    allow 1 --force
    init_list
    u_line="$(infer_model_files "$INFER_MODELS" | awk -v f="$pos1" '$1 == f')"
    [ -n "$u_line" ] || die "no model in models.local.yaml uses $pos1."
    read -r _ u_sha256 u_license u_url <<EOF
$u_line
EOF
    hf_parse "$u_url" ||
      die "$pos1 isn't from Hugging Face, so I can't update it; change its \"# file:\" lines in models.local.yaml by hand, then run ./manage-models.sh sync."
    hf_file_info
    [ -n "$hf_sha256" ] || die "$hf_url no longer exists (or has no SHA-256)."
    if [ "$hf_sha256" = "$u_sha256" ]; then
      echo "$pos1 is up to date."
      exit 0
    fi
    if too_new "$hf_date" && ! $force; then
      die "$pos1 changed $hf_date, less than INFER_COOLING_DAYS ($INFER_COOLING_DAYS) days ago. Wait, or rerun with --force."
    fi
    # Change the SHA-256 on each of its lines, download it, and only then
    # put the new list in place.
    OLD="    # file: $pos1 $u_sha256 " NEW="    # file: $pos1 $hf_sha256 " awk '{
      if (index($0, ENVIRON["OLD"]) == 1) $0 = ENVIRON["NEW"] substr($0, length(ENVIRON["OLD"]) + 1)
      print
    }' "$INFER_MODELS" > "$INFER_MODELS.new"
    sync_list "$INFER_MODELS.new"
    mv "$INFER_MODELS.new" "$INFER_MODELS"
    echo "Updated $pos1 to the version from $hf_date."
    hf_repo_info
    if [ -n "$hf_license" ] && [ "$hf_license" != "$u_license" ]; then
      echo "WARNING: $hf_repo's license is now $hf_license, not $u_license; check it, and change its lines in models.local.yaml by hand." >&2
    fi
    echo "A model that's loaded keeps using the old file until llama-swap unloads it"
    echo "(after a day without requests)."
    if command -v launchctl >/dev/null 2>&1; then
      echo "To switch now: sudo launchctl kickstart -k system/$INFER_LABEL"
    fi
    exit 0
    ;;
  prune)
    allow 0 --delete
    init_list
    unused="$(unused_files)"
    if [ -z "$unused" ]; then
      echo "Every file in $MODELS_DIR is used by a model in models.local.yaml."
      exit 0
    fi
    if ! $delete; then
      echo "No model in models.local.yaml uses these files in $MODELS_DIR:"
      printf '%s\n' "$unused" | sed 's/^/  /'
      echo "To delete them, run: ./manage-models.sh prune --delete"
      exit 0
    fi
    printf '%s\n' "$unused" | while IFS= read -r f; do
      rm -f "${MODELS_DIR:?}/${f:?}"
      # A model's directory, once it's empty.
      case "$f" in */*) rmdir "${MODELS_DIR:?}/${f%/*}" 2>/dev/null || true ;; esac
      echo "Deleted $f."
    done
    exit 0
    ;;
esac

# Adding a model: a generalist's one file (URL), or each file a
# specialist's sd-server arguments (--sd-args) name by URL.
init_list
serve="$pos1"
if [ -n "$sd_args" ]; then
  allow 1 --sd-args --dir --ttl --desc
  ttl="${ttl:-600}"
  case "$ttl" in
    "" | 0* | *[!0-9]*) die "--ttl must be a whole number of seconds, 1 to 3600." ;;
  esac
  [ "$ttl" -le 3600 ] || die "--ttl must be at most 3600 seconds, so a specialist unloads soon after use."
  $make_default && die "only a generalist can be the default."
  subdir="${subdir:-$serve}"
  desc="${desc:-$serve}"
  # Each word of ARGS that's a URL is a file to download.
  urls="$(
    set -f
    for a in $sd_args; do
      case "$a" in https://*) printf '%s\n' "$a" ;; esac
    done
  )"
  [ -n "$urls" ] || die "--sd-args names no model file; write each one as its Hugging Face URL."
else
  allow 2 --dir --ctx --max --desc --sha256 --license --default
  urls="$pos2"
fi
case "$subdir" in
  . | .. | *[!A-Za-z0-9._-]*) die "--dir must be one directory name (letters, digits, '.', '_', and '-')." ;;
esac
[ -z "$(model_lines in "$serve" "$INFER_MODELS")" ] ||
  die "there's already a model named $serve."

# Check each file's URL, and get its SHA-256, license, and size: one
# "GIVEN URL SHA256 LICENSE FILE SIZE" line per file in $files, where
# GIVEN is the URL as given, and URL its download link. A file another
# model lists is shared, with that model's line.
files=""
while read -r given; do
  [ -n "$given" ] || continue
  f_size=0
  if hf_parse "$given"; then
    f_url="$hf_url"
    hf_repo_info
    [ "$hf_gated" = false ] ||
      die "$hf_repo is gated (you must accept its terms on Hugging Face first), and this script doesn't handle Hugging Face tokens."
    hf_file_info
    [ -n "$hf_sha256" ] ||
      die "Hugging Face has no file $hf_path in $hf_repo at $hf_rev, or publishes no SHA-256 for it."
    if [ -n "$sha256" ] && [ "$sha256" != "$hf_sha256" ]; then
      die "--sha256 doesn't match the SHA-256 Hugging Face publishes ($hf_sha256)."
    fi
    f_sha256="$hf_sha256"
    f_license="${license:-$hf_license}"
    f_size="${hf_size:-0}"
    [ -n "$sd_args" ] || ctx="${ctx:-$hf_ctx}"
  else
    [ -z "$sd_args" ] || die "$given isn't a Hugging Face file link; with --sd-args, each file must come from Hugging Face."
    case "$given" in https://*) ;; *) die "the URL must use https." ;; esac
    [ -n "$sha256" ] || die "for a URL outside Hugging Face, give --sha256 (from its publisher)."
    f_url="$given" f_sha256="$sha256" f_license="$license"
  fi
  f_license="${f_license:-NOASSERTION}"
  # Only characters the list's rules allow in a "# file:" line.
  case "$f_url" in *[!A-Za-z0-9._~:/%+=-]*) die "$f_url has characters I won't put in models.local.yaml." ;; esac
  case "$f_sha256" in *[!0-9a-f]*) die "the SHA-256 must be 64 lowercase hex digits." ;; esac
  [ "${#f_sha256}" -eq 64 ] || die "the SHA-256 must be 64 lowercase hex digits."
  case "$f_license" in
    *[!A-Za-z0-9._+-]*) die "\"$f_license\" isn't a license ID; give one with --license (e.g., apache-2.0)." ;;
  esac
  f_file="$(model_file "$f_url" "$subdir")"
  case "$f_file" in
    *.gguf | *.safetensors) ;;
    *) die "$f_file isn't a .gguf or .safetensors file." ;;
  esac
  listed="$(infer_model_files "$INFER_MODELS" | awk -v f="$f_file" '$1 == f')"
  if [ -n "$listed" ]; then
    read -r _ l_sha256 l_license l_url <<EOM
$listed
EOM
    [ "$l_sha256" = "$f_sha256" ] ||
      die "another model already uses $f_file, in a different version; to get the newer one, run ./manage-models.sh update $f_file"
    f_url="$l_url" f_license="$l_license"
  fi
  if printf '%s\n' "$files" | awk -v f="$f_file" '$5 == f { found = 1 } END { exit !found }'; then
    die "--sd-args names $f_file twice (or two files with that name)."
  fi
  files="$files$given $f_url $f_sha256 $f_license $f_file $f_size
"
done <<EOM
$urls
EOM
file_lines="$(printf '%s' "$files" | awk '{ print "    # file: " $5, $3, $4, $2 }')"

if [ -n "$sd_args" ]; then
  # sd-server's arguments, with each URL replaced by its local copy.
  # Only plain words outside URLs, so nothing YAML or llama-swap would
  # treat specially (e.g., "$" starts a macro).
  cmd_args=""
  set -f
  for a in $sd_args; do
    case "$a" in
      https://*) a="\${models-dir}/$(printf '%s' "$files" | G="$a" awk '$1 == ENVIRON["G"] { print $5; exit }')" ;;
      *[!A-Za-z0-9._=:+-]*) die "--sd-args may use only letters, digits, '.', '_', '=', ':', '+', and '-', except in URLs: $a" ;;
    esac
    cmd_args="$cmd_args $a"
  done
  set +f
  entry_files="$(printf '%s' "$files" | awk '{ print $5 }')"
  # shellcheck disable=SC2086 # entry_files is checked file names, one per line
  infer_model_ok "$serve" "$desc" $entry_files ||
    die "NAME may use only letters, digits, '.', '_', and '-'; and --desc can't have quotes, backslashes, \$, or control characters."
else
  file="$(printf '%s' "$files" | awk '{ print $5 }')"
  case "$ctx" in
    "") die "Hugging Face doesn't say $file's context length; give --ctx." ;;
    *[!0-9]*) die "--ctx must be a whole number." ;;
  esac
  case "$file" in *.gguf) ;; *) die "llama-server only serves GGUF files." ;; esac
  if [ -z "$max" ]; then
    max=32768
    [ "$max" -le "$ctx" ] || max="$ctx"
  fi
  case "$max" in *[!0-9]*) die "--max must be a whole number." ;; esac
  [ "$max" -le "$ctx" ] || die "--max ($max) is more than the context window ($ctx)."
  desc="${desc:-$(basename "$file" .gguf)}"
  infer_model_ok "$serve" "$desc" "$file" ||
    die "NAME may use only letters, digits, '.', '_', and '-'; and --desc can't have quotes, backslashes, \$, or control characters."
fi

# The new list, checked now so a bad entry stops us before the download,
# and put in place only after it.
cp "$INFER_MODELS" "$INFER_MODELS.new"
# Make sure it ends with a newline.
[ -z "$(tail -c 1 "$INFER_MODELS.new")" ] || echo >> "$INFER_MODELS.new"
if [ -n "$sd_args" ]; then
  cat >> "$INFER_MODELS.new" <<EOM
  $serve:
$file_lines
    name: "$desc"
    cmd: \${sd-server}$cmd_args
    proxy: \${specialist-proxy}
    # Seconds without a request before it unloads.
    ttl: $ttl
    # sd-server has no /health; it answers /v1/models once it's loaded.
    checkEndpoint: /v1/models
    capabilities:
      in: [text]
      out: [image]
EOM
else
  cat >> "$INFER_MODELS.new" <<EOM
  $serve:
$file_lines
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
    # initial-models.yaml.
    # filters:
    #   setParams:
    #     temperature?: 0.7
    #     top_p?: 0.8
    #     top_k?: 20
    #     min_p?: 0
EOM
fi
if $make_default; then
  set_default "$serve" "$INFER_MODELS.new" > "$INFER_MODELS.new.d"
  mv "$INFER_MODELS.new.d" "$INFER_MODELS.new"
fi
infer_models_ok "$INFER_MODELS.new" ||
  die "the new entry for $serve breaks the rules in initial-models.yaml's opening comment."

# Check there's room, then download every file before changing the
# list, so a failure leaves it as it was; a rerun skips the files
# already here.
prepare_models_dir
need=0
while read -r given f_url f_sha256 f_license f_file f_size; do
  [ -n "$given" ] || continue
  [ -f "$MODELS_DIR/$f_file" ] && [ "$(recorded_sha256 "$f_file")" = "$f_sha256" ] ||
    need=$((need + f_size))
done <<EOM
$files
EOM
avail_kb="$(df -Pk "$MODELS_DIR" | awk 'NR == 2 { print $4 }')"
[ "$((need / 1024))" -lt "$avail_kb" ] ||
  die "the files need $((need / 1073741824)) GiB, but only $((avail_kb / 1048576)) GiB is free."
sync_list "$INFER_MODELS.new"
mv "$INFER_MODELS.new" "$INFER_MODELS"
while read -r given f_url f_sha256 f_license f_file f_size; do
  [ -n "$given" ] || continue
  case "$f_license" in
    NOASSERTION) echo "WARNING: no license was published for $f_file, so I recorded NOASSERTION; check the license before you use it." >&2 ;;
    other) echo "$f_file's license is \"other\"; read it on Hugging Face before you use it." ;;
  esac
done <<EOM
$files
EOM
if [ -n "$sd_args" ]; then
  echo "Added $serve to models.local.yaml as a specialist."
else
  echo "Added $serve to models.local.yaml; you may want to add its sampling"
  echo "defaults there. Once the engine serves it, rerun ./vm-setup.sh on each"
  echo "VM so pi lists it."
fi
offer_install
