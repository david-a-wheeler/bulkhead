# GUIs in compartments: what we know, and options

Status (2026-11-24): notes only; nothing here is built. We paused
bulkhead work here, so this records what we learned so far, to pick up
later. The VMs run GNOME 50 on Wayland, with Xwayland (`DISPLAY=:0`).

## Why GUIs don't work in a compartment today

1. **Snaps don't start.** `/snap/bin/firefox` and `/snap/bin/chromium`
   run `snap-confine`, which needs file capabilities; nono sets
   `no_new_privs`, so the kernel never grants them. Ubuntu's Firefox
   and Chromium are both snaps. (The binaries themselves can still
   run; see "Running the Chromium snap without snap" below.)
2. **There's no display.** A compartment has its own `/run`, so
   `$XDG_RUNTIME_DIR/wayland-0` isn't there, and nono's socket
   mediation would refuse it anyway. X11 is blocked too, and that's
   good: `/tmp` is private, and Xwayland's abstract socket is in the
   VM's network namespace, not the compartment's (pasta's). X11 would
   let any client log keystrokes and capture other windows.
3. **HTTPS fails.** nono's proxy decrypts HTTPS (that's how it filters
   by method) with a CA it makes for each session, and points programs
   at it with `SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`,
   and `REQUESTS_CA_BUNDLE`. Browsers ignore those: Chromium (and
   Electron) use an NSS database (`~/.pki/nssdb`), and Firefox its
   profile's own store (or a `policies.json`). Since the CA is new each
   session, it has to be added inside the sandbox, after nono starts,
   e.g., `certutil -d sql:$HOME/.pki/nssdb -A -t C,, -n nono -i
   "$SSL_CERT_FILE"` (from `libnss3-tools`) in a small launcher.
4. **The proxy wants a login.** nono gives the proxy's credentials in
   `HTTPS_PROXY` (`http://USER:PASS@127.0.0.1:PORT`). Chromium's
   `--proxy-server` takes no credentials, and would ask for them in a
   dialog, which a driven browser (chromedriver, Playwright) can't
   answer; Firefox doesn't take them from the URL either. Options: check
   whether nono's proxy can run without its login for one session, or
   run a tiny forwarder in the compartment (on its own loopback) that
   adds the `Proxy-Authorization` header.
5. **The browser's own sandbox.** Chromium's needs a setuid helper or
   user namespaces; under `no_new_privs` and Ubuntu's AppArmor limits
   on user namespaces, use `--no-sandbox`, and let the compartment and
   nono confine it.
6. **No D-Bus.** Portals (e.g., file dialogs), notifications,
   accessibility, and dconf fail; most apps fall back or just warn
   (`GSETTINGS_BACKEND=memory` quiets dconf).
7. **No GPU.** `/dev` is minimal, so rendering is in software: fine for
   a browser.

## What a display would expose

Wayland is much safer than X11 (no keylogging, no capturing other
windows), but a compartment given the real compositor socket could
still read what you've copied (e.g., a password) whenever its window
has focus, set the clipboard (e.g., to a command you'd then paste into
a terminal), draw look-alike windows (e.g., a fake password prompt),
pass data to another compartment through the clipboard, and reach the
compositor, which runs as you, outside any sandbox. Flatpak narrows
this with Wayland's security-context protocol; I don't know whether
GNOME supports it yet.

## Options, most isolated first

1. **Headless, for agents.** Most agent browsing needs no display:
   headless Chromium (`--headless=new`), with chromedriver or
   Playwright. It still needs 1 and 3 to 5, but nothing from the
   display. Start here for an agent's browser tool.
