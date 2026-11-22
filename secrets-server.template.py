#!/usr/bin/env python3
"""macOS Host Secrets Server.

Listens on the virtual bridge interface, looks up a named secret in
Keychain, and prompts for human approval before releasing it. Serves any
secret host-secrets.sh has stored, not just a single GitHub PAT: the
caller (vm-git-helper or any other VM-side script) names which secret it
wants via "secret_name" in the request payload; for vm-git-helper, that
name is baked into a git config credential.<url>.helper line by
vm-setup.sh from config.sh's GIT_SECRETS, so git itself has already
picked it before vm-git-helper ever runs.

Rendered from secrets-server.template.py by host-setup.sh: edit the
template, not the installed copy, since a re-run of host-setup.sh
overwrites this file.

Only secrets stored under Keychain's "@@KEYCHAIN_PREFIX@@" prefix are ever
served (see get_secret_from_keychain()). This is the entire access-control
list: there's no separate allowlist to maintain, so adding a new servable
secret is just "host-secrets.sh set <name>" on the host, nothing else. A
request for a name that was never stored under the prefix looks exactly
like "not found": denied by construction, not by a check that could be
forgotten.

A secret can also be locked to one specific VM by storing it under
"<name>@<vm-hostname>" (still under the KEYCHAIN_PREFIX) instead of the
plain "<name>": see resolve_vm_hostname() and _resolve(). The VM's
identity is resolved from the request's real network source IP
cross-referenced against `utmctl ip-address`, the same source of truth
host-setup.sh already uses for ~/.ssh/config, so no separate credential is
distributed to VMs to identify themselves.

Separately, a secret can be marked as releasable without a human
approval dialog by storing it under "<name>!" instead of "<name>" (the
two compose: "<name>@<vm-hostname>!" is both locked and dialog-free);
see needs_confirmation() and _resolve(). Every secret defaults to
requiring approval, so this only ever happens by deliberately choosing
that name at `host-secrets.sh set` time, and `host-secrets.sh list`
shows it directly, with nothing else to keep in sync. Only ever use this
for a secret that leaking does meaningfully no more harm than having no
secret at all (see GH_PUBLIC_TOKEN in rotate-github-pat.sh).

The approval dialog itself defaults to Deny the first time a given
session id shows up, and to Authorize once that session has had a prior
approval; see session_previously_approved(). This is tracked purely in
memory for this process's lifetime, not persisted anywhere: it's a
dialog-default convenience, not a security boundary (a missing or empty
session is still always denied outright, above), so there's nothing
wrong with forgetting it on every server restart.

Logs one JSON object per line to stdout (see log_event) for every request
this handles, approved/denied/errored, not just crashes. This exists
because of a real incident: the process was alive and correctly bound (the
actual cause turned out to be the VM's own egress firewall missing a rule
for this port; see nftables.template.conf), but the LaunchAgent's log
files sat empty the whole time regardless, which wasted real time
diagnosing "is it even receiving requests." Now every request leaves a
line, flushed immediately, whether or not anything goes wrong.

To test connectivity or the approval dialog itself without ever touching
the real secret, set "dry_run": true in a /secret request; see
_handle_secret_dry_run. This exists because of a second incident on the
same day: a raw curl test against a real request printed an actual token
in plaintext. dry_run makes that a non-issue by construction, not by
remembering to redact output: the server never reads the secret's value
out of Keychain at all when dry_run is set, so there's nothing to expose
regardless of how the response gets displayed.
"""
import json
import re
import socket
import subprocess
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = @@SECRETS_SERVER_PORT@@
KEYCHAIN_PREFIX = "@@KEYCHAIN_PREFIX@@"
UTMCTL = "@@UTMCTL@@"

# Session ids that have had at least one approval dialog actually clicked
# "Authorize" during this process's lifetime; see session_previously_approved().
# In-memory only, on purpose: this is just "have we seen a human approve
# something in this session before" for picking a dialog default, not a
# security boundary (BULKHEAD_AUTH_SESSION itself is that), so there's
# nothing worth persisting across a server restart. Guarded by a lock since
# ThreadingHTTPServer runs each request's dialog on its own thread.
_approved_sessions = set()
_approved_sessions_lock = threading.Lock()


def session_previously_approved(session_id: str) -> bool:
  with _approved_sessions_lock:
    return session_id in _approved_sessions


def mark_session_approved(session_id: str) -> None:
  with _approved_sessions_lock:
    _approved_sessions.add(session_id)


