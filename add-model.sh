#!/bin/sh
# add-model.sh: add a local AI model to MODELS_DIR, update the ones
# you have when their publishers change them, or remove one you added.
# Run it where the engine runs (the Mac today). POSIX sh, like
# host-setup.sh, and nothing in it is macOS-specific. It doesn't use
# sudo.
#
# Usage:
#   ./add-model.sh [--serve NAME] [--dir SUBDIR] [--ctx N] [--max N]
#                  [--desc TEXT] [--sha256 HEX] [--license ID] URL
#   ./add-model.sh --serve NAME --sd-args ARGS [--dir SUBDIR] [--ttl N]
#                  [--desc TEXT]
#   ./add-model.sh --check
#   ./add-model.sh --update FILE [--force]
#   ./add-model.sh --remove NAME
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
# for it to infer-models.local.yaml (the models you add to
# infer-models.yaml's; it starts the file if needed), so once you rerun
# host-setup.sh (and vm-setup.sh on each VM, for pi), harnesses can
# request NAME. --ctx (the context window) defaults to the one Hugging
# Face reports for the repository's GGUF files, --max (the most tokens
# one reply may use) to 32768 (or the context window, if smaller), and
# --desc to the file name. That makes it a generalist (a llama-server
# model, which can chat; see infer-models.yaml).
#
# --sd-args ARGS instead adds a specialist (an sd-server model, which
# makes images): ARGS are the sd-server arguments you'd use (e.g., from
# stable-diffusion.cpp's docs), with each model file written as its
# Hugging Face URL. For example, for FLUX.2-klein 4B:
#   ./add-model.sh --serve my-flux --sd-args "--diffusion-model URL1
#     --vae URL2 --llm URL3 --cfg-scale 1.0 --steps 4"
# It downloads each URL into --dir (by default NAME), and the entry names
# each file's local copy instead. --ttl (by default 600) is how many
# seconds without a request before it unloads, at most 3600, and --desc
# defaults to NAME. It downloads every file before it records any, so if
# one fails, just rerun it.
#
# --remove NAME undoes --serve NAME: it removes NAME's entry from
# infer-models.local.yaml (and the file, once it lists no models), and
# for each of NAME's files, unless another model uses it or config.sh
# lists it, its line in config.local.sh, the file itself, and its lines
# in SHA256SUMS and SOURCES.tsv. It won't touch a model in the repo's
# infer-models.yaml.
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

# model_lines in|out NAME FILE...: prints the lines of model NAME's
# entry in the FILEs (in infer-models.yaml's format), or ("out") every
# other line. An entry runs from NAME's line up to the next line
# indented two spaces or less.
model_lines() {
  ml_want="$1" ml_name="$2"
  shift 2
  awk -v want="$ml_want" -v n="$ml_name" '
    /^[^ ]|^ [^ ]|^  [^ ]/ { inside = ($0 == "  " n ":" || $0 == "  \"" n "\":") }
    (want == "in") == inside' "$@"
}

