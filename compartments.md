# Compartments

Every agent you start through `anon-access` (e.g., with `noclaude` or
`nopi`) runs in its workspace's *compartment*. A compartment keeps one
project's agent from reading, changing, or reaching what belongs to
another project's agent, or to the VM itself. This file explains what
a compartment gives you and how it's built. For why the workspace's
dossier exists and where it lives, see `workspace-dossier-plan.md`; for
the overall security design, see `architecture.md`.

## What a compartment can and can't do

A workspace is `~/projects/NAME` or `~/sensitive/NAME` (or another
directory you've registered); its dossier is the sibling directory
`NAME.dossier`. Every directory inside a workspace shares its
compartment.

An agent in a compartment **can**:

- Read and write its own workspace (the directory it started in and
  below, as the harness's nono profile grants).
- Read the files you put in the dossier's `inbox/`, and write files
  for you in its `outbox/`.
- Keep its own harness state: its own `/tmp`, `~/.claude` (transcripts,
  history, todos, its config file), Claude's caches and sockets, and
  pi's sessions. These persist between runs in the same compartment.
- Read your shared harness setup (e.g., `~/.agents`, including the
  global instructions `~/.agents/AGENTS.md`, and `~/.claude/CLAUDE.md`,
  `settings.json`, skills, and plugins), so it applies everywhere.
- Reach the web through nono's proxy, as the network policy allows:
  outside `~/sensitive`, GET and HEAD to any site plus the harness's
  own hosts (e.g., Claude's API); under `~/sensitive`, only the narrow
  allowlist.
- Reach sites by name: nono's proxy looks them up, through the VM's
  resolver.
- Run its own servers and tests on its own loopback, on ports you list
  in the dossier's `policy/local-ports`.
- Reach a VM port its harness's wrapper needs (e.g., `nopi`'s local AI
  engine tunnel), and only that one.

An agent in a compartment **can't**:

- Read or change another compartment's state, `/tmp`, or workspace.
- Read or change its own dossier, except `inbox/` (read only) and
  `outbox/` (write only). So it can't change its own policy, read back
  what it gave you, or erase its own log.
- Change your shared harness setup (it's read-only inside), even when a
  harness's pack grants it write access (e.g., `nolabs-ai/goose` grants
  `~/.agents` read-write).
- Read the rest of your home directory, beyond what the nono profiles
  grant.
- See or reach the VM's local services (e.g., sshd, or other agents'
  servers). It has its own
  loopback, and `/proc/self/net` lists only its own sockets.
- See the VM's other processes: it has its own PID namespace.
- Connect to an abstract Unix socket outside its own sandbox, including
  another agent's.
- Use a loopback port you haven't listed in `local-ports`.
- Accept connections from outside: nothing it listens on is reachable
  from the VM.
- Create a UDP socket (so it can't do its own DNS lookups), or open a
  TCP connection anywhere except nono's proxy and its opened ports.
- Reach a site, or use an HTTP method, the network policy doesn't
  allow.
- Use your credentials: `anon-access` strips them from the environment
  (e.g., `BULKHEAD_AUTH_SESSION`, `SSH_AUTH_SOCK`, GitHub and Heroku
  tokens), and gives `gh` only a read-only public-repositories token.

What a compartment does **not** protect against:

- Two runs in the *same* compartment share its files (workspace,
  state, `/tmp`). They don't share a network: each run gets a fresh
  network namespace, so they can't talk over loopback.
- Everything runs as you, on one kernel. A kernel bug that breaks out
  of namespaces or Landlock breaks out of the compartment; the VM is
  the next boundary.
- Claude's credentials are shared on purpose
  (`CLAUDE_SECURESTORAGE_CONFIG_DIR`), so one login works everywhere.
- Broad GET to the web is a way to send data out (e.g., in a URL's
  query string). That's a policy choice for workspaces outside
  `~/sensitive`; put a workspace under `~/sensitive` when that matters.
- An agent's own test servers need their ports listed in
  `local-ports` (see "Known gaps").

## How it's built

`anon-access` starts every agent like this:

```
noclaude → anon-access → pasta → bwrap → nono run → claude
```

Each layer does a different job, and each backs up the others:

| Layer | Answers | Mechanism |
|---|---|---|
| `anon-access` | What does the agent start with? | strips secrets, prepares the dossier, builds arguments |
| pasta | What network exists at all? | user, network, and PID namespaces |
| bwrap | What is each path? | a nested user namespace and bind mounts |
| nono | What may the agent touch? | Landlock, seccomp, and a filtering proxy |
| nftables | Where may the VM send traffic? | the VM's firewall (ports 22, 53, 80, 443, and the secrets server) |

### anon-access

`anon-access` runs `bulkhead-workspace-prepare`, which finds the
current directory's workspace (via `bulkhead-compartment-info`) and
creates its dossier. It refuses a directory no agent may start in:
anything matching `workspace-forbidden` (e.g., `~`, `~/projects`
itself, dot directories, a dossier, `/tmp`), a workspace at or above
`~`, or one that holds another workspace's dossier.

It then strips credentials from the environment, and for a `nono run`
command it adds:

- `--extends bulkhead-broad` outside `~/sensitive` (broad GET and HEAD).
- `--log-file` in the dossier's `logs/`, outside every sandbox grant.
- What `bulkhead-workspace-nono-args` prints: `--read DOSSIER/inbox`,
  `--write DOSSIER/outbox`, and an `--open-port` for each port in
  `DOSSIER/policy/local-ports` (one port or range per line).
- For each `--open-port` the harness's wrapper passes (e.g., `nopi`'s
  for the AI engine), a `--forward-port` to `bulkhead-compartment`, so
  pasta forwards that VM port in. The dossier's `local-ports` aren't
  forwarded: they're for the agent's own servers.

Finally it runs `bulkhead-compartment` with the command.

### pasta: the network namespace

pasta (from Ubuntu's `passt` package, the default network for rootless
podman) creates new user, network, and PID namespaces and runs bwrap
in them. `bulkhead-compartment` runs it as:

```
pasta --config-net --quiet \
  --tcp-ports none --udp-ports none --udp-ns none --tcp-ns PORTS \
  --map-host-loopback none --map-guest-addr none \
  --dns-forward 169.254.53.53 --dns-host 127.0.0.53 -- bwrap ...
```

pasta's defaults suit containers, not us, so we override them:

- `--tcp-ns` and `--udp-ns` default to `auto`, which forwards every
  port listening on the VM's loopback into the namespace. We forward
  none, except `--tcp-ns` for each `--forward-port` (`PORTS`, or
  `none`). A connection to `127.0.0.1:PORT` inside then reaches
  `127.0.0.1:PORT` on the VM.
- `--tcp-ports` and `--udp-ports` default to `auto`, which forwards
  ports the agent listens on out to the VM. We forward none.
- By default, connections to the namespace's gateway address go to the
  VM's loopback. `--map-host-loopback none` and `--map-guest-addr none`
  turn that off.

pasta gives the namespace a route out through ordinary sockets on the
VM, so nftables still applies to everything it sends. In practice only
nono's proxy uses that route, since Landlock confines the agent itself
to the proxy and its opened ports.

DNS needs one more step. Ubuntu's `/etc/resolv.conf` points to
systemd-resolved at `127.0.0.53`, which is on the VM's loopback and so
out of reach. pasta maps `169.254.53.53` inside to the VM's first IPv4
resolver (read from `/etc/resolv.conf`), and bwrap mounts
`netns-resolv.conf`, which names that address, over the file
`/etc/resolv.conf` points to.

pasta's own AppArmor profile runs its command unconfined (`Ux`), so
bwrap still runs under its usual profile. But the capital `U` also
scrubs the environment: glibc drops its "unsecure" variables, such as
`TMPDIR`, `TZDIR`, `LOCPATH`, and the `LD_*` and `MALLOC_*` debugging
knobs. Without `TMPDIR`, nono expands `$TMPDIR` in `bulkhead-claude` to
`/tmp`, and Claude Code refuses `/tmp/claude-UID`. So bwrap sets
`TMPDIR` again. We let the rest go: they're rarely set, and a sandbox
is better off without the loader's debugging knobs. If one of them
turns out to matter, have bwrap set it too. pasta passes through the
terminal, the rest of the environment, and the exit status. Each run
gets a fresh namespace, which goes away when the command exits.

### bwrap: the filesystem view

bwrap (bubblewrap) runs unprivileged in a nested user namespace and
starts from the real filesystem (`--dev-bind / /`). It then mounts
over the paths `compartment-paths` lists, each as one of these kinds:

- `private`: the compartment's own copy, from `DOSSIER/state/` (named
  by the path with `/` as `%`), created empty the first time. E.g.,
  `~/.claude`, `~/.cache/claude`, `~/.local/state/claude`,
  `$XDG_RUNTIME_DIR/cc-socks`, and `~/.pi/agent/sessions`.
