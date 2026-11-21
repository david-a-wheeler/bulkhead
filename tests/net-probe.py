# net-probe.py: try one local network operation and print "ok" or
# "refused". tests/compartment-test.sh copies this into a scratch
# workspace and runs it under nono, to check that a workspace's agent
# gets its own loopback and abstract Unix sockets.
#
# Usage: python3 net-probe.py OP [NAME]
#   connect22         connect to the VM's sshd on 127.0.0.1:22
#   loopback          listen on 127.0.0.1 and connect to ourselves
#   abstract-listen   bind abstract socket NAME and hold it 6 seconds
#   abstract-connect  connect to abstract socket NAME
import socket
import sys
import time

op = sys.argv[1]
try:
    if op == "connect22":
        s = socket.socket()
        s.settimeout(2)
        s.connect(("127.0.0.1", 22))
    elif op == "loopback":
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen()
        client = socket.socket()
        client.settimeout(2)
        client.connect(server.getsockname())
    elif op == "abstract-listen":
        server = socket.socket(socket.AF_UNIX)
        server.bind("\0" + sys.argv[2])
        server.listen()
        print("ok", flush=True)
        time.sleep(6)
        sys.exit(0)
    elif op == "abstract-connect":
        client = socket.socket(socket.AF_UNIX)
        client.settimeout(2)
        client.connect("\0" + sys.argv[2])
    else:
        sys.exit("net-probe.py: unknown operation: " + op)
    print("ok")
except OSError:
    print("refused")
