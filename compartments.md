# Compartments

Every agent you start with `compart` (e.g., `compart claude` or
`compart pi`) runs in its workspace's *compartment*. A compartment keeps one
project's agent from reading, changing, or reaching what belongs to
another project's agent, or to the VM itself. This file explains what
a compartment gives you, how to use it (including each workspace's
*dossier*), and how it's built. For the overall security design, see
`architecture.md`; `archive/workspace-dossier-plan.md` has the
dossier's original plan and lessons learned.

## What a compartment can and can't do

A workspace is `~/projects/NAME` or `~/sensitive/NAME`, with its
dossier beside it (`NAME.dossier`), and every directory inside it
shares its compartment. Elsewhere, a workspace is just the directory
you start in, with its dossier in `~/.local/state/bulkhead/dossiers`
(see "Where dossiers live").

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
  in the dossier's `policy/local-ports`, or `policy/expose-ports` to
  let you reach them from the VM.
- Reach a VM port its harness needs (e.g., `compart pi`'s local AI
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
- Accept connections from outside, except on ports you list in
  `policy/expose-ports`: those you (and other VM processes outside a
  compartment) can reach at `127.0.0.1:PORT` on the VM.
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
- Git runs commands named in a repository's local files, so an agent
  can make git run its code outside the compartment, the next time
  *you* run git in its workspace. See "Git runs commands from local
  files".

### Git runs commands from local files

An agent can write its workspace's `.git`, on purpose, so it can
commit. (It can't push: the network policy refuses it.) But git runs
commands named in `.git/config` (e.g., `core.fsmonitor`, `core.pager`,
or a `filter.NAME.smudge` that a `.gitattributes` line selects) and in
`.git/hooks`. So an agent could plant a command there that runs,
unsandboxed, the next time you run git in that workspace, or your shell
prompt does. git's own documentation (git(1), "SECURITY") says it isn't
safe to run git in a `.git` directory from an untrusted source, and
that's what this is.

We can't stop the agent writing `.git`, so `vm-setup.sh` makes your git
ignore the riskiest parts of a repository's own config and hooks. This
is cheap insurance against surprise commands, not a boundary:

- **Pinned settings.** git reads command-scope settings
  (`GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_n`, and `GIT_CONFIG_VALUE_n`)
  after a repository's config, so they win, and a few environment
  variables beat the matching key. `make-git-safety-env` writes them to
  `~/.config/environment.d/50-bulkhead-git-safety.conf`, which your
  desktop session reads, and `~/.profile` reads it too (for ssh and
  console logins). They pin `core.hooksPath`, `core.fsmonitor`,
  `protocol.ext.allow` (an `ext::` remote runs a command),
  `gpg.program` and its relatives, the pager, the editors,
  `GIT_SSH_COMMAND`, `GIT_ASKPASS`, and your credential helpers. The
  last matters most: git hands every helper your password on "store",
  so a planted one would get your GitHub token when you push. The pins
  reset the list and add back yours. The values come from your own
  config when `vm-setup.sh` runs, so re-run it after you change them;
  they take effect at your next login. They reach agents too, which is
  harmless: an agent can change its own environment anyway.
- **Approved hooks.** `git-hook-passthrough` (which your global
  `core.hooksPath` runs for every hook name) runs a repository's own
  hook only if its path and SHA-256 hash are a line in
  `~/.config/bulkhead/approved-git-hooks`, in `sha256sum`'s format. When
  it skips one, it prints the command to approve it. No nono profile
  grants that file, so an agent can't approve its own hook, and a
  changed hook needs a new approval. Approving a framework's hook (e.g.,
  pre-commit's or git-lfs's) trusts its config files too, which the
  agent can change (e.g., `.pre-commit-config.yaml`). There's also a
  brief window between the check and the run.

What's still open, so check these before you run git after a session
you didn't watch:

- Drivers, whose names a repository picks: `filter.NAME.*`,
  `diff.NAME.*`, and `merge.NAME.*`. (An empty `diff.external` doesn't
  disable it; git fails every diff instead.) `git diff --no-ext-diff
  --no-textconv` avoids the diff ones while you review.
- Other keys with a repository's own names in them, e.g., a remote's
  URL, `uploadpack`, or `pushurl`, `url.NAME.insteadOf`, and per-URL
  `http.URL.*` settings (git prefers the most specific URL match, so a
  pin can't beat them). These could send your push, and its
  credentials, elsewhere.
- Programs that don't get your login environment (e.g., cron).
- Anything else that runs from the workspace (e.g., `Makefile`,
  `ci.sh`, `package.json` scripts, or `.envrc`).

E.g., `git config --local --list`, `git remote -v`, `ls .git/hooks`,
`ls .git/commondir`, and `find . -name .git` (for a repository the
agent created below the workspace).

We tried and rejected these:

- **Read-only `.git/config` and `.git/hooks`** (bwrap binds, with `.git`
  bound onto itself so it can't be swapped). git honors a
  `.git/commondir` file in any repository, not only in worktrees, and
  then reads config and hooks from the directory it names. I tested
  that: planting one made `git config user.name` return the planted
  repository's value. A bind can't stop a file being created, and a
  placeholder at that name makes git refuse to run. It also wouldn't
  cover a repository the agent creates below the workspace. (The pins
  above don't care where config comes from, so `commondir` doesn't
  defeat them.)
- **nono:** Landlock is allow-only, so nono can't make part of a
  writable workspace read-only on Linux; it refuses to start instead.
- **A read-only `.git`:** that works, but then the agent can't commit.
- **`~/.gitconfig`:** a repository's config overrides it. git honors
  only a few keys (e.g., `safe.directory`) solely from your own config.

## Workspaces and their dossiers

### Choosing the workspace

`bulkhead-workspace` decides which workspace a directory belongs to,
so every script computes it the same way:

- Anything under `~/projects/NAME` or `~/sensitive/NAME` belongs to
  that `NAME`.
- Else, the directory itself. So `~/junk` and `~/junk/sub` are separate
  workspaces, with separate compartments.

Its compartment's key is `projects-NAME`, `sensitive-NAME`, or
`dir%PATH` (the path with `/` as `%`).

### Where an agent may not start

Everything runs as you, so the sandbox's grants are the only thing
keeping an agent away from data, and an agent gets its whole workspace.
Starting in `~` or `~/projects` would quietly grant every workspace and
every dossier. So `bulkhead-workspace` refuses (and so `compart`
and `anon-access` refuse, before anything else, even the secrets dialog):

- A directory, or a workspace, matching a pattern in
  `workspace-forbidden` (data: shell `case` patterns, one per line).
  It lists `~/projects` and `~/sensitive` themselves, `~/.*` (e.g.,
  `~/.ssh` and `~/.config`), any dossier, and `/tmp`, `/var/tmp`,
  `/dev/shm`, and everything in them, where another user could plant
  files (e.g., a workspace's `.tmp`) before you.
- `~` and every directory above it (in code; it's not one pattern).

`bulkhead-workspace prepare` also refuses a workspace you can't write,
and a dossier that isn't a directory you own (e.g., a symlink).
Outside `~/projects` and `~/sensitive`, before it creates a dossier,
it asks on the terminal (`make DIR a workspace, ...? [y/N]`), in case
you started in the wrong place, e.g., `~/Downloads`. Anything but yes
refuses, and so does having no terminal (e.g., a script); `prepare
--yes` skips the question.

### The dossier

Each workspace gets a dossier directory, mode 700 (see "Where dossiers
live"), for data that's *about* the workspace and mustn't be under its agent's
control: what the agent did, what it's allowed, and the harness's
private state. `bulkhead-workspace prepare` (run by `anon-access`)
creates it before any sandbox starts; it must exist first, since nono
binds its grants at start, so a directory made later stays denied.

| Path | Agent's access | Holds |
| --- | --- | --- |
| `workspace` | none | `DIR`'s real path when last launched |
| `state/` | read-write, through bwrap's binds only | the harness's private files (e.g., `~/.claude`) |
| `logs/` | none | `nono.log` and its one rotated copy |
| `policy/` | none | your settings for the workspace: `local-ports` and `expose-ports` |
| `inbox/` | read-only (nono `--read`) | files you give the agent |
| `outbox/` | write-only (nono `--write`) | files the agent gives you |

nono grants the workspace (`--allow-cwd`) and its profiles' paths, and
none of those covers a sibling or `~/.local/state/bulkhead/dossiers`,
so "none" needs no rule of its own.
`state/` holds one subdirectory per `private` path in
`compartment-paths`, named by its path with `/` as `%`; bwrap binds each
over its path. The shared Claude credentials aren't here
(`~/.local/state/bulkhead/claude-credentials`): they're shared on
purpose.

### Where dossiers live

- **Under `~/projects` and `~/sensitive`**, `NAME`'s dossier is the
  sibling `NAME.dossier`.
- **Elsewhere**, `DIR`'s dossier is
  `~/.local/state/bulkhead/dossiers/KEY`, where `KEY` is `dir%PATH`
  (`DIR`'s real path with `/` as `%`), e.g.,
  `dir%srv%foo` for `/srv/foo`.

A dossier is never inside its own workspace:

- **What's inside a workspace can arrive with its contents**: a
  tarball, a zip, a submodule, or a branch you check out. If harness
  state lived there, a planted `~/.claude` could hold an `mcpServers`
  entry (which Claude Code runs at startup without asking), an
  already-accepted folder-trust prompt, or a `MEMORY.md` or transcript
  the agent trusts as its own notes. What these run stays in the
  sandbox, but each skips a point where you'd normally decide. A
  dossier outside the workspace can't arrive that way, so the state
  comes only from the harness.
- **Ordinary tools would treat it as project files**: `git clean -fdx`
  would delete your transcripts, and archiving the project to share it
  would copy transcripts that may hold secrets you pasted.

Beside the workspace, you see it (`ls` shows `NAME.dossier` right
beside `NAME`). But a dossier must also never be inside *another*
workspace: that workspace's agent could then read this one's
transcripts, change its policy, or plant a `MEMORY.md` in its private
`~/.claude`, which is what compartments exist to stop. Under
`~/projects` and `~/sensitive`, that can't happen: the only
directories holding `~/projects/NAME.dossier` are `~/projects`, `~`,
and above, and no agent may start there. Elsewhere it could: a dossier
beside `~/junk/sub` is inside `~/junk`.

So elsewhere, dossiers live in one central directory, under `~/.*`,
where no agent may start. We used to put them beside their workspaces
there too, with a registry of every workspace, so we could refuse a
workspace that held another's dossier, and so a subdirectory of a
registered workspace could share its compartment. That took about 40
lines of code (finding the nearest registered workspace, the nested
check, and keeping the registry up to date), and it trusted that our
code had made every dossier: one you made by hand wasn't in the
registry, so the check couldn't see it. The central directory makes
the whole problem impossible instead, with no registry. The cost:
outside `~/projects` and `~/sensitive`, you can't see the dossier
beside the workspace, a subdirectory is a separate workspace, and the
dossier doesn't follow the workspace when you move it (see below).

### Moving a workspace

A dossier doesn't move by itself, so **move or delete a workspace and
its dossier together, with `mv`**:

- Under `~/projects` and `~/sensitive`, move both:
  `mv ~/projects/a ~/projects/b && mv ~/projects/a.dossier ~/projects/b.dossier`.
- Elsewhere, the dossier's name comes from the workspace's path, so
  rename it to the new path's key, e.g., for `/srv/a` to `/srv/b`:
  `mv /srv/a /srv/b && mv ~/.local/state/bulkhead/dossiers/dir%srv%a ~/.local/state/bulkhead/dossiers/dir%srv%b`.

`bulkhead-workspace prepare` helps you notice:

- It records the workspace in the dossier's `workspace` file.
- When it creates a dossier, it says so, so if you moved a workspace
  without its dossier, you notice and can move the old one.
- When a dossier's `workspace` names another path, it says so and
  updates it (you moved both).
- `bulkhead-workspace orphans` lists dossiers whose workspace is gone,
  and `vm-setup.sh` warns about them.

Transitional, until every VM has run it: it moves older layouts in.
Each registered workspace's old dossier beside it, outside `~/projects`
and `~/sensitive`, moves to the central directory, all at once (since
one workspace could hold another's), and then the registry goes. A
workspace's `.bulkhead` (the old place for harness state) moves into
`state/`, but only one we made (its `.gitignore` is `*`) that git
doesn't track; it warns about any other. And it moves old logs from
`~/.local/state/bulkhead/logs/KEY`.

### Inbox and outbox

Put files in `inbox/` that you want an agent to read but not change,
e.g., a task description, a spec, or reference data. An agent puts
files in `outbox/` that are for you but don't belong in the workspace,
e.g., a proposed PR description. `compart` sets `BULKHEAD_INBOX` and
`BULKHEAD_OUTBOX`, and the global instructions (`agents-AGENTS.md`)
tell agents about them.

The agent can create files in `outbox/` but can't list, read, or delete
them, so it can't read back what it gave you. It *can* overwrite a file
it wrote, since write-only access includes writing; so don't treat an
outbox file as final until the session's over.

### Ports: local-ports and expose-ports

Each compartment has its own loopback, so an agent's servers can't
clash with, or be reached by, another compartment's. But nono still
refuses any loopback port it isn't told to open, since it doesn't know
the namespace is private. Two files in `policy/` list ports, one port
number per line (e.g., `8089`); lines starting with `#`, and blank
lines, don't count. So `echo 3000 >> ~/projects/NAME.dossier/policy/expose-ports`
exposes a port. `bulkhead-workspace prepare` creates both, with only
comments:

- `local-ports`: ports the agent may use on its own loopback (connect
  and listen), e.g., for its tests' servers. Nothing outside the
  compartment can reach them.
- `expose-ports`: ports the agent may also use, and that you can reach
  from the VM at `127.0.0.1:PORT`, e.g., a dev server you open in a
  browser. pasta listens on the VM's `127.0.0.1` only and forwards to
  the agent's server.

`compart` reads and checks both (a line that isn't a port from 1 to
65535, without leading zeros, stops the launch). It turns both into
nono's `--open-port`, and `expose-ports` into `bulkhead-compartment`'s
`--expose-port`, which becomes pasta's `--tcp-ports 127.0.0.1/PORTS`.

Warnings about `expose-ports`:

- Every process on the VM outside a compartment can reach an exposed
  port, not just you.
- Other compartments can't, since their `127.0.0.1` is their own, with
  one exception: a port a harness needs forwarded in (`--forward-port`,
  e.g., `compart pi`'s for the local AI engine, `INFER_PORT`). If you expose
  that port, the other compartment's harness reaches this agent's
  server instead of the real service. Don't expose a port some VM
  service uses.
- The agent's server takes the port on the VM while it runs, so a VM
  program that wants it gets "address in use", and vice versa (then
  pasta fails to start, and the agent with it).
- Changes take effect at the next launch.

## How it's built

`compart` starts every agent like this:

```
compart claude → anon-access → pasta → bwrap → nono run → claude
```

Each layer does a different job, and each backs up the others:

| Layer | Answers | Mechanism |
|---|---|---|
| `compart`, `anon-access` | What does the agent start with? | prepare the dossier, build arguments, strip secrets |
| pasta | What network exists at all? | user, network, and PID namespaces |
| bwrap | What is each path? | a nested user namespace and bind mounts |
| nono | What may the agent touch? | Landlock, seccomp, and a filtering proxy |
| nftables | Where may the VM send traffic? | the VM's firewall (ports 22, 53, 80, 443, and the secrets server) |

We wrote as little of this as we could. Each of pasta, bwrap, and nono
does one job we'd otherwise have to build and maintain, and all three
are packaged, maintained tools that run without root:

- **pasta** gives each run its own network: a private loopback and
  process list, with a route out to the web but no view of the VM's
  own services. We'd otherwise write port relays and DNS plumbing
  (we tried; see "Why nono doesn't make the namespace").
- **bwrap** decides what some paths *are*: it mounts the compartment's
  own `/tmp`, `~/.claude`, and so on over the shared ones, and makes
  shared setup read-only. It's the only layer that can change what a
  path refers to; it doesn't limit access.
- **nono** decides what the agent may *do*: which files it may read or
  write, which sites, methods, and paths it may reach, and which
  sockets it may open. It does that from profiles (data), and ships
  maintained profiles for each harness. It saves us the most work:
  we'd otherwise write a filtering proxy, Landlock and seccomp rules,
  and per-harness policy.

Where they overlap, they back each other up. bwrap alone wouldn't stop
an agent from reading the rest of your home, and nono alone wouldn't
stop two projects' agents sharing `/tmp` or `~/.claude`. If the proxy
were bypassed, pasta would still block the VM's local services and
nftables would still limit ports; without pasta, Landlock would still
refuse connections to those services, though the agent could list
them again.

The sections below say how each one is set up.

### compart and anon-access

`compart` runs one harness's setup (see its `case`), then
`bulkhead-workspace prepare`, which finds the current directory's
workspace and creates its dossier. It refuses a directory no agent may
start in: anything matching `workspace-forbidden` (e.g., `~`,
`~/projects` itself, dot directories, a dossier, `/tmp`), a workspace
at or above `~`, or one that holds another workspace's dossier.

`compart` then builds the harness's `nono run` command, adding:

- `--extends bulkhead-broad` outside `~/sensitive` (broad GET and HEAD).
- `--log-file` in the dossier's `logs/`, outside every sandbox grant.
- `--read DOSSIER/inbox`, `--write DOSSIER/outbox`, and an
  `--open-port` for each port in `DOSSIER/policy/local-ports` and
  `expose-ports`.

It runs that through `anon-access`, with options for
`bulkhead-compartment`: an `--expose-port` for each port in
`expose-ports`, and a `--forward-port` for each VM port the harness
needs (e.g., `compart pi`'s for the AI engine), so pasta forwards that
VM port in. The dossier's `local-ports` aren't forwarded: they're for
the agent's own servers.

`anon-access` works for any command, not only a harness (e.g.,
`anon-access gh ...`, or your shell when you give no command). It runs
`bulkhead-workspace prepare` too, strips credentials from the
environment, and runs `bulkhead-compartment` with the command.

### pasta: the network namespace

pasta's job is to give each run a network of its own that still has a
route out. A new network namespace alone has no route out, and the
agent needs one to reach nono's proxy's upstream; sharing the VM's
namespace would let the agent see (in `/proc/self/net`) and try every
service listening on the VM. pasta makes the namespace and connects it
to the outside through ordinary sockets on the VM, forwarding only what
we ask. It also forwards DNS, and its PID namespace hides the VM's
other processes.

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
  ports the agent listens on out to the VM. We forward none, except
  `--tcp-ports 127.0.0.1/PORTS` for the dossier's `expose-ports`. Then
  we add `--host-lo-to-ns-lo`, so these connections reach the
  namespace's `127.0.0.1`, where agents' servers usually listen.
  Without it, pasta sends them to the namespace's public address from
  the `--map-host-loopback` address, and since that's `none`, it drops
  them. It applies only to the ports `--tcp-ports` lists.
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

bwrap's job is to give each compartment its own copy of the paths
every harness writes to (e.g., `/tmp` and `~/.claude`), so one
project's agent can't leave something there for another's to read or
run. nono can only allow or deny a path, not redirect it, so without
bwrap every agent would share those paths. bwrap starts from the real
filesystem, so agents use the tools installed on the VM, and it leaves
access control to nono.

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
- `tmpdir`: `/tmp` becomes the current directory's `.tmp` (on disk),
  which is also the compartment's `TMPDIR`.

bwrap also mounts `netns-resolv.conf` (see above) and sets
`BULKHEAD_COMPARTMENT` to the compartment's key (`projects-NAME`,
`sensitive-NAME`, or `dir%PATH`). The state lives in the dossier, beside
the workspace rather than in it, so it can't arrive with a workspace's
contents, and nono doesn't grant the agent the dossier directly.

Anything a harness writes that another compartment could read or run
belongs in `compartment-paths`; list every harness's paths there.

### nono: what the agent may touch

nono's job is to limit what the agent can touch, from policy written as
data. It runs inside bwrap and sandboxes the harness with Landlock and
seccomp, using its shared `default` profile (`nono-default-profile.json`)
plus the harness's pack and small profile (e.g., `bulkhead-claude`).

Without nono, we'd have to write and maintain all of this ourselves:

- **A filtering proxy.** It allows only listed sites and, per site,
  only listed HTTP methods and paths; to see those inside HTTPS it
  terminates TLS with a per-session certificate authority. Landlock
  then makes sure the agent can't go around it.
- **Filesystem rules.** bwrap could build an allowlisted view by
  mounting only granted paths, but we'd have to write code turning a
  policy into mount arguments. Landlock checks every access by path,
  independently of mounts, so a mount mistake (or
  `BULKHEAD_NO_COMPARTMENT=1`) still doesn't expose your home
  directory.
- **seccomp rules**, e.g., refusing UDP sockets.
- **Per-harness policy.** nono's packs (e.g., `nolabs-ai/pi`) already
  list what each harness needs, and profiles can `extends` one
  another, so we write only a shared default and a small profile per
  harness.
- **Diagnosis.** `nono why` explains any denial.

Files:

- The workspace and the paths the profiles grant; the rest of home is
  denied.
- `/tmp`, read and write. bwrap makes it the compartment's own, so
  reading it can't reveal another compartment's files. nono alone
  grants only write there, so tools that hard-code `/tmp` (ignoring
  `TMPDIR`) couldn't read back their own files.
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
  can't connect to one made outside it. (pasta's network namespace
  separates them too, since abstract sockets belong to a network
  namespace.)

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

- `BULKHEAD_NO_COMPARTMENT=1`: skip bwrap and pasta entirely. nono still
  runs, but compartments share `/tmp`, `~/.claude`, and so on. Since
  the default profile grants reading `/tmp`, the agent can then read
  the VM's shared `/tmp`, too.

It prints a warning. Use it only to work around a breakage.

## Known gaps

- nono still refuses loopback ports that aren't opened, even though
  the namespace is private, because it doesn't know that. So list an
  agent's own server ports in its dossier's `policy/local-ports`. A nono
  option to allow all loopback ports in a namespace it didn't make
  would close this.
- No snapshots: nothing keeps a copy of the workspace that its agent
  can't change, to undo its damage. nono's rollback snapshots don't
  qualify, since `--rollback-dest` must be a directory the sandbox can
  already write. We'd have to take our own, outside the sandbox, at
  launch.
- An agent can't read its own `policy/`, so it can't see why something
  is allowed; `nono why --self` usually explains it.
- An agent can't install or change shared setup from inside a
  compartment, since it's read-only there. E.g., goose can't install a
  plugin into `~/.agents/plugins`, and Claude can't add a skill to
  `~/.claude/skills`. Do that from outside any compartment (e.g., run
  the harness's install command in a plain shell), and every
  compartment then sees it.
- nono's error message for the AppArmor denial points to the wrong
  cause; it's worth reporting upstream.

## Testing

`./ci.sh` checks the workspace refusals, that
`bulkhead-workspace prepare` makes the dossier and notices moves, the
arguments `bulkhead-compartment` builds (with `--dry-run`), including
that pasta forwards nothing unless asked, and the command line
`compart claude` builds (with a stand-in `anon-access`), including the
port lists. `tests/compartment-test.sh` runs
real compartments; run it by hand in a VM, outside any sandbox (bwrap
can't run inside nono). It checks the file isolation, the inbox and
outbox, that an agent can't see or reach the VM's loopback services,
that a compartment keeps your uid and `TMPDIR`, that names resolve in
the compartment, that a forwarded port works and an unforwarded one
doesn't, that you can reach an exposed port and another compartment
can't, that an agent reaches an allowed site through nono's proxy,
and that abstract sockets stay apart.