- `ro`: the real path, read-only, so shared setup applies everywhere
  but no compartment can change it. E.g., `~/.agents`,
  `~/.claude/CLAUDE.md`,
  `settings.json`, `keybindings.json`, `agents`, `commands`, `hooks`,
  `skills`, and `plugins`.
- `tmpdir`: `/tmp` becomes the workspace's `$TMPDIR` (on disk, inside
  the workspace) if it's there, and a fresh tmpfs otherwise.
- `tmpfs`: an empty in-memory directory for each run.

bwrap also mounts `netns-resolv.conf` (see above) and sets
`BULKHEAD_COMPARTMENT` to the compartment's key (`projects-NAME`,
`sensitive-NAME`, or `dir%PATH`). The state lives in the dossier, beside
the workspace rather than in it, so it can't arrive with a workspace's
contents, and nono doesn't grant the agent the dossier directly.

Anything a harness writes that another compartment could read or run
belongs in `compartment-paths`; list every harness's paths there.

### nono: what the agent may touch

nono runs inside bwrap and sandboxes the harness with Landlock and
seccomp, using its shared `default` profile (`nono-default-profile.json`)
plus the harness's pack and small profile (e.g., `bulkhead-claude`).

Files:

- The workspace and the paths the profiles grant; the rest of home is
  denied.
