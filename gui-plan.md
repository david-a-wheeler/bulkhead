# GUIs in compartments: what we know, and options

Status (2026-11-24): notes only; nothing here is built. This records
what we've learned, two targets, and two experiments to try. The VMs run GNOME 50 on Wayland, with Xwayland (`DISPLAY=:0`).

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
this with Wayland's security-context protocol (`wp_security_context_v1`),
but GNOME doesn't support it (see "GNOME and security-context" below).

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
3. **A nested compositor** (e.g., `cage`, as a client of GNOME),
   giving the compartment only the nested compositor's socket, with the
   compositor in its own small sandbox. Nearly native, and it decides
   whether the clipboard crosses; more parts to get right than 2 (see
   "A nested compositor: `cage`" below).
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

## Two targets

1. **The badge project's tests**, driving headless Chromium against its
   own Rails server. No display, no proxy, and no CA needed (it all
   stays on the compartment's loopback), but random loopback ports
   (Capybara's server, chromedriver, and Chrome's DevTools port), which
   nono refuses unless opened.
2. **goose's desktop app, entirely in the compartment.** It's an
   Electron window (`/usr/lib/goose/Goose` in its `.deb`) that starts
   the same `goose` binary as our CLI as its backend (`goose serve
   --host 127.0.0.1 --port PORT`, with PORT random). It can instead use
   a backend you start (`GOOSE_EXTERNAL_BACKEND`, `GOOSE_PORT`, and
   `GOOSE_SERVER__SECRET_KEY`), but that's from its bundled code, not
   its documentation, so it may change. Its `.deb` links `/usr/bin/goose`
   to the app, which would collide with our CLI, so we'd install its
   files ourselves.

The aim is for programs to work without options of their own: the
environment, set up once in shared code, should make them work.

## Random loopback ports

Programs such as Capybara and chromedriver bind port 0, i.e., they let
the kernel pick a free port, and nono refuses that by default. We
tested this on 2026-11-25 (nono 0.82.0, kernel 7.0, `nono run` with a
profile extending `bulkhead-sh`, and a Python line that binds port 0
and connects to it):

- One `--open-port` per port in `ip_local_port_range` (32768 to 60999)
  doesn't work through `compart`: bwrap stops with "Exceeded maximum
  number of arguments 9000", after `compart`'s shell spends about 190 s
  building the list. (`--open-port 32768-60999` fails too: "invalid
  digit found in string".)
- The profile field `open_port_range: [[32768, 60999]]` starts in
  0.1 s, and nono's proxy port (which falls in that range) didn't
  conflict with it. But `bind()` to port 0 is still refused: Land&#108;ock
  checks it against a rule for port 0 itself, not the port the kernel
  picks (the comment on `port` in the kernel's Land&#108;ock header).
- `open_port_range` plus `--listen-port 0` (or `listen_port: [0]` in a
  profile) works. `--open-port 0` doesn't: nono says it's macOS-only.

So two profile entries let such programs work unchanged. A
compartment has its own network namespace, so they open only its own
loopback; outside one (e.g., a bare `nono run`), they'd let the sandbox
reach any of your own programs listening on an ephemeral port, so they
belong only where `compart` adds them. So `compart` now adds the
`bulkhead-loopback` profile to every launch (see `compartments.md`'s
"Ports"). Through `compart sh` (pasta, bwrap, and nono), the same test
printed "ok, port 40221" (2026-11-25), so the profile's `listen_port:
[0]` works as `--listen-port 0` does. It'd still help to ask nono for a
way to allow every loopback port in a namespace it didn't make.

## GNOME and security-context

GNOME 50 doesn't support the security-context protocol, and nothing
shows it coming:

- Ubuntu's mutter 50.1 (`libmutter-18.so.0`) has about 90 Wayland
  interfaces compiled in, including recent ones such as
  `wp_color_manager_v1` and `xdg_toplevel_tag_manager_v1`, but not
  `wp_security_context_manager_v1`.
- mutter's `src/meson.build` on `main` (checked at commit
  30405578e2c9, 2026-11-24) lists every protocol it builds, and
  `security-context` isn't one.
- A web search found no mutter issue or merge request for it. (GNOME's
  GitLab refuses anonymous API searches, so I couldn't search there
  directly.)
- mutter's service channel (`src/core/meta-service-channel.c`) grants
  *extra* rights to trusted clients, such as portal backends; nothing
  restricts a sandboxed one.

As I understand it, GNOME keeps privileged operations (e.g., screen
capture, clipboard managers) off Wayland and behind portals, so a
client on GNOME's socket can't do those anyway. But the risks in "What
a display would expose" remain, so a compartment shouldn't get GNOME's
socket.

## A nested compositor: `cage`

`cage` is a small Wayland "kiosk" compositor (MIT, built on wlroots)
that runs full-screen in one window. Started inside GNOME, it opens as
a window there. Upstream is at 0.3.1 (2026-06-30); Ubuntu 26.04 has
0.2.1 in universe, which is what we have installed (`man cage`).
Options: `-d` (no client-side decorations), `-m last|extend`
(outputs), `-s` (VT switching), `-D` (debug log). The program to run
is optional (`cage [OPTIONS] [--] [APPLICATION...]`; in 0.2.1's
`cage.c`, line 590), and without one it runs until stopped. Ubuntu
built it with Xwayland, which 0.2.1 always sets up (line 532, lazily,
so I believe Xwayland starts only when an X11 program connects); there's
no option to turn that off.

**Its window in GNOME** (from wlroots 0.19's
`backend/wayland/output.c`, which draws `cage`'s window):

- It starts at 1280×720 (line 1113), not full screen, and follows
  GNOME's resizing and maximizing (line 1066); the program inside
  fills `cage`'s window, never your screen.
- A program that asks for full screen gets only `cage`'s window; I
  found no code asking GNOME to make that window full screen. So a
  fake full-screen login prompt stays inside an ordinary window.
- It probably has no title bar: wlroots asks the desktop for
  decorations through `xdg-decoration` (line 1192) and draws none
  itself, and mutter doesn't offer that protocol (it isn't in
  `libmutter-18.so.0`). So you'd move and resize it with GNOME's
  shortcuts (I believe Super+drag moves, and Super+Up maximizes).
- wlroots sets a window title (line 754), so it should show in GNOME's
  window switcher. Check whether `compart` can set it to the
  workspace's name, to tell compartments apart.

**Windows** (from `view.c`, `xdg_shell.c`, and `seat.c` on `master`):

- A window with a parent (a dialog or modal) is centered on top of
  the others; menus and tooltips are drawn attached to their window. So
  an app with a modal works as you'd expect.
- A window with no parent (another main window, or another program)
  is maximized over the rest. There's no key to switch windows (its
  only bindings are quit, in debug builds, and VT switching), so you
  see the newest until it closes. E.g., if goose's app starts a
  browser, the browser inherits `WAYLAND_DISPLAY`, joins the same
  `cage`, and covers goose.

If that's a problem: a nested compositor that manages several windows
(e.g., labwc or sway, also built on wlroots, so they'd sandbox the same
way; not yet checked nested), or a compartment `xdg-open` that hands
you the URL (e.g., in the outbox) instead of starting a browser.

**Its own sandbox.** `cage` needs little: read access to its libraries
and keyboard maps (`/usr/share/X11/xkb`, maybe cursor themes), a
connection to GNOME's `wayland-0`, one directory for its own socket,
no network, and (with `WLR_RENDERER=pixman`, I believe) no GPU. Its
input comes from GNOME, so no `/dev/input`. Then an agent's program
that exploits `cage` lands in a sandbox that can reach only GNOME's
socket, which is no worse than any Wayland client.

It can't be the compartment's parent, though: a sandbox's limits pass
to its children, and bwrap can't run inside nono. So `compart` would
start them as siblings:

1. Start `cage` in its own sandbox (nono with a small profile and
   `--block-net`, or bwrap with `--unshare-all`), with no program, and
   its socket in a dossier directory
   no agent can reach (e.g., `gui/`).
2. Start the compartment as usual, with `bulkhead-compartment` binding
   just that socket into its runtime directory and setting
   `WAYLAND_DISPLAY` (and nono's socket mediation allowing it).
3. Stop `cage` when the session ends.

Xwayland can wait: `cage` would start it in its own sandbox, and its X
socket would be one more thing to pass in. Since 0.2.1 always sets up
Xwayland, its sandbox needs a private `/tmp` (for `/tmp/.X11-unix`)
and its own network namespace (for X's abstract socket), so no other
program in the VM can reach that X server. Chromium and Electron can
use Wayland directly (whether they choose it on their own is to be
tested; I believe recent Electron does with
`ELECTRON_OZONE_PLATFORM_HINT=auto`).

## A second experiment: `cage` in its own sandbox

1. Install `cage` (Ubuntu's is fine to try).
2. Start it in a nono sandbox with `--block-net`, read-only system
   paths, its socket in a scratch directory, and `WLR_RENDERER=pixman`.
3. In a separate `compart sh`, with that socket bound in, run a
   simple Wayland program, then Chromium (the snap wrapper) with
   `--ozone-platform=wayland`.

Check that:

- a window appears, including for a program `cage` didn't start;
- the window starts at 1280×720, resizes with GNOME, has no title bar,
  and shows a title in GNOME's window switcher;
- a program asking for full screen stays inside `cage`'s window;
- a dialog shows over its parent, and a second main window covers the
  first;
- the program can't read GNOME's clipboard (I believe `cage` doesn't
  pass it through, but its documentation doesn't say);
- `cage` runs with no network and no GPU; and
- nono's log shows no surprise denials for either sandbox.

### Results (2026-11-25)

We ran `cage` 0.2.1 under bwrap (`--unshare-all`, read-only `/usr`, a
private `/tmp`, GNOME's socket, and a directory for its own socket),
not nono, and the programs in `compart sh`, as clients of `cage`. The
script was `,gui-experiments.sh` (not kept).

What worked:

- `gnome-calculator` and `gnome-text-editor` showed in `cage`'s window;
  the editor covered the calculator, its dialog showed centered over
  it, and the calculator came back when the editor closed.
- `wl-paste` in the compartment got nothing from GNOME's clipboard.
- Chromium (the snap's binary, through the badge's wrapper, with
  `--ozone-platform=wayland`) showed its page filling `cage`'s window,
  and F11 stayed inside it. It shows Chrome's warning about
  `--no-sandbox`, which is accurate: Chrome's own sandbox can't run in a
  compartment (no_new_privs stops its setuid helper, and AppArmor stops
  user namespaces inside bwrap), so the compartment is its only
  sandbox. Fine for testing your own server; not for general browsing.
- With no GPU, programs print Vulkan and EGL warnings and fall back to
  software rendering. nono refused only connections to the system
  D-Bus, which nothing needed.

What we had to fix:

- `cage` covered the whole 1280×800 screen: wlroots opens a 1280×720
  window, and mutter's `auto-maximize` maximizes a new window nearly
  the screen's size, and it has no title bar. Fix: turn
  `auto-maximize` off while it runs, and shrink it with `wlr-randr
  --output WL-1 --custom-mode 960x600` (`sudo apt install wlr-randr`),
  through `cage`'s output-management protocol. A watchdog that stops
  `cage` unless you answer in its terminal within 60 s made this safe
  to try.
- A black area followed the pointer over `cage`'s window: the pointer
  image wlroots hands GNOME came out blank. `WLR_NO_HARDWARE_CURSORS=1`
  (`cage` draws the pointer itself) fixed it. We also pass GNOME's
  cursor theme (`XCURSOR_THEME`, `XCURSOR_SIZE`, and `XCURSOR_PATH`),
  since the default theme is a symlink into `/etc/alternatives`, which
  `cage`'s sandbox lacks.
- The Chromium wrapper broke on Ubuntu 26.04, GUI or not: it put the
  GNOME content snap's own glibc ahead of the host's, which doesn't work
  with the host's loader ("symbol lookup error: ... GLIBC_PRIVATE"), and
  it ran host commands (e.g., `basename`) after setting
  `LD_LIBRARY_PATH`. The fix is to put the host's library directories
  right after Chrome's own, and set `LD_LIBRARY_PATH` just before
  `exec`. The badge repository's copy needs both fixes.

What's still awkward:

- You move `cage`'s window with Super and drag, since nothing draws a
  title bar (mutter has no `xdg-decoration`, and wlroots draws none).
  Nested `weston` draws its own title bar and manages several windows,
  so it's worth trying next.
- `cage` logged "No free output buffer slot" a few times, without
  visible effect.
- Not tested: goose desktop (Electron) in `cage`, and running `cage`
  under nono instead of bare bwrap.

## A third experiment: nested `weston`

We ran `weston` 14.0.2 the same way as `cage` (its own bwrap sandbox,
the same fixes), with `--renderer=pixman --width=1024 --height=700` and
a generated `weston.ini` (`[shell] panel-position=none`,
`locking=false`, `binding-modifier=alt`; `[core] idle-time=0`; and the
cursor theme). It picks its Wayland backend because `WAYLAND_DISPLAY`
is set.

### Results (2026-11-25)

- **A better window than `cage`'s:** `weston` draws its own frame, so
  you move its window by the title bar, resize it by an edge, and
  maximize it. Inside, each program gets its own movable window, so the
  calculator and editor can sit side by side. The calculator kept its
  normal size instead of filling the window.
- **The title:** `weston` titles its window "Weston Compositor - NAME",
  where NAME is its output's name, set by `[output] name=`. The prefix
  is built in, and `weston` uses only `[output]` sections whose names
  start with "WL". We used `name=WL-gui-test`. Since `weston` draws the
  frame from outside the compartment, nothing inside can change it.
- **The same as `cage`:** the calculator, editor, its dialog, and
  Chromium all worked, and the compartment's `wl-paste` got nothing
  from GNOME's clipboard. `weston` has no clipboard bridge to its
  parent at all.
- **Starting only when needed:** `systemd-socket-activate
  --listen=SOCKET` makes the compartment's socket, with nothing running.
  When the first program connects, it starts `weston`, passing the
  socket as file descriptor 3. `weston --modules=systemd-notify.so`
  (part of the `weston` package) listens on it, logging "add 1
  socket(s) provided by systemd". Later programs join that same
  `weston`, which we confirmed in GNOME: one `weston` served the
  calculator, editor, and Chromium. Details that matter:
  - `sd_listen_fds` wants `LISTEN_PID` to be `weston`'s own process ID,
    which only something inside bwrap's process namespace knows. So
    bwrap passes `LISTEN_FDS=1` and runs `sh -c 'LISTEN_PID=$$ exec
    weston ...'`.
  - `weston` makes its own socket too, so it needs `--socket=` with
    another name. Otherwise it may take `wayland-0`'s lock and replace
    our socket.
  - Without the module, `weston` can't take over a listening socket.
    `WAYLAND_SERVER_SOCKET` is one already-connected client, and
    `weston` exits when that client does ("Primary client died").
    With `systemd-socket-activate --accept` that gives one `weston` per
    connection, which we rejected: programs couldn't share a window,
    clipboard, or drag and drop.
- **Noise:** nono refused the system D-Bus to the editor and Chromium,
  as before. `weston` logged "Detected an unmapped surface or view in
  the layer list, which should not occur" once, without visible effect.
- **Not tested:** goose desktop, and `weston` under nono.
- **Later (2026-11-25), with `bulkhead-display`:** copying and pasting
  works between two programs in one compartment's `weston`, even when
  they're started by different `compart sh` sessions. The window kept
  the size we gave it (70% of the monitor) instead of GNOME maximizing
  it. Spaces in the output's name work ("WL Compartment bulkhead").
  The "WL" stays: a nested `weston` ignores an `[output]` section whose
  name doesn't start with it, and then titles its window "Weston
  Compositor - wayland0", which doesn't say which compartment it is.

### The design this suggests

One `weston` per compartment, started by `compart`:

- **A socket per compartment,** outside the workspace (e.g., under
  `$XDG_RUNTIME_DIR`), named by its compartment. `compart` binds it into
  every launch there and sets `WAYLAND_DISPLAY`. Programs in one
  compartment share its `weston`, and its clipboard and drag and drop,
  which adds little risk since they already share files. Programs in
  different compartments never share one.
- **Started on demand:** the first `compart` launch starts
  `systemd-socket-activate` with `weston` as a sibling of the
  compartment, not inside it. No window shows until a program connects.
- **Titled by compartment:** "Compartment FOO" for `~/projects/FOO`, as
  far as the fixed prefix allows.
- **Stopped with the last session:** each `compart` session records
  itself in the dossier, and when a session ends and finds no other
  live session there, it stops that compartment's `weston`. A lock
  (`flock`) keeps two launches from starting two `weston`s.
- **Wayland only for now:** no Xwayland. `compart` can set variables
  that steer programs to Wayland (e.g., `GDK_BACKEND=wayland`,
  `QT_QPA_PLATFORM=wayland`, and `ELECTRON_OZONE_PLATFORM_HINT=wayland`)
  and leave `DISPLAY` unset.

Built as `bulkhead-display` (see `compartments.md`, "GUI programs").
Instead of a file per session, the last session is the one that can
take the dossier's `sessions.lock` exclusively, since each session
holds it shared; so a session that crashed can't look alive. CI tests
the launcher's start and stop with stand-ins for `weston` and bwrap,
but not a real window; we've tested that by hand on GNOME (see
Results above).

## Future directions

- **Per-compartment app state.** GUI programs want to keep settings
  and data in your home directory (e.g., gnome-text-editor tries to
  create `~/.config/enchant` and `~/.local/share/org.gnome.TextEditor`),
  which nono refuses. `compartment-paths` already gives a compartment
  `private` copies of directories, so the likely fix is a private
  `~/.config` and `~/.local/share` (or the parts apps use), granted
  read-write in the shared nono profile. Then settings would last
  between runs in that compartment but never reach another. dconf
  could then work too, if it gets a per-compartment
  `$XDG_RUNTIME_DIR` (instead of `GSETTINGS_BACKEND=memory`).
- **Input methods (ibus), per compartment.** A quick test
  (2026-11-25, in a nono session with a display) says it's feasible.
  `ibus-daemon --address=unix:path=SOCKET --panel=disable
  --emoji-extension=disable --config=/usr/libexec/ibus-memconf` runs
  in the sandbox, with no session D-Bus and no dconf (`ibus-memconf`
  keeps its settings in memory). Clients find it through
  `IBUS_ADDRESS`, not the usual address file (whose name ibus builds
  from `WAYLAND_DISPLAY`, an absolute path here, so it can't make it).
  `ibus list-engine` listed the engines, `ibus engine table:cangjie5`
  switched to one, and gnome-text-editor (with `GTK_IM_MODULE=ibus`)
  connected to the daemon's socket. Not tested: typing through it.
  What it would take: start a daemon per compartment, beside its
  `weston` (and stopped with it), with its socket in the display's
  directory; set `IBUS_ADDRESS` and `GTK_IM_MODULE=ibus` (and
  `QT_IM_MODULE=ibus`) instead of turning input methods off; and give
  engines somewhere to write, since ibus-table insists on
  `~/.local/share/ibus-table` (it ignores `XDG_DATA_HOME`), which is
  the per-compartment state above. Clients still warn that
  `/var/lib/dbus/machine-id` is missing, which nono hides; granting
  `/etc/machine-id` would quiet that but give agents an identifier
  shared by every compartment on the VM.
- **Qt and Electron apps, quietly, without GNOME.** We've tested only
  GTK programs and Chromium. Qt and Electron apps need a test, aiming
  for no warnings and no denials, and for nothing that needs GNOME's
  own services.

## Sources

- `cage`: its [README](https://github.com/cage-kiosk/cage), [man
  page](https://raw.githubusercontent.com/cage-kiosk/cage/master/cage.1.scd),
  [releases](https://github.com/cage-kiosk/cage/releases), source on
  `master` and `v0.2.1` (`view.c`, `xdg_shell.c`, `seat.c`, `cage.c`),
  wlroots 0.19's `backend/wayland/output.c`, `man cage` and `cage -h`
  for the installed 0.2.1, and
  [Ubuntu's package](https://packages.ubuntu.com/resolute/cage), all
  read 2026-11-24.
- Security-context: [the protocol](https://wayland.app/protocols/security-context-v1);
  mutter's [`src/meson.build`](https://github.com/GNOME/mutter/blob/main/src/meson.build)
  and [`src/core/meta-service-channel.c`](https://github.com/GNOME/mutter/blob/main/src/core/meta-service-channel.c);
  the strings in Ubuntu's `libmutter-18.so.0`; and, secondhand, the
  [snugmo/apse README](https://github.com/snugmo/apse), which says
  wlroots compositors and KWin support it and mutter doesn't.
- goose's desktop app: the `.deb` for v1.60.0 (its file list, and
  strings in its `app.asar`), unpacked 2026-11-24.
- `weston` 14.0.2 on our VM (2026-11-25): `weston --help`, its logs,
  the symbols its `systemd-notify.so` uses (`sd_listen_fds` and
  `wl_display_add_socket_fd`), and headless tests in my sandbox.
- nono 0.82.0's `nono run --help`, and its `--dry-run` with 28,232
  `--open-port` options.

- The OpenSSF Best Practices badge project's `snap-chromium-bp-badge`
  (the copy in this workspace, `,snap-chromium-bp-badge`).
- What I checked on our VMs on 2026-11-24: the session (GNOME 50,
  Wayland, `DISPLAY=:0`), that Firefox and Chromium are snaps, the
  variables nono sets for its CA and proxy. That a compartment can't
  see `wayland-0` follows from its own `/run`, but no test checks it
  yet.
- The rest (how browsers keep CAs, proxy logins, VNC, and Wayland's
  clipboard rules) is from general knowledge I haven't checked against
  a source yet; check it before relying on it.
