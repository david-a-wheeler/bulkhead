# make_tar_fixtures.py: writes the tarballs ci.sh checks
# unpacked_tree_ok (common.sh) with, into a new directory DIR: one like
# llama.cpp's (a directory, a file, and a version symlink beside it),
# then one per thing unpacked_tree_ok must refuse.
#   python3 -I tests/make_tar_fixtures.py DIR
import io
import os
import sys
import tarfile

out = sys.argv[1]
os.mkdir(out)
def tar(name, *members):
    with tarfile.open(os.path.join(out, name + ".tar.gz"), "w:gz") as t:
        for path, kind, target in members:
            m = tarfile.TarInfo(path)
            m.type = kind
            if kind == tarfile.DIRTYPE:
                m.mode = 0o755
            elif kind == tarfile.REGTYPE:
                m.size = len(b"x")
            elif target is not None:
                m.linkname = target
            t.addfile(m, io.BytesIO(b"x") if kind == tarfile.REGTYPE else None)
good = [("r/", tarfile.DIRTYPE, None), ("r/lib.0.dylib", tarfile.REGTYPE, None),
        ("r/lib.dylib", tarfile.SYMTYPE, "lib.0.dylib")]
tar("good", *good)
tar("bad-abs-link", *good, ("r/sd-server", tarfile.SYMTYPE, "/bin/sh"))
tar("bad-up-link", *good, ("r/up", tarfile.SYMTYPE, "../outside"))
tar("bad-dotdot-link", *good, ("r/up", tarfile.SYMTYPE, ".."))
tar("bad-subdir-link", *good, ("r/s", tarfile.SYMTYPE, "sub/x"))
tar("bad-hard-link", *good, ("r/h", tarfile.LNKTYPE, "r/lib.0.dylib"))
tar("bad-fifo", *good, ("r/p", tarfile.FIFOTYPE, None))