def log_event(level: str, event: str, **fields) -> None:
  """Writes one JSONL record to stdout and flushes immediately.

  The LaunchAgent redirects stdout to secrets-server.log with no terminal
  attached, and Python fully buffers stdout by default when it's not a
  tty, so lines can sit unwritten until the process exits. flush=True here
  is what makes a log line show up right away instead. Never pass a field
  containing the actual secret value; secret_name (which one was
  requested) is fine to log, the secret itself is not.
  """
  record = {
      "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
      "level": level,
      "event": event,
  }
  record.update(fields)
  print(json.dumps(record, sort_keys=True), flush=True)


def get_virtual_bridge_ip() -> str:
  """Scans macOS interfaces for UTM/Virtualization bridge adapters."""
  try:
    virtual_ifaces = [
        name
        for _, name in socket.if_nameindex()
        if name.startswith(("bridge", "vmnet", "vnic"))
    ]
    for iface in virtual_ifaces:
      out = subprocess.check_output(
          ["ifconfig", iface], text=True, stderr=subprocess.DEVNULL
      )
      match = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)", out)
      if match:
        return match.group(1)
  except Exception:
    pass
  return "127.0.0.1"


def enumerate_guests() -> list[tuple[str, str]]:
  """Lists (name, ip) for every currently-running guest VM, via UTM's
  utmctl (already installed with the app). Only lists VMs utmctl reports
  as "started" with a resolvable IP: a stopped VM has no guest agent to
  answer "ip-address" anyway. Returns [] if utmctl is missing or fails.
  This is the one place that knows how to ask the hypervisor which guests
  exist; a different hypervisor backend would only need to replace this
  function. See host-backend.sh's shell equivalent, used by host-setup.sh.
  """
  try:
    out = subprocess.check_output(
        [UTMCTL, "list"], text=True, stderr=subprocess.DEVNULL
    )
  except Exception:
    return []
  guests = []
  for line in out.splitlines()[1:]:
    fields = line.split()
    if len(fields) < 3 or fields[1] != "started":
      continue
    vm_name = fields[-1]
    try:
      ip_out = subprocess.check_output(
          [UTMCTL, "ip-address", vm_name], text=True, stderr=subprocess.DEVNULL
      )
    except Exception:
      continue
    lines = ip_out.strip().splitlines()
    if lines:
      guests.append((vm_name, lines[0].strip()))
  return guests


def resolve_vm_hostname(source_ip: str) -> str:
  """Maps a request's source IP to a running guest's name via
  enumerate_guests(): the same source of truth host-setup.sh already uses
  to build ~/.ssh/config, so there's no separate credential a guest needs
  to prove its own identity. Returns "" if no running guest's IP matches;
  callers then only try the unlocked secret name, exactly as if no
  guest-locked variant existed for this request. Re-enumerates on every
  call rather than caching: guests are few enough that the cost is
  negligible, and a DHCP lease can change between requests.
  """
  for vm_name, ip in enumerate_guests():
    if ip == source_ip:
      return vm_name
  return ""


