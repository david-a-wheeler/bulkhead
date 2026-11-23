# Plan: workspaces and their dossier directories

Status (2026-11-21): archived. It's implemented, and `compartments.md`
now documents what's live (the dossier's layout, how to use it, and how
it's built). This is the original plan, kept for its reasoning and its
lessons learned; parts are out of date (e.g., it says "today" about the
layout before dossiers).

## The problem

A *workspace* is a directory you start an agent in, e.g.,
`~/projects/FOO`, `~/sensitive/BAR`, or `~/junk`. The agent may change
anything in its workspace and read public files elsewhere (e.g.,
`/usr/bin`). But some data is *about* a workspace and must never be
under its agent's full control:

- logs of what the agent did (nono's log), which an agent could
  otherwise rewrite or erase;
- policy that grants the workspace extra access (e.g., a port to open,
  an extra host), which an agent could otherwise widen;
- the harness's private state (transcripts, `~/.claude`), which the
  agent may change, but which must come only from the harness itself,
  never from the workspace's contents (see "Why harness state moves").

Today that data is scattered: harness state is in the workspace's
`.bulkhead` (so we refuse one git tracks, and add a self-ignoring
`.gitignore`), logs are in `~/.local/state/bulkhead/logs/KEY`, and
there's no per-workspace policy at all (`nopi` hard-codes its port).

Everything runs as you, so the sandbox (nono and bwrap) is the only
thing keeping an agent away from this data. A grant must never cover
it.

## Design

Each workspace `DIR` gets a sibling `DIR.dossier`, created at launch:

| Path | Agent's access | Holds |
| --- | --- | --- |
| `DIR.dossier/workspace` | none | `DIR`'s real path when last launched |
| `DIR.dossier/state/` | read-write, via bwrap (same as today) | what `DIR/.bulkhead` holds today |
| `DIR.dossier/logs/` | none | `nono.log` and its one rotated copy |
| `DIR.dossier/policy/` | none | your settings for it, e.g., `local-ports` |
| `DIR.dossier/inbox/` | read-only (nono `--read`) | files you give the agent |
| `DIR.dossier/outbox/` | write-only (nono `--write`) | files the agent gives you |

`DIR.dossier` is mode 700. nono grants the workspace (`--allow-cwd`) and
its profiles' paths, none of which cover a sibling, so "none" needs no
new rule. `state` keeps today's mechanism: bwrap binds its
subdirectories over `~/.claude` and the rest of `compartment-paths`.
Each subdirectory's name says its access, so the code maps it
mechanically. The shared Claude credentials stay where they are
(`~/.local/state/bulkhead/claude-credentials`): they're shared by
design, not per workspace.

Why a sibling: when you move or delete `DIR`, `ls` shows `DIR.dossier`
right beside it. The cost is that `ls ~/projects` doubles, and a loop
over `~/projects/*` sees each dossier.

## Inbox and outbox

The inbox holds what you give an agent but don't want it to change,
e.g., a task description, a spec, or reference data. The outbox holds
what an agent gives you that doesn't belong in the workspace, e.g., a
proposed PR description. The agent can create files there but can't
read them back or delete them; it can still overwrite one it wrote,
since write-only access includes writing. `anon-access` sets
`BULKHEAD_INBOX` and `BULKHEAD_OUTBOX`, and `agents-AGENTS.md` tells
agents about them.

## Local ports

Agents on one VM could collude, reach the VM's own services, or learn
what's running, over local sockets. Tested in a Claude session under
nono 0.82:

- nono refuses TCP connect and listen, and UDP, on loopback, except
  ports it's told to open. So an agent can't even run its own test
  server on localhost.
- Connecting to an abstract Unix socket made outside the sandbox (the
  X server's `@/tmp/.X11-unix/X0`) fails with <code>E&#80;ERM</code>: Land&#108;ock scopes
  abstract sockets to the sandbox's own domain. Binding one works. Each
  nono sandbox is its own domain, so one agent shouldn't be able to
  connect to another's either (`tests/compartment-test.sh` checks).
- But `/proc/self/net/tcp` and `/proc/self/net/unix` list every
  listening port and abstract socket name on the VM. That's names, not
  data, but it tells an agent what else is running.

So each agent gets its own network namespace, where `/proc/self/net`
shows only its own sockets. nono's `--isolate net,loopback` would do
that, but it doesn't work here: nono runs inside
`bulkhead-compartment`'s bwrap, and Ubuntu's AppArmor profile for bwrap
runs everything bwrap starts under `unpriv_bwrap`, which denies every
capability, including the `CAP_SYS_ADMIN` nono needs to create the
namespace (even inside its own user namespace). nono then fails with a
misleading message blaming `kernel.apparmor_restrict_unprivileged_userns`.
We won't loosen that AppArmor profile; that would give nono more
privilege.

Instead, `bulkhead-compartment` runs bwrap under pasta (from `passt`,
the default network for rootless podman), which makes the namespace
before bwrap starts. We tell pasta to forward no ports either way, and
not to map any address to the VM's loopback, so the VM's local
services are out of reach. Its route out is no wider than the VM's
(nftables still applies), and inside it, nono's proxy and Land&#108;ock
still limit the agent. DNS goes to an address (`netns-resolv.conf`)
that pasta maps to the VM's resolver. A port the harness's wrapper
opens (e.g., `nopi`'s for the local AI engine) is a VM service, so
`anon-access` has pasta forward it in; that closes the gap where
`nopi` couldn't be isolated. The dossier's
`DIR.dossier/policy/local-ports` (one port or range per line, each an
`--open-port`) are for the agent's own servers, on its own loopback.

nono still refuses any loopback port that isn't opened, so an agent
can't run a test server on an arbitrary port without listing it. A
nono option to allow all loopback ports in a namespace it didn't make
would fix that.

We tried bwrap's own `--unshare-net`, relaying ports out over Unix
sockets, and nono's `--upstream-proxy` to a CONNECT proxy outside.
That worked, but needed more pieces (relays, a proxy, startup
ordering) than pasta, which does all of it.

## Snapshots (not yet)

A snapshot of the workspace that its agent can't touch would let you
undo an agent's damage. nono's rollback snapshots don't qualify: its
`--rollback-dest` must be a directory the sandbox can already write,
so an agent could change its own undo. We'd have to take our own,
outside the sandbox, at launch.

## Why harness state moves

`state/` gets the same access the agent has today in `.bulkhead`, so
moving it isn't about permissions. It's about where the data can come
from. Anything inside a workspace can arrive with its contents: a
tarball, a zip, a submodule, or a branch you check out. Today a
workspace's `.bulkhead` becomes the harness's private `~/.claude`, so
one planted there could hold:

- an `mcpServers` entry in `.claude.json`, which Claude Code runs at
  startup without asking you;
- an already-accepted folder-trust prompt, skipping the point where
  you'd normally decide whether to trust the folder;
- a `MEMORY.md` or transcripts, which the agent reads as its own
  trusted notes: prompt injection with extra credibility.

What these run stays inside the sandbox, but each skips a point where
you'd normally consent. Our only defense today is refusing a
`.bulkhead` that git tracks, which misses every other way files
arrive. A sibling directory can't arrive inside the workspace's
contents, so in the dossier the harness's state comes only from the
harness, and we can drop that check.

It also keeps ordinary workspace tools from treating the state as
project files: `git clean -fdx` would delete your transcripts and
memory, and archiving or `rsync`ing the project to share it would
copy transcripts that may hold secrets you pasted.

The cost: `state/` no longer moves with `DIR` by itself. `logs/` and
`policy/` already make the dossier something you must move with `DIR`,
so this adds nothing new to remember.

## Choosing and checking the workspace

`bulkhead-compartment-info` computes the workspace root as it does now
(`~/projects/NAME` or `~/sensitive/NAME` for anything under them, else
the current directory), and gains a `dossier` field. Then, before
anything else starts:

1. **Refuse forbidden directories.** Check both the root and the
   current directory against a data file, `workspace-forbidden`, of
   shell `case` patterns, one per line, e.g.:

   ```
   ~/projects
   ~/sensitive
   ~/.*
   *.dossier
   *.dossier/*
   ```

   Also refuse `~` and any ancestor of it (`/`, `/home`): that's one
   `case` test in code, since an agent there would be granted every
   workspace and every dossier. `~/.*` keeps an agent out of
   `~/.ssh`, `~/.config`, and the like. Anything else, e.g., `~/junk`,
   is fine if the rest of these checks pass.
2. **Refuse if a registered dossier is inside the root.** If
   `~/junk/sub` is a workspace, an agent started in `~/junk` could
   change `~/junk/sub.dossier`. So at creation we append each dossier's
   path to a registry, `~/.local/state/bulkhead/workspaces` (one path
   per line, outside every grant), and refuse a root that contains
   any of them. That's a `grep`, with no walk of the tree.
3. **Require write access.** If you can't write the root, or can't
   create `DIR.dossier` and its subdirectories, fail with a message
   saying which. No fallback location for now; that keeps it simple.
4. **Notice moves.** If `DIR.dossier/workspace` names another path, say
   so and update it (you moved both; that's fine). If `DIR.dossier` is
   new, say so, and add "if you moved this workspace, move its old
   dossier beside it". `vm-setup.sh` lists registered dossier
   directories whose workspace is gone.

The dossier and its subdirectories must exist before nono starts:
nono binds grants at sandbox start, so a directory created later
stays denied.

Where the code goes: `anon-access` already runs every harness's
command, so steps 1 to 4 go there (or in `bulkhead-compartment-info`,
called from there), and every harness gets them. `nopi`'s port would
move to `policy/` later, once we know nono can take a profile
fragment by path through `--extends` (to check).

## Decisions while implementing

- We call it a *dossier* (`DIR.dossier`), the first draft's `DIR.meta`.
  A dossier is the file an authority keeps about a subject, which the
  subject can't change: that's this directory's purpose. We rejected
  `.meta` (Unity puts a `.meta` beside every asset, and it says nothing
  about who controls it), `.bulkhead` (it names our implementation,
  not the purpose), verbs such as `.watch` and `.guard` (we wanted a
  noun), and `.casefile` (it collides with assurance cases).
- The registry lists workspace paths, not `.dossier` paths, one per line;
  the dossier is always the path plus `.dossier`. A registered workspace
  also becomes the root for its subdirectories (like `~/projects/NAME`),
  so `~/junk/sub` shares `~/junk`'s compartment. Step 2 only refuses a
  registered workspace whose `.dossier` still exists.
- A dossier must be a real directory you own (not a symlink), and
  `/tmp`, `/var/tmp`, `/dev/shm`, and everything in them are
  forbidden: another user could create `/tmp/x.dossier` before you.
- A refused directory fails in `anon-access` before anything else,
  including the secrets dialog for `GH_PUBLIC_TOKEN`. That also means
  any `anon-access` command (not just an agent) refuses `~`.
- Each compartment's `/tmp` is now its `$TMPDIR` (`compartment-paths`
  kind `tmpdir`), not a tmpfs: tools that hard-code `/tmp` then use
  the per-directory temp area, and on disk, not in the VM's RAM. It's
  bound only when `$TMPDIR` is inside the current directory, so a
  `TMPDIR=/tmp` can't bring the shared `/tmp` back.
- Migration only moves a `.bulkhead` that we made (its `.gitignore` is
  `*`), that git doesn't track, into an empty `state/`; otherwise it
  warns and leaves it. Exit every session in a workspace before its
  first launch with this code, since migration moves the state they
  use.

## Migration

At launch, outside the sandbox: if `DIR.dossier` doesn't exist and
`DIR/.bulkhead` does, move `.bulkhead`'s contents (less its
`.gitignore`) to `DIR.dossier/state`, and move
`~/.local/state/bulkhead/logs/KEY` to `DIR.dossier/logs`. Both are
harmless when there's nothing to move. Then drop the `.bulkhead`
code, the git-tracked check, and the logs directory's grant notes.

## Tests

- `ci.sh`: `bulkhead-compartment-info` refusals (each forbidden
  pattern, `~` and its ancestors, a registered dossier inside the
  root, an unwritable root), plus `--dry-run` showing binds from
  `DIR.dossier/state`.
- Outside nono, on the VM: `tests/compartment-test.sh` extended to
  migrate a workspace with an old `.bulkhead`, then check that an
  agent can't read `DIR.dossier/logs` or `DIR.dossier/policy` and can't
  write `DIR.dossier/workspace`.

## Open questions

- Should the agent get read-only access to `policy/`, so it can see
  why something's allowed? `nono why --self` may be enough.
- Should `.tmp` and `.cache` (today in the current directory, from
  `anon-access`) move to `state/`? They're agent-owned, so the
  workspace is fine; moving them would only tidy it.
- The registry trusts that every dossier was made by our code. A
  dossier you make by hand isn't registered, so step 2 can't see it.

## Lessons so far

For the eventual lessons-learned write-up:

- Separate an agent's data (its workspace, which it controls) from
  data *about* the agent (its logs and its grants). An agent must
  never control its own audit trail or its own permissions.
- Under one Unix user, the sandbox's grants are the only boundary, so
  check where an agent *starts*: starting in `~` or `~/projects`
  quietly grants everything below it.
- Refuse risky starting points instead of guessing what you meant;
  keep the list of them as data, so it's easy to review and extend.
- Decide where data lives by where it may *come from*, not only by
  who may write it. A harness's state inside the workspace can arrive
  with a download (e.g., a `.claude.json` with an `mcpServers` entry,
  or a planted `MEMORY.md`); state kept beside the workspace can't.
  Checking for git-tracked files catches only one way files arrive.
- Sandbox grants bound at start (nono's) mean "create it first, then
  launch"; a directory made later stays denied.
- Don't put anything security-relevant where other users can create
  files first (`/tmp` and friends), and check that a directory you
  rely on is yours and not a symlink.
- Test what a sandbox actually allows instead of assuming, and test
  the operation you're worried about: binding an abstract socket
  worked, which I first took to mean agents could connect to each
  other's, but connecting is scoped. What did leak was *viewing*:
  `/proc/self/net` lists the VM's sockets.
- A recovery mechanism the protected party can write (nono's rollback
  destination) doesn't protect you from that party.
- Keep one set of agent instructions (`AGENTS.md`) and give each
  harness a pointer to it, so harnesses can't drift apart.
- Write tests that run where CI runs: GitHub's `mktemp -d` is in
  `/tmp`, which the new refusals reject, so the tests use the repo's
  `.tmp` instead.
