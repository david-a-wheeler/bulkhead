# shellcheck shell=sh
# host-models.sh: downloading local AI models into MODELS_DIR. Shared by
# host-setup.sh (every model in MODEL_DOWNLOADS) and add-model.sh (adding
# or updating one), so the checks that keep a bad file out of MODELS_DIR
# exist only once.
#
# Nothing here is macOS-specific except keeping MODELS_DIR out of Time
# Machine, which it skips elsewhere. Source this after
# config.sh/common.sh:
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
# like a model. A checksum mismatch deletes it and stops. Files are
# read-only; SHA256SUMS and SOURCES.tsv record each one's checksum,
# source, and (from Hugging Face) the repository's commit when downloaded.
#
# Only formats that can't run code when loaded are allowed: GGUF and
# safetensors, both just a header plus raw numbers. Pickle-based formats
# (PyTorch's .bin, .pt, .pth, and .ckpt, and plain .pkl) can run
# arbitrary code when loaded, so a URL with one of those extensions is
# refused before downloading, and every download's first bytes must show
# GGUF (the bytes "GGUF") or safetensors (an 8-byte header length, then
# the JSON header's "{"); anything else is deleted and stops the script.
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
    die "$fm_file doesn't match its SHA-256; deleted it."
  fi
  # The first 9 bytes as hex: 18 digits.
  case "$(head -c 9 "$MODELS_DIR/$fm_file.partial" | od -An -tx1 | tr -d ' \n')" in
    47475546*) ;;          # GGUF
    ????????????????7b) ;; # safetensors
    *)
      rm -f "$MODELS_DIR/$fm_file.partial"
      die "$fm_file is neither GGUF nor safetensors; deleted it."
      ;;
  esac
  chmod 444 "$MODELS_DIR/$fm_file.partial"
  mv -f "$MODELS_DIR/$fm_file.partial" "$MODELS_DIR/$fm_file"
  # Replace any older copy's records. File names have no spaces or tabs.
  touch "$MODELS_DIR/SHA256SUMS"
  awk -v f="$fm_file" '$2 != f' "$MODELS_DIR/SHA256SUMS" > "$MODELS_DIR/SHA256SUMS.new"
  mv "$MODELS_DIR/SHA256SUMS.new" "$MODELS_DIR/SHA256SUMS"
  awk -F '\t' -v f="$fm_file" '$1 != f' "$MODELS_DIR/SOURCES.tsv" > "$MODELS_DIR/SOURCES.tsv.new"
  mv "$MODELS_DIR/SOURCES.tsv.new" "$MODELS_DIR/SOURCES.tsv"
  printf '%s  %s\n' "$2" "$fm_file" >> "$MODELS_DIR/SHA256SUMS"
  printf '%s\t%s\t%s\t%s\t%s\n' "$fm_file" "$1" "$3" "$(date +%Y-%m-%d)" "$fm_commit" >> "$MODELS_DIR/SOURCES.tsv"
}
