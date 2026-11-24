#!/usr/bin/env python3
"""Write one snapshot of a workspace's tracked files into a snapshot store.

Usage: snapshot-feed.py ROOT STORE REF MESSAGE_FILE CACHE_IN CACHE_OUT

bulkhead-snapshot runs this outside every sandbox; see snapshot-plan.md.
stdin is "git ls-files -s -z" from the workspace's repository: the paths
to save. We read each file as it is in ROOT now (not its index entry),
and feed "git fast-import" (run in the store) a root commit at REF,
with MESSAGE_FILE as its message. fast-import stores the bytes we give
it, so no repository's filters or attributes apply; it writes one pack,
and skips objects the store already has.

CACHE_IN (from the last snapshot, or /dev/null) holds each file's
inode, size, ctime, mtime, mode, and blob ID. A file whose stat matches
isn't read again; fast-import just references its blob. If every file
matches and no path was added or removed, nothing changed: we write
nothing and exit 3. Otherwise we write CACHE_OUT for this snapshot and
exit 0, or exit 1 on an error.

We open every path through directory file descriptors with O_NOFOLLOW,
so we never follow a symlink the agent planted in place of a directory
(such paths are skipped and counted). We save regular files and
symlinks, and skip anything else, including submodules (mode 160000).
"""

import hashlib
import os
import stat
import subprocess
import sys

CHUNK = 1 << 20


def quote(path):
    """Quote PATH (bytes) for fast-import if it needs it."""
    if b"\n" not in path and not path.startswith(b'"'):
        return path
    out = bytearray(b'"')
    for c in path:
        if c in (0x22, 0x5C):
            out += b"\\" + bytes([c])
        elif c < 0x20 or c == 0x7F:
            out += b"\\%03o" % c
        else:
            out.append(c)
    return bytes(out + b'"')


def read_cache(name):
    cache = {}
    with open(name, "rb") as f:
        data = f.read()
    for rec in data.split(b"\0"):
        if not rec:
            continue
        ino, size, ctime, mtime, mode, oid, path = rec.split(b" ", 6)
        cache[path] = ((int(ino), int(size), int(ctime), int(mtime), mode.decode()), oid.decode())
    return cache


def paths_from_index(data):
    seen = set()
    out = []
    for rec in data.split(b"\0"):
        if not rec:
            continue
        meta, path = rec.split(b"\t", 1)
        if meta.split(b" ", 1)[0] == b"160000" or path in seen:
            continue
        seen.add(path)
        out.append(path)
    return out


class Tree:
    """Open paths below ROOT without following symlinks."""

    def __init__(self, root):
        self.root = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        self.dirs = {b"": self.root}

    def dirfd(self, parent):
        """Return a descriptor for directory PARENT, or None."""
        if parent in self.dirs:
            return self.dirs[parent]
        head, _, name = parent.rpartition(b"/")
        up = self.dirfd(head)
        fd = None
        if up is not None:
            try:
                fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=up)
            except OSError:
                fd = None
        self.dirs[parent] = fd
        return fd


def key(st):
    if stat.S_ISLNK(st.st_mode):
        mode = "120000"
    elif stat.S_ISREG(st.st_mode):
        mode = "100755" if st.st_mode & stat.S_IXUSR else "100644"
    else:
        return None
    return (st.st_ino, st.st_size, st.st_ctime_ns, st.st_mtime_ns, mode)


def main():
    if len(sys.argv) != 7:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    root, store, ref, message_file, cache_in, cache_out = sys.argv[1:]
    paths = paths_from_index(sys.stdin.buffer.read())
    cache = read_cache(cache_in)
    tree = Tree(root)

    # First pass: stat everything, to see whether anything changed.
    entries = []  # (path, dirfd, name, key, cached blob ID or None)
    skipped = 0
    for path in paths:
        parent, _, name = path.rpartition(b"/")
        dfd = tree.dirfd(parent)
        if dfd is None:
            # A missing (deleted) directory is normal; one that's there
            # but that we can't open without following a symlink isn't.
            skipped += os.path.lexists(os.path.join(root.encode(), parent))
            continue
        try:
            st = os.lstat(name, dir_fd=dfd)
        except FileNotFoundError:
            continue
        k = key(st)
        if k is None:
            skipped += not stat.S_ISDIR(st.st_mode)
            continue
        hit = cache.get(path)
        entries.append((path, dfd, name, k, hit[1] if hit and hit[0] == k else None))
    if skipped:
        print(f"bulkhead-snapshot: didn't save {skipped} tracked path(s) below a symlink or of an odd type.", file=sys.stderr)
    if len(entries) == len(cache) and all(e[4] for e in entries):
        return 3

    with open(message_file, "rb") as f:
        message = f.read()
    proc = subprocess.Popen(["git", "--git-dir=" + store, "fast-import", "--quiet", "--done", "--date-format=now"], stdin=subprocess.PIPE)
    out = proc.stdin
    new_cache = []
    try:
        out.write(b"commit %s\n" % ref.encode())
        out.write(b"committer bulkhead-snapshot <bulkhead-snapshot> now\n")
        out.write(b"data %d\n%s\n" % (len(message), message))
        for path, dfd, name, k, oid in entries:
            if oid:
                out.write(b"M %s %s %s\n" % (k[4].encode(), oid.encode(), quote(path)))
                new_cache.append((path, k, oid))
                continue
            if k[4] == "120000":
                try:
                    data = os.readlink(name, dir_fd=dfd)
                except OSError:
                    continue
                h = hashlib.sha1(b"blob %d\0" % len(data))
                h.update(data)
                out.write(b"M 120000 inline %s\ndata %d\n%s\n" % (quote(path), len(data), data))
                new_cache.append((path, k, h.hexdigest()))
                continue
            try:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
            except OSError:
                continue
            with os.fdopen(fd, "rb") as f:
                st = os.fstat(f.fileno())
                k = key(st)
                if k is None or k[4] == "120000":
                    continue
                size = st.st_size
                h = hashlib.sha1(b"blob %d\0" % size)
                out.write(b"M %s inline %s\ndata %d\n" % (k[4].encode(), quote(path), size))
                # Send exactly SIZE bytes, even if the file changes meanwhile.
                left = size
                while left:
                    try:
                        chunk = f.read(min(left, CHUNK))
                    except OSError:
                        chunk = b""
                    if not chunk:
                        chunk = b"\0" * min(left, CHUNK)
                    h.update(chunk)
                    out.write(chunk)
                    left -= len(chunk)
                out.write(b"\n")
                new_cache.append((path, k, h.hexdigest()))
        out.write(b"\ndone\n")
        out.close()
    except BrokenPipeError:
        pass
    if proc.wait() != 0:
        print("bulkhead-snapshot: git fast-import failed.", file=sys.stderr)
        return 1
    with open(cache_out, "wb") as f:
        for path, k, oid in new_cache:
            f.write(b"%d %d %d %d %s %s %s\0" % (k[0], k[1], k[2], k[3], k[4].encode(), oid.encode(), path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