mode=add
url="" serve="" subdir="" ctx="" max="" desc="" sha256="" license=""
sd_args="" ttl="" update_file="" remove_name="" force=false
while [ $# -gt 0 ]; do
  case "$1" in
    --serve | --dir | --ctx | --max | --desc | --sha256 | --license | --sd-args | --ttl | --update | --remove)
      [ $# -ge 2 ] || usage
      case "$1" in
        --serve) serve="$2" ;;
        --sd-args) sd_args="$2" ;;
        --ttl) ttl="$2" ;;
        --dir) subdir="$2" ;;
        --ctx) ctx="$2" ;;
        --max) max="$2" ;;
        --desc) desc="$2" ;;
        --sha256) sha256="$2" ;;
        --license) license="$2" ;;
        --update) mode=update update_file="$2" ;;
        --remove) mode=remove remove_name="$2" ;;
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
    if [ -n "$url$serve$subdir$ctx$max$desc$sha256$license$sd_args$ttl" ] || $force; then usage; fi
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
    [ -z "$url$serve$subdir$ctx$max$desc$sha256$license$sd_args$ttl" ] || usage
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
    echo "(after a day without requests)."
    if command -v launchctl >/dev/null 2>&1; then
      echo "To switch now: sudo launchctl kickstart -k system/$INFER_LABEL"
    fi
    exit 0
    ;;
  remove)
    if [ -n "$url$serve$subdir$ctx$max$desc$sha256$license$sd_args$ttl" ] || $force; then usage; fi
    local_models="$SCRIPT_DIR/infer-models.local.yaml"
    local_config="$SCRIPT_DIR/config.local.sh"
    if [ -n "$(model_lines in "$remove_name" "$SCRIPT_DIR/infer-models.yaml")" ]; then
      die "$remove_name is in the repo's infer-models.yaml; I only remove models you've added."
    fi
    if [ ! -f "$local_models" ] || [ -z "$(model_lines in "$remove_name" "$local_models")" ]; then
      die "infer-models.local.yaml has no model named $remove_name."
    fi
    # The files its cmd names: one for a generalist, maybe several for a
    # specialist.
    # shellcheck disable=SC2016
    r_files="$(model_lines in "$remove_name" "$local_models" | sed -n '/^    cmd:/p' |
      grep -o '\${models-dir}/[^ ]*' | sed 's/^\${models-dir}\///' | sort -u)" || true
    [ -n "$r_files" ] ||
      die "can't tell which files $remove_name serves from its cmd in infer-models.local.yaml; remove it by hand."
    for r_file in $r_files; do
      case "$r_file" in
        *[!A-Za-z0-9._/-]* | /* | ../* | */../*)
          die "can't tell which files $remove_name serves from its cmd in infer-models.local.yaml; remove it by hand."
          ;;
      esac
    done
    # Work out every change before making any.
    new_models="$local_models.new"
    trap 'rm -f "$new_models" "$local_config.new" "$local_config.next"' EXIT
    model_lines out "$remove_name" "$local_models" > "$new_models"
    if [ -f "$local_config" ]; then cp "$local_config" "$local_config.new"; else : > "$local_config.new"; fi
    removed="" kept=""
    for r_file in $r_files; do
      # shellcheck disable=SC2016
      r_users="$(cat "$SCRIPT_DIR/infer-models.yaml" "$new_models" |
        F="\${models-dir}/$r_file " awk '
          /^    cmd:/ && index($0 " ", ENVIRON["F"]) { n++ }
          END { print n + 0 }')"
      r_url=""
      while read -r m_url m_sha256 m_license m_subdir; do
        [ -n "$m_url" ] || continue
        if [ "$(model_file "$m_url" "$m_subdir")" = "$r_file" ]; then
          r_url="$m_url" r_sha256="$m_sha256"
        fi
      done <<EOM
$MODEL_DOWNLOADS
EOM
      if [ "$r_users" -gt 0 ]; then
        kept="$kept$r_file, since another model uses it.
"
        continue
      elif [ -z "$r_url" ]; then
        kept="$kept$r_file, since it isn't in MODEL_DOWNLOADS.
"
        continue
      elif grep -qF "$r_url $r_sha256" "$SCRIPT_DIR/config.sh"; then
        kept="$kept$r_file, since config.sh lists it.
"
        continue
      fi
      # Drop the lines add-model.sh added for r_url: its comment, the
      # blank line before that, and its two-line MODEL_DOWNLOADS
      # assignment.
      # shellcheck disable=SC2016
      A='MODEL_DOWNLOADS="${MODEL_DOWNLOADS:+$MODEL_DOWNLOADS' B="}$r_url $r_sha256 " awk '
        {
          line[NR] = $0
          if (index($0, ENVIRON["B"]) == 1 && /"$/ && line[NR - 1] == ENVIRON["A"]) {
            hit = NR
            hits++
          }
        }
        END {
          if (hits != 1) exit 1
          drop[hit] = drop[hit - 1] = 1
          if (line[hit - 2] ~ /^# Added by add-model\.sh on /) {
            drop[hit - 2] = 1
            if (line[hit - 3] == "") drop[hit - 3] = 1
          }
          for (i = 1; i <= NR; i++) if (!(i in drop)) print line[i]
        }' "$local_config.new" > "$local_config.next" 2>/dev/null ||
        die "couldn't find the line add-model.sh added to config.local.sh for $r_file; remove that line by hand, then rerun."
      mv "$local_config.next" "$local_config.new"
      removed="$removed $r_file"
    done

    if grep -q '^  [^ #]' "$new_models"; then
      mv "$new_models" "$local_models"
      echo "Removed $remove_name from infer-models.local.yaml."
    else
      rm -f "$new_models" "$local_models"
      echo "Removed $remove_name, and infer-models.local.yaml, which listed no other models."
    fi
    if [ -n "$removed" ]; then
      cat "$local_config.new" > "$local_config"
      for r_file in $removed; do
        rm -f "$MODELS_DIR/$r_file"
        remove_model_records "$r_file"
        # A specialist's directory, once it's empty.
        case "$r_file" in */*) rmdir "$MODELS_DIR/${r_file%/*}" 2>/dev/null || true ;; esac
        echo "Removed $r_file, and its line in config.local.sh."
      done
    fi
    printf '%s' "$kept" | sed 's/^/Kept /'
    echo "To stop serving it, rerun ./host-setup.sh here, then ./vm-setup.sh on"
    echo "each VM so pi stops listing it."
    exit 0
    ;;