def retrieve_secret(service_name: str) -> str:
  """Prints-equivalent: returns the secret stored under service_name in
  macOS Keychain, or "" if it's not stored. This, secret_exists(), and
  show_approval_prompt() below are this server's only OS-specific calls;
  see host-backend.sh's shell equivalent (used by host-secrets.sh) for the
  same idea in the other setup scripts.
  """
  try:
    return subprocess.check_output(
        [
            "security",
            "find-generic-password",
            "-s",
            service_name,
            "-w",
        ],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()
  except subprocess.CalledProcessError:
    return ""


def secret_exists(service_name: str) -> bool:
  return subprocess.run(
      ["security", "find-generic-password", "-s", service_name],
      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
  ).returncode == 0


def _resolve(name: str, vm_hostname: str, lookup):
  """Tries every combination of VM-locking and the "!" no-confirmation
  suffix that could apply to this request, most to least specific:
  "<name>@<vm>!", "<name>@<vm>", "<name>!", "<name>". Returns (result,
  needs_confirmation): result is whatever `lookup` returned for the
  first variant that matched (a falsy `lookup` result means "keep
  trying"); needs_confirmation is False only when the variant that
  matched ends in "!". If nothing matches, returns whatever the last
  (always-tried, unlocked, no-bang) lookup returned, paired with True -
  callers only ever look at needs_confirmation when result is truthy.

  This is the entire VM-locking mechanism and the entire
  no-confirmation mechanism, both at once: storing a secret under
  "name!" instead of "name" (there's no separate NO_APPROVAL_SECRETS
  list to keep in sync) is what marks it as needing no dialog, visible
  directly in "host-secrets.sh list". The two compose freely: "name@vm!"
  is both locked to one VM and confirmation-free. Parameterized on
  `lookup` so dry-run's keychain_secret_exists can share this without
  ever calling retrieve_secret, i.e. without ever reading a real secret's
  value.
  """
  candidates = [(f"{name}!", False), (name, True)]
  if vm_hostname:
    candidates = [(f"{name}@{vm_hostname}!", False),
                  (f"{name}@{vm_hostname}", True)] + candidates
  for variant, confirm in candidates:
    result = lookup(f"{KEYCHAIN_PREFIX}{variant}")
    if result:
      return result, confirm
  return result, True


def get_secret_from_keychain(name: str, vm_hostname: str) -> str:
  value, _ = _resolve(name, vm_hostname, retrieve_secret)
  return value


def keychain_secret_exists(name: str, vm_hostname: str) -> bool:
  """Like get_secret_from_keychain, but never reads the secret's value."""
  found, _ = _resolve(name, vm_hostname, secret_exists)
  return bool(found)


def needs_confirmation(name: str, vm_hostname: str) -> bool:
  """Whether releasing this secret needs a human approval dialog; see
  _resolve for what marks a secret as not needing one. Never reads the
  secret's value (see secret_exists). Doesn't affect the session
  check: a no-confirmation secret still requires a real
  BULKHEAD_AUTH_SESSION, only the human click is skipped.
  """
  _, confirm = _resolve(name, vm_hostname, secret_exists)
  return confirm


def _applescript_escape(s: str) -> str:
  """Escapes a string for safe embedding in an AppleScript string literal.

  repo_path/context_info/secret_name all come from the requesting VM (for
  git requests, context_info is derived from a commit message, which is
  attacker-influenceable if you ever clone something untrusted), so
  without this a crafted value could break out of the quoted string and
  run arbitrary AppleScript via osascript.
  """
  return s.replace("\\", "\\\\").replace('"', '\\"')


class SecretsRequestHandler(BaseHTTPRequestHandler):

  def do_POST(self):
    client_ip = self.client_address[0]
    log_event("info", "request_received", path=self.path, client=client_ip)

    if self.path != "/secret":
      log_event("warning", "unknown_path", path=self.path, client=client_ip)
      self.send_response(404)
      self.end_headers()
      return

    content_length = int(self.headers.get("Content-Length", 0))
    body = self.rfile.read(content_length)

    try:
      payload = json.loads(body.decode("utf-8"))
    except Exception as e:
      log_event(
          "warning", "secret_denied", reason="invalid_json",
          client=client_ip, detail=str(e),
      )
      self._respond({"status": "denied", "reason": "Invalid JSON"}, 400)
      return

    session_id = payload.get("session", "")
    repo_path = payload.get("path", "Unknown Path")
    context_info = payload.get("context", "No context given")
    secret_name = payload.get("secret_name", "")

    if not session_id:
      log_event(
          "warning", "secret_denied", reason="missing_session",
          client=client_ip, secret_name=secret_name,
      )
      self._respond(
          {"status": "denied", "reason": "Missing BULKHEAD_AUTH_SESSION"}, 403
      )
      return

    if not secret_name:
      log_event(
          "warning", "secret_denied", reason="missing_secret_name",
          client=client_ip,
      )
      self._respond(
          {"status": "denied", "reason": "Missing secret_name"}, 400
      )
      return

    vm_hostname = resolve_vm_hostname(client_ip)

    if "@" in secret_name or "!" in secret_name:
      # A well-behaved client only ever sends a plain logical name: both
      # the "@vm-hostname" suffix (a VM-locked Keychain entry) and the
      # "!" suffix (a no-confirmation entry; see _resolve) are
      # server-side details, never something a client supplies itself.
      # Without this check, a client could send "somename@othervm" or
      # "somename!" directly and the fallback lookup in _resolve would
      # treat that whole string as an opaque name and find it verbatim,
      # silently defeating VM-locking or the confirmation dialog. Always
      # denied either way, but this gets its own alert dialog (not the
      # normal approve/deny one) rather than looking like an ordinary
      # "not found," since it's either a misconfigured client or a
      # deliberate attempt to name another secret's locked or
      # no-confirmation variant directly, and a human should notice
      # regardless of which it turns out to be.
      log_event(
          "warning", "secret_denied", reason="secret_name_contains_at_or_bang",
          client=client_ip, vm=vm_hostname or "unknown",
          secret_name=secret_name,
      )
      self._show_alert_dialog(
          f"Secrets Server: suspicious request denied\n\n"
          f"From: {_applescript_escape(client_ip)} "
          f"(resolved VM: {_applescript_escape(vm_hostname or 'unknown')})\n"
          f"Requested secret name: {_applescript_escape(secret_name)}\n\n"
          f"Secret names containing \"@\" or \"!\" are never sent by a "
          f"normal client: this looks like a misconfigured script, or an "
          f"attempt to request another secret's locked or "
          f"no-confirmation variant directly. This request has already "
          f"been denied; no action needed unless you don't recognize it."
      )
      self._respond(
          {"status": "denied", "reason": "Invalid secret_name"}, 400
      )
      return

    dry_run = bool(payload.get("dry_run", False))
    if dry_run:
      self._handle_secret_dry_run(
          client_ip, vm_hostname, secret_name, session_id, repo_path,
          context_info,
      )
      return

    secret = get_secret_from_keychain(secret_name, vm_hostname)
    if not secret:
      log_event(
          "error", "secret_error", reason="keychain_secret_not_found",
          client=client_ip, vm=vm_hostname or "unknown", secret_name=secret_name,
      )
      self._respond(
          {"status": "error", "reason": "Keychain secret not found"}, 500
      )
      return

    new_session = not session_previously_approved(session_id)
    prompt_text = (
        f"Secrets Server Request\n\n"
        + (
            "NEW SESSION: no request from this session id has been "
            "approved yet this run.\n\n" if new_session else ""
        )
        + f"Secret: {_applescript_escape(secret_name)}\n"
        f"Requesting VM: {_applescript_escape(vm_hostname or 'unknown')}\n"
        f"Target Path: {_applescript_escape(repo_path)}\n"
        f"Local Context: {_applescript_escape(context_info)}\n"
        f"Session ID: {_applescript_escape(session_id[:8])}...\n\n"
        f"Authorize access for this operation?"
    )

    if needs_confirmation(secret_name, vm_hostname):
      log_event(
          "info", "secret_prompt_shown", client=client_ip,
          vm=vm_hostname or "unknown", secret_name=secret_name,
          session=session_id[:8], path=repo_path, new_session=new_session,
      )
      approved = self.show_approval_prompt(
          prompt_text, default_authorize=not new_session
      )
      if approved:
        mark_session_approved(session_id)
    else:
      log_event(
          "info", "secret_auto_approved", client=client_ip,
          vm=vm_hostname or "unknown", secret_name=secret_name,
          session=session_id[:8], path=repo_path,
      )
      approved = True

    if approved:
      log_event(
          "info", "secret_approved", client=client_ip,
          vm=vm_hostname or "unknown", secret_name=secret_name,
          session=session_id[:8],
      )
      self._respond({"status": "approved", "token": secret}, 200)
    else:
      log_event(
          "info", "secret_denied", reason="user_rejected", client=client_ip,
          vm=vm_hostname or "unknown", secret_name=secret_name,
          session=session_id[:8],
      )
      self._respond(
          {"status": "denied", "reason": "User rejected request"}, 403
      )

  def _handle_secret_dry_run(self, client_ip, vm_hostname, secret_name,
                              session_id, repo_path, context_info):
    """Exercises the full approval flow (Keychain lookup, dialog) without
    ever reading the secret's actual value; see keychain_secret_exists().
    The response has no "token" field either way, so there's nothing in it
    that could ever put a real secret in a terminal or a log by accident.
    This is the sanctioned way to test connectivity or the approval dialog:
    always set "dry_run": true rather than curling /secret directly with a
    real request; see the incident noted in git log around this file.
    """
    if not keychain_secret_exists(secret_name, vm_hostname):
      log_event(
          "error", "secret_error", reason="keychain_secret_not_found",
          client=client_ip, vm=vm_hostname or "unknown",
          secret_name=secret_name, dry_run=True,
      )
      self._respond(
          {
              "status": "error",
              "reason": "Keychain secret not found",
              "dry_run": True,
          },
          500,
      )
      return

    new_session = not session_previously_approved(session_id)
    prompt_text = (
        f"TEST REQUEST: dry run, no secret will be released\n\n"
        + (
            "NEW SESSION: no request from this session id has been "
            "approved yet this run.\n\n" if new_session else ""
        )
        + f"Secret: {_applescript_escape(secret_name)}\n"
        f"Requesting VM: {_applescript_escape(vm_hostname or 'unknown')}\n"
        f"Target Path: {_applescript_escape(repo_path)}\n"
        f"Local Context: {_applescript_escape(context_info)}\n"
        f"Session ID: {_applescript_escape(session_id[:8])}...\n\n"
        f"This only tests connectivity and this dialog; nothing is "
        f"released either way."
    )
    if needs_confirmation(secret_name, vm_hostname):
      log_event(
          "info", "secret_dry_run_prompt_shown", client=client_ip,
          vm=vm_hostname or "unknown", secret_name=secret_name,
          session=session_id[:8], path=repo_path, new_session=new_session,
      )
      approved = self.show_approval_prompt(
          prompt_text, title="Secrets Server Gatekeeper (TEST)",
          default_authorize=not new_session,
      )
      if approved:
        mark_session_approved(session_id)
    else:
      approved = True
    log_event(
        "info", "secret_dry_run_result", approved=approved, client=client_ip,
        vm=vm_hostname or "unknown", secret_name=secret_name,
        session=session_id[:8],
    )
    self._respond(
        {"status": "approved" if approved else "denied", "dry_run": True},
        200 if approved else 403,
    )

  def _run_dialog(self, applescript: str, stderr_event: str) -> str:
    """Runs one AppleScript "display dialog", returning its stdout (e.g.
    "button returned:Authorize"). Logs stderr_event if osascript itself
    produced stderr (a dialog that failed to display, not a real click).
    """
    res = subprocess.run(
        ["osascript", "-e", applescript], capture_output=True, text=True
    )
    if res.stderr.strip():
      log_event("warning", stderr_event, detail=res.stderr.strip())
    return res.stdout

  def show_approval_prompt(self, prompt_text: str,
                            title: str = "Secrets Server Gatekeeper",
                            default_authorize: bool = True) -> bool:
    """Shows the human-approval dialog via AppleScript/osascript: this and
    _show_alert_dialog below are this server's only other OS-specific call
    (besides retrieve_secret/secret_exists/enumerate_guests above); a
    different backend (a non-GUI host, say) would only need to replace
    this method. Only ever fires for a request with a live
    BULKHEAD_AUTH_SESSION, which compart claude strips before an AI agent gets
    near it, so this gates routine human operations, not an adversarial AI.

    default_authorize picks which button a bare Enter triggers: "Deny"
    the first time a given session id shows up (see
    session_previously_approved()), "Authorize" once that session has
    had a prior approval. A session id is generated fresh per human
    interactive shell (vm-bash-aliases-block.sh), so a first-time prompt
    defaulting to Deny means a moment's inattention doesn't rubber-stamp
    a session nobody's actually looked at yet; once you've approved
    anything in it, later prompts in that same shell go back to the
    quick-approve default.
    """
    default_button = "Authorize" if default_authorize else "Deny"
    applescript = (
        f'display dialog "{prompt_text}" with title'
        f' "{_applescript_escape(title)}"'
        f' buttons {{"Deny", "Authorize"}} default button "{default_button}"'
    )
    stdout = self._run_dialog(applescript, "approval_dialog_stderr")
    return "button returned:Authorize" in stdout

  def _show_alert_dialog(self, text: str) -> None:
    """Single-button alert for a request already denied as outright
    invalid (see secret_name_contains_at); not an approve/deny choice.
    """
    applescript = (
        f'display dialog "{text}" with title "Secrets Server Alert" '
        'buttons {"OK"} default button "OK"'
    )
    self._run_dialog(applescript, "alert_dialog_stderr")

  def _respond(self, data, code=200):
    self.send_response(code)
    self.send_header("Content-Type", "application/json")
    self.end_headers()
    self.wfile.write(json.dumps(data).encode("utf-8"))

  def log_message(self, format, *args):
    # Suppressed in favor of the explicit log_event calls above, which
    # carry more useful structure than BaseHTTPRequestHandler's default
    # access-log line.
    pass


class SecretsHTTPServer(ThreadingHTTPServer):
  # Each connection (each dialog) runs on its own thread, so one VM's
  # pending approval no longer makes a second, unrelated request queue
  # behind it. daemon_threads=True so a request thread stuck waiting on
  # an unanswered dialog can never block process shutdown (launchctl
  # stop/restart, Ctrl-C): the thread is simply abandoned when the main
  # process exits, same as it would be if left as an orphaned dialog
  # today.
  daemon_threads = True


def main():
  listen_host = get_virtual_bridge_ip()
  log_event("info", "startup", listen_host=listen_host, listen_port=LISTEN_PORT)
  server = SecretsHTTPServer((listen_host, LISTEN_PORT), SecretsRequestHandler)
  try:
    server.serve_forever()
  except KeyboardInterrupt:
    log_event("info", "shutdown", reason="keyboard_interrupt")


if __name__ == "__main__":
  main()