2. **A display that's only pixels (VNC), for GUIs you watch or use.**
   Run an X server that's also a VNC server inside the compartment
   (TigerVNC's `Xvnc`, from `tigervnc-standalone-server`), and view it
   with a VNC client running as you (GNOME's Connections, Remmina, or
   `vncviewer`) through an exposed port (`expose-ports`). It's fully
   interactive (your keyboard and mouse go to the app), but only pixels
   and input cross: no clipboard unless you turn on the viewer's
   clipboard sharing, no drag and drop, and some key combinations may go
   to GNOME instead. Latency is unnoticeable, since it's all on the VM's
   loopback. **This is the one to try first.**
3. **A nested compositor** (e.g., `cage` or `weston` as a client of
   GNOME), giving the compartment only the nested compositor's socket.
   Nearly native, and it decides whether the clipboard crosses; more
   parts to get right than 2.
4. **The real Wayland socket.** Most convenient, least isolated (see
   above); only for apps you trust more than agents.

In every option, the browser's profile must be the compartment's own and
start fresh, never your real one, with its logins and cookies.

## Running the Chromium snap without snap

The OpenSSF Best Practices badge project's `snap-chromium-bp-badge`
(MIT; a copy is in this workspace as `,snap-chromium-bp-badge`)
already runs the snap's Chromium, and its chromedriver, under nono. What it shows:

- Run the snap's ELF binaries directly
  (`/snap/chromium/current/usr/lib/chromium-browser/chrome` and
  `chromedriver`) with the VM's own loader and glibc, which must be at
  least as new as the snap's base (core24 has 2.39; our VMs have 2.43).
- Set `LD_LIBRARY_PATH` to the snap's own libraries plus those of the
  content snaps it would have mounted (its GNOME platform and GPU
  snaps), read from the snap's `meta/snap.yaml` instead of hard-coded,
  since their names change with each base.
- Read a file to test access (`head -c 1`), not `[ -r ]`: `access(2)`
  isn't restricted by Land&#108;ock, so `[ -r ]` can say yes when a read
  would be refused. (We hit the same trap here.)
- Flags: `--no-sandbox` (see 5) and `--disable-dev-shm-usage` (it uses
  `$TMPDIR` if `/dev/shm` is refused; compartments now have their own
  `/dev/shm`, so it may be unneeded, but it's harmless). chromedriver
  ignores flags it doesn't know and passes its environment on, so one
  wrapper serves both.
- `GSETTINGS_BACKEND=memory`, and `XDG_CONFIG_HOME` and `XDG_CACHE_HOME`
  kept away from a real browser profile. In a compartment, I'd rather
  make `~/.config/chromium` (and `~/.pki`, for the CA) private in
  `compartment-paths`.
- Chromium reads `/sys/bus/pci` (through libpci, which exits the whole
  process if it can't), and needs `/etc/fonts` and `/snap`.
  `bulkhead-claude` grants all three read-only; check the others
  (e.g., `bulkhead-sh`) with `nono profile show`.

## A first experiment, when we pick this up

1. `vm-setup.sh` installs `tigervnc-standalone-server` and
   `libnss3-tools`, and a root-owned copy of a Chromium wrapper adapted
   from `snap-chromium-bp-badge`.
2. In a scratch workspace, list a port (e.g., 5901) in
   `$(compart dossier)/policy/expose-ports`.
3. In `compart sh`: start `Xvnc :1 -rfbport 5901 -localhost
   -SecurityTypes VncAuth -PasswordFile FILE`, add nono's CA to
   `~/.pki/nssdb`, then run the wrapper with `DISPLAY=:1`,
   `--proxy-server` (see 4 for the login), and `--window-size` (there's
   no window manager; one can come later).
4. From your own desktop, connect a VNC client to `127.0.0.1:5901`.

Open questions for that experiment:

- Proxy login (4): does nono's proxy have an option for it, or do we
  need the forwarder?
- Can Chromium connect to `Xvnc` in a compartment? Under nono's socket
  mediation, abstract sockets are refused; X clients try the abstract
  socket first, then the pathname one in `/tmp/.X11-unix`, which nono
  must allow (compartments' `/tmp` allows binding sockets in it).
- The VNC password: `compart` could make one per session in the
  dossier and give it to your viewer. An agent can read it, but it
  already controls that display; what matters is that other
  compartments can't reach the port (tested) and your other processes
  need the password.
- An agent controls what that display shows, so treat anything in it as
  the agent's (e.g., a login page there may be fake).
- GUI harnesses such as goose's Electron desktop app would need the same
  as Chromium (3 to 5).

## Sources

- The OpenSSF Best Practices badge project's `snap-chromium-bp-badge`
  (the copy in this workspace, `,snap-chromium-bp-badge`).
- What I checked on our VMs on 2026-11-24: the session (GNOME 50,
  Wayland, `DISPLAY=:0`), that Firefox and Chromium are snaps, the
  variables nono sets for its CA and proxy, and that a compartment
  hides `wayland-0`.
- The rest (how browsers keep CAs, proxy logins, VNC, and Wayland's
  clipboard rules) is from general knowledge I haven't checked against
  a source yet; check it before relying on it.