esac

# Adding a model: a generalist's one file (URL), or each file a
# specialist's sd-server arguments (--sd-args) name by URL.
if [ -z "$url$sd_args" ] || $force; then usage; fi
[ -z "$url" ] || [ -z "$sd_args" ] || die "give a URL (for a generalist) or --sd-args (for a specialist), not both."
if [ -n "$sd_args" ]; then
  [ -n "$serve" ] || die "--sd-args only makes sense with --serve."
  [ -z "$ctx$max" ] || die "--ctx and --max are for a generalist, not --sd-args."
  [ -z "$sha256$license" ] ||
    die "--sha256 and --license are for one URL; with --sd-args, each file must come from Hugging Face."
  ttl="${ttl:-600}"
  case "$ttl" in
    "" | 0* | *[!0-9]*) die "--ttl must be a whole number of seconds, 1 to 3600." ;;
  esac
  [ "$ttl" -le 3600 ] || die "--ttl must be at most 3600 seconds, so a specialist unloads soon after use."
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
  [ -n "$serve" ] || [ -z "$ctx$max$desc" ] || die "--ctx, --max, and --desc only make sense with --serve."
  [ -z "$ttl" ] || die "--ttl is for a specialist (--sd-args); a generalist stays loaded for up to a day."
  urls="$url"
fi
case "$subdir" in
  . | .. | *[!A-Za-z0-9._-]*) die "--dir must be one directory name (letters, digits, '.', '_', and '-')." ;;
esac

# Check each file's URL, and get its SHA-256, license, and size: one
# "GIVEN URL SHA256 LICENSE FILE SIZE" line per file in $files, where
# GIVEN is the URL as given, and URL its download link.
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
  # Everything here goes into config.local.sh inside double quotes, so
  # allow nothing the shell would treat specially there.
  case "$f_url" in *[!A-Za-z0-9._~:/%+=-]*) die "$f_url has characters I won't put in config.local.sh." ;; esac
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
  while read -r m_url m_sha256 m_license m_subdir; do
    [ -n "$m_url" ] || continue
    [ "$(model_file "$m_url" "$m_subdir")" != "$f_file" ] ||
      die "$f_file is already in MODEL_DOWNLOADS (to get a newer version, use --update)."
  done <<EOM
$MODEL_DOWNLOADS
EOM
  if printf '%s\n' "$files" | awk -v f="$f_file" '$5 == f { found = 1 } END { exit !found }'; then
    die "--sd-args names $f_file twice (or two files with that name)."
  fi
  files="$files$given $f_url $f_sha256 $f_license $f_file $f_size
"
done <<EOM
$urls
EOM