- `inbox/` read-only, `outbox/` write-only, and nothing else in the
  dossier.

Network:

- nono starts a proxy on the namespace's loopback and points the agent
  at it. The proxy allows only the domains, paths, and methods the
  network policy lists, and refuses the rest before anything leaves.
- Landlock lets the agent open TCP connections only to the proxy and
  to ports opened with `--open-port`, and bind only those ports.
  seccomp refuses to create UDP sockets, so the agent can't do its own
  DNS lookups; the proxy resolves names for it.
- Landlock scopes abstract Unix sockets to the sandbox, so the agent
  can't connect to one made outside it.

So bwrap alone wouldn't stop an agent from reading the rest of your
home, and nono alone wouldn't stop two projects' agents sharing `/tmp`
or `~/.claude`. Likewise, if the proxy were bypassed, pasta would still
block the VM's local services and nftables would still limit ports;
without pasta, Landlock would still refuse connections to those
services, though the agent could list them again.

## Why nono doesn't make the namespace

nono can make a network namespace itself (`--isolate net,loopback`),
and with it, the agent could use any loopback port. But not inside
bwrap on Ubuntu. Ubuntu's AppArmor profile for bwrap
(`/etc/apparmor.d/bwrap-userns-restrict`) runs everything bwrap starts
under the stacked profile `unpriv_bwrap`, which has
`audit deny capability`. Creating a network namespace needs
`CAP_SYS_ADMIN`, even inside nono's own user namespace, so nono fails
with "Operation not permitted". The kernel log shows the denial:

```
apparmor="DENIED" operation="capable" profile="unpriv_bwrap" comm="nono" capname="sys_admin"
```

