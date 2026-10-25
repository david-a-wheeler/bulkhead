#!/usr/bin/env bash
# extract-chat-template.sh — extract the chat template embedded in a GGUF.
#
# Usage:
#   extract-chat-template.sh <file.gguf> [dest-dir]
#
# Reads the GGUF's tokenizer.chat_template metadata and writes it to
# <dest-dir>/<name>.chat-template.jinja, where <name> is the GGUF file
# name without its .gguf suffix (dest-dir defaults to the GGUF's own
# directory). Extracting from the file (rather than pasting jinja
# through a terminal) avoids transcription errors, and naming the
# output after its source makes it obvious which model a template
# came from when an entry points at it with --chat-template.
#
# Read-only on the GGUF; refuses to overwrite an existing output file.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $(basename "$0") <file.gguf> [dest-dir]" >&2
  exit 2
fi
SRC="$1"
if [[ ! -r "$SRC" ]]; then
  echo "cannot read $SRC" >&2
  exit 1
fi
DEST_DIR="${2:-$(dirname "$SRC")}"
mkdir -p "$DEST_DIR"
DST="$DEST_DIR/$(basename "${SRC%.gguf}").chat-template.jinja"
if [[ -e "$DST" ]]; then
  echo "refusing to overwrite existing $DST (remove it first to re-extract)" >&2
  exit 1
fi

python3 - "$SRC" "$DST" <<'PY'
import mmap, struct, sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

assert data[:4] == b"GGUF", "not a GGUF file"
_, _, n_kv = struct.unpack_from("<IQQ", data, 4)

FMTS = {0:1,1:1,2:2,3:2,4:4,5:4,6:4,7:1,10:8,11:8,12:8}

def get_string(off):
    (n,) = struct.unpack_from("<Q", data, off); off += 8
    if n > 100_000_000:
        raise ValueError(f"implausible string length {n}")
    return data[off:off+n].decode("utf-8", "replace"), off + n

def skip_value(off):
    (t,) = struct.unpack_from("<I", data, off); off += 4
    if t in FMTS:
        return off + FMTS[t]
    if t == 8:
        return get_string(off)[1]
    if t == 9:
        (et,) = struct.unpack_from("<I", data, off); off += 4
        (cnt,) = struct.unpack_from("<Q", data, off); off += 8
        if et in FMTS:
            return off + FMTS[et] * cnt
        if et == 8:
            for _ in range(cnt):
                off = get_string(off)[1]
            return off
        raise ValueError("nested array in metadata; not expected")
    raise ValueError(f"unknown value type {t}")

off = 24
template = None
for _ in range(n_kv):
    key, off = get_string(off)
    if key != "tokenizer.chat_template":
        off = skip_value(off)
        continue
    (t,) = struct.unpack_from("<I", data, off); off += 4
    if t != 8:
        raise SystemExit(f"tokenizer.chat_template has type {t}, expected string")
    template, off = get_string(off)
    break
if template is None:
    raise SystemExit(f"tokenizer.chat_template not found in {src}")
if not template.strip():
    raise SystemExit(f"tokenizer.chat_template in {src} is empty; not writing {dst}")

open(dst, "w").write(template)
print(f"wrote {dst} ({len(template)} chars)")
PY
