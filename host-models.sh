# shellcheck shell=sh
# host-models.sh: downloading local AI models into MODELS_DIR. Shared by
# host-setup.sh (every model in MODEL_DOWNLOADS) and add-model.sh (one new
# model), so the checks that keep a bad file out of MODELS_DIR exist only
# once.
#
# Host-only (macOS today). Source this after config.sh/common.sh:
#   . "$(dirname "$0")/host-models.sh"

# Usage: prepare_models_dir
# Creates MODELS_DIR (readable by everyone, so by MACOS_INFER_USER, but
# writable only by you), keeps it out of Time Machine, and starts
# SOURCES.tsv.
prepare_models_dir() {
  mkdir -p "$MODELS_DIR"
  chmod 755 "$MODELS_DIR"
  tmutil addexclusion "$MODELS_DIR"
  [ -f "$MODELS_DIR/SOURCES.tsv" ] ||
    printf 'file\tsource_url\tlicense\tadded\n' > "$MODELS_DIR/SOURCES.tsv"
}

# Usage: model_file <url> [<subdir>]
# Prints the model's path relative to MODELS_DIR. A multi-file model
# (e.g., an image model) names a subdirectory.
model_file() {
  printf '%s\n' "${2:+$2/}$(basename "$1")"
}

# Usage: download_model <url> <sha256> <license> [<subdir>]
# Downloads one model file into MODELS_DIR unless it's already there.
# It goes to FILE.partial first (rerunning resumes it), so an unfinished
# or wrong download never looks like a model. A checksum mismatch deletes
# it and stops. Files are read-only; SHA256SUMS and SOURCES.tsv record
# each one's checksum and source.
#
# Only formats that can't run code when loaded are allowed: GGUF and
# safetensors, both just a header plus raw numbers. Pickle-based formats
# (PyTorch's .bin, .pt, .pth, and .ckpt, and plain .pkl) can run
# arbitrary code when loaded, so a URL with one of those extensions is
# refused before downloading, and every download's first bytes must show
# GGUF (the bytes "GGUF") or safetensors (an 8-byte header length, then
# the JSON header's "{"); anything else is deleted and stops the script.
download_model() {
  dm_file="$(model_file "$1" "${4:-}")"
  [ -f "$MODELS_DIR/$dm_file" ] && return 0
  case "$dm_file" in
    *.bin | *.pt | *.pth | *.ckpt | *.pkl | *.pickle)
      die "$dm_file is a pickle-based format, which can run code when loaded; refusing to download it."
      ;;
  esac
  if [ -n "${4:-}" ]; then
    mkdir -p "$MODELS_DIR/$4"
    chmod 755 "$MODELS_DIR/$4"
  fi
  echo "Downloading $dm_file"
  curl -fL -C - -o "$MODELS_DIR/$dm_file.partial" "$1"
  if [ "$(shasum -a 256 "$MODELS_DIR/$dm_file.partial" | cut -d ' ' -f 1)" != "$2" ]; then
    rm -f "$MODELS_DIR/$dm_file.partial"
    die "$dm_file doesn't match its SHA-256; deleted it."
  fi
  # The first 9 bytes as hex: 18 digits.
  case "$(head -c 9 "$MODELS_DIR/$dm_file.partial" | od -An -tx1 | tr -d ' \n')" in
    47475546*) ;;          # GGUF
    ????????????????7b) ;; # safetensors
    *)
      rm -f "$MODELS_DIR/$dm_file.partial"
      die "$dm_file is neither GGUF nor safetensors; deleted it."
      ;;
  esac
  mv "$MODELS_DIR/$dm_file.partial" "$MODELS_DIR/$dm_file"
  chmod 444 "$MODELS_DIR/$dm_file"
  printf '%s  %s\n' "$2" "$dm_file" >> "$MODELS_DIR/SHA256SUMS"
  printf '%s\t%s\t%s\t%s\n' "$dm_file" "$1" "$3" "$(date +%Y-%m-%d)" >> "$MODELS_DIR/SOURCES.tsv"
}
