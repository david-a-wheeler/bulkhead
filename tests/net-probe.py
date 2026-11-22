# net-probe.py: try one local network operation and print "ok" or
# "refused". tests/compartment-test.sh copies this into a scratch
# workspace and runs it under nono, to check what local sockets a
# workspace's agent can use.
#
# Usage: python3 net-probe.py OP [NAME]
#   connect22         connect to the VM's sshd on 127.0.0.1:22
#   connect PORT [HOST]
#                     connect to HOST (default 127.0.0.1) on PORT
#   see22             find a listener on port 22 in /proc/self/net
#   resolve NAME      look up host NAME
#   loopback          listen on 127.0.0.1 and connect to ourselves
#   abstract-listen   bind abstract socket NAME and hold it 6 seconds
#   abstract-connect  connect to abstract socket NAME
#   serve STOP ADDR:PORT...
#                     answer HTTP GETs on each ADDR:PORT with the
#                     client's address; print "ready" once all are
#                     bound, then serve until file STOP exists (or 60
#                     seconds pass)
import http.server
import os
import socket
import sys
import threading
import time


class EchoClient(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = self.client_address[0].encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


op = sys.argv[1]
try:
    if op == "connect22":
        s = socket.socket()
        s.settimeout(2)
        s.connect(("127.0.0.1", 22))
    elif op == "connect":
        s = socket.socket()
        s.settimeout(2)
        host = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"
        s.connect((host, int(sys.argv[2])))
    elif op == "see22":
        # Field 2 is local address:port in hex; state 0A is LISTEN.
        found = False
        for f in ("/proc/self/net/tcp", "/proc/self/net/tcp6"):
            with open(f) as lines:
                for line in list(lines)[1:]:
                    fields = line.split()
                    if fields[1].endswith(":0016") and fields[3] == "0A":
                        found = True
        if not found:
            raise OSError("no listener on port 22")
    elif op == "resolve":
        socket.getaddrinfo(sys.argv[2], 443)
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
    elif op == "serve":
        for spec in sys.argv[3:]:
            addr, port = spec.rsplit(":", 1)
            server = http.server.ThreadingHTTPServer((addr, int(port)), EchoClient)
            threading.Thread(target=server.serve_forever, daemon=True).start()
        print("ready", flush=True)
        deadline = time.monotonic() + 60
        while not os.path.exists(sys.argv[2]) and time.monotonic() < deadline:
            time.sleep(0.2)
        sys.exit(0)
    else:
        sys.exit("net-probe.py: unknown operation: " + op)
    print("ok")
except OSError:  # socket.gaierror is an OSError too
    print("refused")