nono's error message blames `kernel.apparmor_restrict_unprivileged_userns`
and suggests an AppArmor profile for nono, but that's not the cause, and
such a profile wouldn't help: bwrap's exec rule picks the profile, and
`deny` beats any `allow` in it.

We rejected these alternatives:

- **Loosening AppArmor** (e.g., a rule in
  `/etc/apparmor.d/local/bwrap-userns-restrict` sending nono to a
  profile with `capability sys_admin`): that gives nono more privilege.
- **Running nono outside bwrap:** bwrap can't run inside nono.
- **bwrap's own `--unshare-net`:** then nono's proxy has no route out.
  We tested a fix: socat-style relays over Unix sockets (which cross
  network namespaces) for each forwarded port, nono's `--upstream-proxy`
  pointed at a CONNECT proxy outside, and care over startup order. It
  worked, and nono didn't need DNS inside, but it needed more pieces
  than pasta, which does all of it.

## Why bwrap and pasta, not a higher-level tool

We need the VM's real filesystem (so agents use the tools installed
there), a few private per-project paths, and a network namespace that
still has a route out, all without root. bwrap and pasta are Ubuntu
packages that do exactly that, and they're already the parts Flatpak
(bwrap) and rootless podman (pasta) are built on. We looked at these
alternatives in Ubuntu's repositories and rejected them:

- **Rootless podman:** it handles the environment and pasta networking
  for you, but it's built around images. Agents would lose direct use
  of the VM's installed tools unless we built and maintained an image
  of them.
- **firejail:** closest in features (`--private-tmp`, `--whitelist`,
  per-run networks), but it's setuid root, with a long history of
  vulnerabilities, so it adds root attack surface we otherwise avoid.
  It scrubs the environment too.
- **`systemd-run --user`:** it offers `PrivateTmp`, `BindPaths`, and
  `TemporaryFileSystem`, but its `PrivateNetwork` gives no route out,
  so we'd still need pasta. It would also tie the agent's lifetime to
  a transient systemd unit, which is more to manage than one `exec`.
- **systemd-nspawn, LXD, and full containers:** they need root (or a
  privileged daemon) and, like podman, a separate root filesystem.

## Escape hatches

- `BULKHEAD_NO_NETNS=1`: skip pasta. The agent shares the VM's network
  namespace and can list its ports and sockets (but Landlock still
  refuses connections to them).
- `BULKHEAD_NO_COMPARTMENT=1`: skip bwrap and pasta entirely. nono still
  runs, but compartments share `/tmp`, `~/.claude`, and so on.

Both print a warning. Use them only to work around a breakage.

## Known gaps

- nono still refuses loopback ports that aren't opened, even though
  the namespace is private, because it doesn't know that. So list an
  agent's own server ports in `DIR.dossier/policy/local-ports`. A nono
  option to allow all loopback ports in a namespace it didn't make
  would close this.
- An agent can't install or change shared setup from inside a
  compartment, since it's read-only there. E.g., goose can't install a
  plugin into `~/.agents/plugins`, and Claude can't add a skill to
  `~/.claude/skills`. Do that from outside any compartment (e.g., run
  the harness's install command in a plain shell), and every
  compartment then sees it.
- nono's error message for the AppArmor denial points to the wrong
  cause; it's worth reporting upstream.

## Testing

`./ci.sh` checks the arguments `bulkhead-compartment` and
`bulkhead-workspace-nono-args` build (with `--dry-run`), including that
pasta forwards nothing unless asked. `tests/compartment-test.sh` runs
real compartments; run it by hand in a VM, outside any sandbox (bwrap
can't run inside nono). It checks the file isolation, the inbox and
outbox, that an agent can't see or reach the VM's loopback services,
that a compartment keeps your uid and `TMPDIR`, that names resolve in the compartment, that a forwarded port works and an unforwarded one
doesn't, that an agent reaches an allowed site through nono's proxy,
and that abstract sockets stay apart.