if [ -n "$serve" ]; then
  if [ -n "$(with_infer_models model_lines in "$serve")" ]; then
    die "there's already a model named $serve."
  fi
  if [ -n "$sd_args" ]; then
    # sd-server's arguments, with each URL replaced by its local copy.
    # Only plain words outside URLs, so nothing YAML or llama-swap
    # would treat specially (e.g., "$" starts a macro).
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
      die "--serve NAME may use only letters, digits, '.', '_', and '-'; and --desc can't have quotes, backslashes, \$, or control characters."
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
      die "--serve NAME may use only letters, digits, '.', '_', and '-'; and --desc can't have quotes, backslashes, \$, or control characters."
  fi
  # The new list of models you've added, checked now so a bad entry
  # stops us before the download, and put in place only after it.
  new_models="$SCRIPT_DIR/infer-models.local.yaml.new"
  trap 'rm -f "$new_models"' EXIT
  if [ -f "$SCRIPT_DIR/infer-models.local.yaml" ]; then
    cp "$SCRIPT_DIR/infer-models.local.yaml" "$new_models"
    # Make sure it ends with a newline.
    [ -z "$(tail -c 1 "$new_models")" ] || echo >> "$new_models"
  else
    cat > "$new_models" <<'EOM'
# infer-models.local.yaml: the models you've added to the ones in
# infer-models.yaml, in the same format (see its opening comment), so
# host-setup.sh serves both. Gitignored. ./add-model.sh --serve adds to
# it, and --remove takes a model out.
models:
EOM
  fi
  if [ -n "$sd_args" ]; then
    cat >> "$new_models" <<EOM
  $serve:
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
    cat >> "$new_models" <<EOM
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
EOM
  fi
  infer_models_ok "$SCRIPT_DIR/infer-models.yaml" "$new_models" ||
    die "the new entry for $serve breaks infer-models.yaml's rules."
fi

# Download every file before recording any, so a failure leaves nothing
# half-added; a rerun skips the files already here.
prepare_models_dir
need=0
while read -r given f_url f_sha256 f_license f_file f_size; do
  [ -n "$given" ] || continue
  if [ -f "$MODELS_DIR/$f_file" ]; then
    [ "$(shasum -a 256 "$MODELS_DIR/$f_file" | cut -d ' ' -f 1)" = "$f_sha256" ] ||
      die "$MODELS_DIR/$f_file already exists, with a different SHA-256; move it away first."
  else
    need=$((need + f_size))
  fi
done <<EOM
$files
EOM
avail_kb="$(df -Pk "$MODELS_DIR" | awk 'NR == 2 { print $4 }')"
[ "$((need / 1024))" -lt "$avail_kb" ] ||
  die "the files need $((need / 1073741824)) GiB, but only $((avail_kb / 1048576)) GiB is free."
while read -r given f_url f_sha256 f_license f_file f_size; do
  [ -n "$given" ] || continue
  download_model "$f_url" "$f_sha256" "$f_license" "$subdir" < /dev/null
done <<EOM
$files
EOM

local_config="$SCRIPT_DIR/config.local.sh"
[ -f "$local_config" ] ||
  echo "# config.local.sh: your overrides of config.sh (see config.local.sh.example)." > "$local_config"
while read -r given f_url f_sha256 f_license f_file f_size; do
  [ -n "$given" ] || continue
  # shellcheck disable=SC2016
  {
    printf '\n# Added by add-model.sh on %s.\n' "$(date +%Y-%m-%d)"
    printf 'MODEL_DOWNLOADS="${MODEL_DOWNLOADS:+$MODEL_DOWNLOADS\n}%s %s %s%s"\n' "$f_url" "$f_sha256" "$f_license" "${subdir:+ $subdir}"
  } >> "$local_config"
  echo "Added $f_file to MODEL_DOWNLOADS in config.local.sh."
  case "$f_license" in
    NOASSERTION) echo "WARNING: no license was published for $f_file, so I recorded NOASSERTION; check the license before you use it." >&2 ;;
    other) echo "$f_file's license is \"other\"; read it on Hugging Face before you use it." ;;
  esac
done <<EOM
$files
EOM
if [ -n "$serve" ]; then
  [ -f "$SCRIPT_DIR/infer-models.local.yaml" ] ||
    echo "Started infer-models.local.yaml, which lists the models you add."
  mv "$new_models" "$SCRIPT_DIR/infer-models.local.yaml"
  if [ -n "$sd_args" ]; then
    echo "Added $serve to infer-models.local.yaml as a specialist. To serve it,"
    echo "rerun ./host-setup.sh here."
  else
    echo "Added $serve to infer-models.local.yaml; you may want to add its sampling"
    echo "defaults there. To serve it, rerun ./host-setup.sh here, then"
    echo "./vm-setup.sh on each VM so pi lists it."
  fi
fi
