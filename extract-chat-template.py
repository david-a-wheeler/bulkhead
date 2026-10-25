#!/usr/bin/env python3
# extract-chat-template.py: extract the chat template embedded in a GGUF.
#
# Usage:
#   extract-chat-template.py <file.gguf> [dest-dir]
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
# Run as a script, Python looks for modules in this script's directory,
# not the current one, so a planted module where you run it isn't loaded.

import mmap
import os
import struct
import sys

# Sizes of GGUF's fixed-size value types, by type number.
FMTS = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}


def get_string(data, off):
    (n,) = struct.unpack_from("<Q", data, off)
    off += 8
    if n > 100_000_000:
        raise ValueError(f"implausible string length {n}")
    return data[off:off + n].decode("utf-8", "replace"), off + n


def skip_value(data, off):
    (t,) = struct.unpack_from("<I", data, off)
    off += 4
    if t in FMTS:
        return off + FMTS[t]
    if t == 8:
        return get_string(data, off)[1]
    if t == 9:
        (et,) = struct.unpack_from("<I", data, off)
        off += 4
        (cnt,) = struct.unpack_from("<Q", data, off)
        off += 8
        if et in FMTS:
            return off + FMTS[et] * cnt
        if et == 8:
            for _ in range(cnt):
                off = get_string(data, off)[1]
            return off
        raise ValueError("nested array in metadata; not expected")
    raise ValueError(f"unknown value type {t}")


def chat_template(src):
    with open(src, "rb") as f:
        data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    if data[:4] != b"GGUF":
        sys.exit(f"{src} is not a GGUF file")
    _, _, n_kv = struct.unpack_from("<IQQ", data, 4)
    off = 24
    for _ in range(n_kv):
        key, off = get_string(data, off)
        if key != "tokenizer.chat_template":
            off = skip_value(data, off)
            continue
        (t,) = struct.unpack_from("<I", data, off)
        if t != 8:
            sys.exit(f"tokenizer.chat_template has type {t}, expected string")
        return get_string(data, off + 4)[0]
    sys.exit(f"tokenizer.chat_template not found in {src}")


def main():
    if not 2 <= len(sys.argv) <= 3:
        print(f"usage: {os.path.basename(sys.argv[0])} <file.gguf> [dest-dir]", file=sys.stderr)
        sys.exit(2)
    src = sys.argv[1]
    if not os.access(src, os.R_OK):
        sys.exit(f"cannot read {src}")
    dest_dir = sys.argv[2] if len(sys.argv) == 3 else os.path.dirname(src) or "."
    name = os.path.basename(src)
    if name.endswith(".gguf"):
        name = name[:-len(".gguf")]
    dst = os.path.join(dest_dir, name + ".chat-template.jinja")
    if os.path.exists(dst):
        sys.exit(f"refusing to overwrite existing {dst} (remove it first to re-extract)")
    template = chat_template(src)
    if not template.strip():
        sys.exit(f"tokenizer.chat_template in {src} is empty; not writing {dst}")
    os.makedirs(dest_dir, exist_ok=True)
    # "x" so a file that appeared since the check above isn't overwritten.
    with open(dst, "x") as f:
        f.write(template)
    print(f"wrote {dst} ({len(template)} chars)")
    # --chat-template takes the template text itself (or a built-in
    # name); only --chat-template-file takes a path, so say that one.
    print(f"point llama-server at it with: --jinja --chat-template-file {dst}")


if __name__ == "__main__":
    main()
