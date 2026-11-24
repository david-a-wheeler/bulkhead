# compartment-sweep.py: sweep, from inside a compartment under nono, for
# anything it can reach or write that another compartment (or the VM)
# shares. tests/compartment-test.sh copies this into a scratch workspace
# and runs it there. It connects without sending anything, and the only
# files it makes are empty markers, which the test removes.
#
# Usage: python3 compartment-sweep.py OP ARG...
#   sockets LIST ALLOWED...
#       try each Unix socket path in file LIST (one per line, as listed
#       from outside); print "CONNECTS PATH" for each that connects and
#       isn't in ALLOWED, and "allowed PATH" for each that is. Lines
#       starting "@" are abstract names.
#   plant NAME WORKSPACE SKIP...
#       in each directory nono's capability file ($NONO_CAP_FILE) lets
#       us write, except in WORKSPACE and SKIP (shared on purpose), try
#       to create file NAME; print "planted PATH" for each one made.
#       The test then checks, from outside and from another
#       compartment, that none shows up where it shouldn't. This tests
#       what matters (what an agent writes stays in its compartment),
#       not how compartments do it.
#   seen LIST
#       print each path in file LIST that exists here.
#   key-hold NAME SECONDS
#       add a key named NAME to our session keyring, make sure we can
#       find it ourselves, print "held", hold it SECONDS seconds, and
#       remove it.
#   key-find NAME
#       print "found" if we can see a key named NAME, by /proc/keys or by
#       searching our keyrings; else "not found".
import json
import os
import socket
import sys


def under(path, top):
    return path == top or path.startswith(top.rstrip("/") + "/")


def sockets(listfile, allowed):
    with open(listfile) as f:
        paths = [line.rstrip("\n") for line in f if line.strip()]
    for path in paths:
        address = "\0" + path[1:] if path.startswith("@") else path
        for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM, socket.SOCK_SEQPACKET):
            s = socket.socket(socket.AF_UNIX, kind)
            try:
                s.settimeout(2)
                s.connect(address)
            except OSError:
                continue
            finally:
                s.close()
            print(("allowed " if path in allowed else "CONNECTS ") + path)
            break


def plant(name, workspace, skip):
    with open(os.environ["NONO_CAP_FILE"]) as f:
        caps = json.load(f)
    for grant in caps.get("fs", []):
        path = grant["path"]
        if grant.get("access") == "read" or grant.get("is_file") or not os.path.isdir(path):
            continue
        if under(path, workspace) or any(under(path, s) for s in skip):
            continue
        marker = os.path.join(path, name)
        try:
            with open(marker, "x"):
                pass
        except OSError:
            continue
        print("planted " + marker)


def seen(listfile):
    with open(listfile) as f:
        for line in f:
            path = line.rstrip("\n")
            if path and os.path.lexists(path):
                print(path)


KEYCTL = {"x86_64": 250, "aarch64": 219}
ADD_KEY = {"x86_64": 248, "aarch64": 217}
KEYCTL_SEARCH = 10
KEYCTL_UNLINK = 9
SESSION, USER = -3, -4


def libc():
    import ctypes
    return ctypes.CDLL(None, use_errno=True)


def key_search(c, name):
    import platform
    nr = KEYCTL[platform.machine()]
    return any(c.syscall(nr, KEYCTL_SEARCH, ring, b"user", name.encode(), 0) > 0
               for ring in (SESSION, USER))


def key_hold(name, seconds):
    import platform
    import time
    c = libc()
    key = c.syscall(ADD_KEY[platform.machine()], b"user", name.encode(), b"x", 1, SESSION)
    if key < 0:
        sys.exit("can't add a key")
    try:
        if not key_search(c, name):
            sys.exit("can't find our own key")
        print("held", flush=True)
        time.sleep(seconds)
    finally:
        c.syscall(KEYCTL[platform.machine()], KEYCTL_UNLINK, key, SESSION)


def key_find(name):
    try:
        with open("/proc/keys") as f:
            listed = any(name in line for line in f)
    except OSError:
        listed = False
    print("found" if listed or key_search(libc(), name) else "not found")


if __name__ == "__main__":
    op = sys.argv[1]
    if op == "sockets":
        sockets(sys.argv[2], set(sys.argv[3:]))
    elif op == "plant":
        plant(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif op == "seen":
        seen(sys.argv[2])
    elif op == "key-hold":
        key_hold(sys.argv[2], float(sys.argv[3]))
    elif op == "key-find":
        key_find(sys.argv[2])
    else:
        sys.exit("unknown op " + op)
