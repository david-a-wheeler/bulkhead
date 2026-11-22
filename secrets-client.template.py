#!/usr/bin/env python3
"""VM-side generic secrets-server client: fetch one named secret from
secrets-server.py on the macOS host, then either print it or run a
command with it set in the environment. Installed without a ".py"
extension (secrets-client), matching every other CLI tool this repo
installs; callers shouldn't need to remember this happens to be Python.

Usage:
  secrets-client [--as ENV_NAME] [--context TEXT] NAME [COMMAND...]
    Fetches NAME, sets env var NAME (or ENV_NAME, if --as is given) to
    it, and execs COMMAND (default: $SHELL) as a *child* process with
    that var set only there; this process is replaced by it, so nothing
    ever holds the secret afterward. Meant for a burst of commands
    against whatever NAME authenticates: run with no COMMAND, use the
    tool normally, exit the shell, and the secret is gone from every
    live process again, with no separate cleanup step. Default
    --context is COMMAND itself (or $SHELL, when COMMAND is omitted),
    since that's what's actually about to happen; override it when
    that's not descriptive enough on its own (see vm-git-helper's
    git-commit-summary context).
  secrets-client --get [--context TEXT] NAME
    Prints the secret to stdout instead of running anything. No COMMAND.

Every flag must come before NAME: everything after NAME is COMMAND,
verbatim, whether or not it looks like a flag (so e.g. a "--context"
typed after NAME becomes part of COMMAND, not this program's own
option).

"name" is always the short logical name (e.g. "GH_TOKEN",
"HEROKU_API_KEY", spelled like the environment variable it stands in
for wherever one exists); secrets-server.py applies KEYCHAIN_PREFIX and
any VM-lock/no-confirmation suffix itself - never send one of those
suffixes here directly, see secrets-server.template.py's _resolve().

Requires BULKHEAD_AUTH_SESSION to be set (see
vm-bash-aliases-block.sh, which generates one for every human
interactive shell). Without it, the server denies the request without
ever consulting Keychain, same as any other caller. compart claude strips it
before an AI agent ever runs, so a sandboxed agent can never use this
to reach a real secret either.

Rendered from secrets-client.template.py by vm-setup.sh: edit the
template, not the installed copy (secrets-client, no ".py"), since a
re-run of vm-setup.sh overwrites this file.
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

SECRETS_SERVER_PORT = @@SECRETS_SERVER_PORT@@


def get_default_gateway() -> str:
  try:
    return subprocess.check_output(
        "ip route | awk '/default/ {print $3}'", shell=True, text=True
    ).strip()
  except Exception:
    return "192.168.64.1"


def fetch_secret(name: str, context: str) -> str:
  """Requests `name` from secrets-server.py; returns the token on
  success. Prints an error to stderr and exits nonzero on denial, not
  found, or unreachable.
  """
  payload = {
      "session": os.environ.get("BULKHEAD_AUTH_SESSION", ""),
      "path": os.getcwd(),
      "context": context,
      "secret_name": name,
  }

  host_ip = get_default_gateway()
  server_url = f"http://{host_ip}:{SECRETS_SERVER_PORT}/secret"

  req = urllib.request.Request(
      server_url,
      data=json.dumps(payload).encode("utf-8"),
      headers={"Content-Type": "application/json"},
  )

  try:
    with urllib.request.urlopen(req, timeout=30) as resp:
      result = json.loads(resp.read().decode("utf-8"))
  except urllib.error.HTTPError as e:
    try:
      result = json.loads(e.read().decode("utf-8"))
    except Exception:
      result = {}
    print(f"secrets-client: {result.get('reason', f'HTTP {e.code}')}", file=sys.stderr)
    sys.exit(1)
  except Exception as e:
    print(f"secrets-client: couldn't reach the secrets server: {e}", file=sys.stderr)
    sys.exit(1)

  if result.get("status") == "approved" and "token" in result:
    return result["token"]
  print(f"secrets-client: {result.get('reason', 'denied')}", file=sys.stderr)
  sys.exit(1)


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  mode = parser.add_mutually_exclusive_group()
  mode.add_argument(
      "--get", action="store_true",
      help="print the secret to stdout instead of running a command",
  )
  mode.add_argument(
      "--as", dest="as_name", metavar="ENV_NAME",
      help="set the secret under ENV_NAME instead of NAME",
  )
  parser.add_argument(
      "--context",
      help="shown to the human in the approval dialog (default: COMMAND, or $SHELL)",
  )
  parser.add_argument("name", help="short logical secret name, e.g. GH_TOKEN")
  parser.add_argument(
      "command", nargs=argparse.REMAINDER,
      help="command to run with the secret set (default: $SHELL)",
  )
  args = parser.parse_args()

  if args.get and args.command:
    parser.error("--get prints to stdout; it doesn't run a command")

  if args.get:
    print(fetch_secret(args.name, args.context or "get"))
    return

  command = args.command or [os.environ.get("SHELL", "/bin/sh")]
  token = fetch_secret(args.name, args.context or " ".join(command))
  os.environ[args.as_name or args.name] = token
  try:
    os.execvp(command[0], command)
  except FileNotFoundError:
    print(f"secrets-client: {command[0]}: command not found", file=sys.stderr)
    sys.exit(127)


if __name__ == "__main__":
  main()
