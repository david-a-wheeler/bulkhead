#!/bin/sh
# add-vision-once.sh: a one-time fix for a host whose models.local.yaml
# predates qwen3.8-27b's vision projector (added to initial-models.yaml
# on 2026-10-22). It adds the projector to qwen3.8-27b's entry, as
# initial-models.yaml now has it, downloads it (about 0.9 GB; nothing
# else is downloaded again), and has the engine serve the result. It
# keeps the old list as models.local.yaml.pre-vision. Run it once on the
# Mac, then delete it.
#
# Usage: ./add-vision-once.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/host-models.sh"

MM="$SCRIPT_DIR/manage-models.sh"
trap 'rm -f "${INFER_MODELS:?}.new"' EXIT
FILE_LINE='    # file: qwen3.8-27b/mmproj-F16.gguf cbb841a9ee0636b2ec172f5bb8df2ea8dfeb01e90fe7c6126581d662a0b4e43e apache-2.0 https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/mmproj-F16.gguf'
# shellcheck disable=SC2016 # literal macros
OLD_CMD='    cmd: ${llama-server} --model ${models-dir}/Qwen3.8-27B-Q8_0.gguf '
# shellcheck disable=SC2016 # literal macros
NEW_CMD='    cmd: ${llama-server} --model ${models-dir}/Qwen3.8-27B-Q8_0.gguf --mmproj ${models-dir}/qwen3.8-27b/mmproj-F16.gguf '

if [ ! -f "$INFER_MODELS" ]; then
  echo "There's no models.local.yaml yet, so the new initial list (with vision) will be used."
elif grep -q -- '--mmproj' "$INFER_MODELS"; then
  echo "models.local.yaml already uses a vision projector; leaving it as it is."
else
  # In qwen3.8-27b's entry: add the file line, add --mmproj to the cmd,
  # and say it takes images (replacing any capabilities.in or .out).
  FILE_LINE="$FILE_LINE" OLD_CMD="$OLD_CMD" NEW_CMD="$NEW_CMD" awk '
    BEGIN { old = ENVIRON["OLD_CMD"] }
    /^  [^ #]/ { inside = ($0 == "  qwen3.8-27b:"); section = "" }
    inside && /^    [^ #]/ { section = $1 }
    inside && $0 == "  qwen3.8-27b:" { print; print ENVIRON["FILE_LINE"]; files++; next }
    inside && index($0, old) == 1 {
      print ENVIRON["NEW_CMD"] substr($0, length(old) + 1); cmds++; next
    }
    inside && section == "capabilities:" && /^      (in|out):/ { next }
    inside && $0 == "    capabilities:" {
      print; print "      in: [text, image]"; print "      out: [text]"; caps++; next
    }
    { print }
    END { if (files != 1 || cmds != 1 || caps != 1) exit 1 }
  ' "$INFER_MODELS" > "$INFER_MODELS.new" ||
    die "qwen3.8-27b's entry in models.local.yaml isn't the one initial-models.yaml started it with (it needs its cmd and a capabilities section); add the projector by hand, as initial-models.yaml does."
  infer_models_ok "$INFER_MODELS.new" ||
    die "the changed list breaks the rules (above); models.local.yaml is unchanged."
  cp "$INFER_MODELS" "$INFER_MODELS.pre-vision"
  mv "$INFER_MODELS.new" "$INFER_MODELS"
  echo "Added the vision projector to qwen3.8-27b; the old list is models.local.yaml.pre-vision."
fi

"$MM" sync
"$MM" check
"$SCRIPT_DIR/install-models.sh"
echo "Done. Now rerun ./vm-setup.sh on each VM, so pi sends qwen3.8-27b"
echo "images, and then you can delete add-vision-once.sh."
