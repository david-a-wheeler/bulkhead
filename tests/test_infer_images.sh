#!/bin/sh
# test_infer_images.sh: run infer-images.js (the pi extension) with node,
# a stand-in for pi's registerProvider, and a stand-in engine on
# localhost: it must register only the image models from INFER_MODELS
# (and none without it), send the key and the prompt's text to
# /v1/images/generations, or with input images, a form to
# /v1/images/edits; return the PNG; and report a bad key or an answer
# without an image as an error. Run by ci.sh.
set -eu

TESTS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS/.." && pwd)"
mkdir -p "$REPO/.tmp"
work="$(mktemp -d "$REPO/.tmp/test-infer-images.XXXXXX")"
engine=""
trap '[ -z "$engine" ] || kill "$engine"; rm -rf "${work:?}"' EXIT

# The engine: checks the key, logs each request (a form as its fields,
# each file as its name, type, and contents), and answers with a 1x1
# PNG, or no image for the model "empty". It writes its port once it's
# listening.
cat > "$work/engine.py" <<'EOF'
import email.parser, email.policy, json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgAAAAAgABVKJPXQAAAABJRU5ErkJggg=="
class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers["Content-Type"] == "application/json":
            body = json.loads(data)
        else:
            form = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
                b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + data)
            body = {}
            for part in form.iter_parts():
                name = part.get_param("name", header="content-disposition")
                value = part.get_content()
                if part.get_filename():
                    value = [part.get_filename(), part.get_content_type(), value.decode()]
                body.setdefault(name, []).append(value)
        with open(sys.argv[1] + "/requests.log", "a") as log:
            log.write(json.dumps([self.path, self.headers["Authorization"], body]) + "\n")
        if self.headers["Authorization"] != "Bearer sk-test":
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"bad key")
            return
        model = body["model"] if isinstance(body["model"], str) else body["model"][0]
        reply = json.dumps({"data": [] if model == "empty" else [{"b64_json": PNG}]}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(reply)
    def log_message(self, *args):
        pass
server = HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1] + "/port", "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
EOF
python3 -I "$work/engine.py" "$work" &
engine=$!
i=0
while [ ! -s "$work/port" ] && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
url="http://127.0.0.1:$(cat "$work/port")/v1"

# Loads the extension with a stand-in pi, and prints what it registered
# and what four requests gave: an image, an edit of two, a bad key, and
# no image.
cp "$REPO/infer-images.js" "$work/infer-images.mjs"
cat > "$work/run.mjs" <<'EOF'
const ext = await import(process.argv[2]);
let provider;
ext.default({ registerProvider: (name, config) => { provider = { name, config }; } });
if (!provider) {
  console.log("none");
  process.exit(0);
}
const { name, config } = provider;
console.log(JSON.stringify([name, config.apiKey, config.models.map((m) => [m.type, m.id, m.baseUrl, m.input, m.output])]));
const generate = Object.values(config.images)[0].generateImages;
const text = [{ type: "text", text: "a red" }, { type: "text", text: "apple" }];
const b64 = (s) => Buffer.from(s).toString("base64");
const edit = [{ type: "text", text: "make it green" }, { type: "image", data: b64("PNG one"), mimeType: "image/png" },
  { type: "image", data: b64("JPEG two"), mimeType: "image/jpeg" }];
for (const [id, apiKey, input] of [["flux", "sk-test", text], ["flux", "sk-test", edit], ["flux", "wrong", text], ["empty", "sk-test", text]]) {
  const r = await generate({ ...config.models[0], id, provider: name }, { input }, { apiKey });
  console.log(JSON.stringify([id, r.stopReason, r.errorMessage ?? null, r.output.map((b) => [b.type, b.mimeType])]));
}
EOF
listing="$(jq -nc --arg url "$url" '{url: $url, default: "q", models: [
  {id: "q", name: "Q", variant_of: null, context: 1, max_tokens: 1, input: ["text", "image"], output: ["text"]},
  {id: "flux", name: "Flux", variant_of: null, context: null, max_tokens: null, input: ["text"], output: ["image"]}]}')"
got="$(INFER_MODELS="$listing" node "$work/run.mjs" "$work/infer-images.mjs")"
# shellcheck disable=SC2016 # a literal $INFER_API_KEY, which pi resolves
want='["mac-local-images","$INFER_API_KEY",[["image","flux","'"$url"'",["text","image"],["image"]]]]
["flux","stop",null,[["image","image/png"]]]
["flux","stop",null,[["image","image/png"]]]
["flux","error","Error: HTTP 401: bad key",[]]
["empty","error","Error: the engine returned no image",[]]'
fail=0
if [ "$got" != "$want" ]; then
  printf 'FAILED: infer-images.js gave\n%s\nnot\n%s\n' "$got" "$want" >&2
  fail=1
fi
got="$(head -n 2 "$work/requests.log")"
want='["/v1/images/generations", "Bearer sk-test", {"model": "flux", "prompt": "a red\napple"}]
["/v1/images/edits", "Bearer sk-test", {"model": ["flux"], "prompt": ["make it green"], "image[]": [["0.png", "image/png", "PNG one"], ["1.jpeg", "image/jpeg", "JPEG two"]]}]'
if [ "$got" != "$want" ]; then
  printf 'FAILED: infer-images.js sent %s, not %s\n' "$got" "$want" >&2
  fail=1
fi
for bad in "" "not JSON" "$(printf '%s' "$listing" | jq -c '.models |= map(select(.id == "q"))')"; do
  got="$(INFER_MODELS="$bad" node "$work/run.mjs" "$work/infer-images.mjs")"
  [ "$got" = none ] || { echo "FAILED: infer-images.js registered models from '$bad'" >&2; fail=1; }
done
[ "$fail" -eq 0 ] && echo "infer-images.js: all checks passed."
exit "$fail"
