# Plan: workspaces and their .meta directories

Status (2026-11-20): draft, not implemented. Builds on the compartments
in `bulkhead-compartment` (see `,restart-notes.md` for their tests).

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

Each workspace `DIR` gets a sibling `DIR.meta`, created at launch:

| Path | Agent's access | Holds |
| --- | --- | --- |
| `DIR.meta/workspace` | none | `DIR`'s real path when last launched |
| `DIR.meta/state/` | read-write, via bwrap (same as today) | what `DIR/.bulkhead` holds today |
| `DIR.meta/logs/` | none | `nono.log` and its one rotated copy |
| `DIR.meta/policy/` | none | your additions, e.g., a nono profile fragment |

`DIR.meta` is mode 700. nono grants the workspace (`--allow-cwd`) and
its profiles' paths, none of which cover a sibling, so "none" needs no
new rule. `state` keeps today's mechanism: bwrap binds its
subdirectories over `~/.claude` and the rest of `compartment-paths`.
Each subdirectory's name says its access, so the code maps it
mechanically. The shared Claude credentials stay where they are
(`~/.local/state/bulkhead/claude-credentials`): they're shared by
design, not per workspace.

Why a sibling: when you move or delete `DIR`, `ls` shows `DIR.meta`
right beside it. The cost is that `ls ~/projects` doubles, and a loop
over `~/projects/*` sees each `.meta`.

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
contents, so in `.meta` the harness's state comes only from the
harness, and we can drop that check.

It also keeps ordinary workspace tools from treating the state as
project files: `git clean -fdx` would delete your transcripts and
memory, and archiving or `rsync`ing the project to share it would
copy transcripts that may hold secrets you pasted.

The cost: `state/` no longer moves with `DIR` by itself. `logs/` and
`policy/` already make the `.meta` something you must move with `DIR`,
so this adds nothing new to remember.

## Choosing and checking the workspace

`bulkhead-compartment-info` computes the workspace root as it does now
(`~/projects/NAME` or `~/sensitive/NAME` for anything under them, else
the current directory), and gains a `meta` field. Then, before
anything else starts:

1. **Refuse forbidden directories.** Check both the root and the
   current directory against a data file, `workspace-forbidden`, of
   shell `case` patterns, one per line, e.g.:

   ```
   ~/projects
   ~/sensitive
   ~/.*
   *.meta
   *.meta/*
   ```

   Also refuse `~` and any ancestor of it (`/`, `/home`): that's one
   `case` test in code, since an agent there would be granted every
   workspace and every `.meta`. `~/.*` keeps an agent out of
   `~/.ssh`, `~/.config`, and the like. Anything else, e.g., `~/junk`,
   is fine if the rest of these checks pass.
2. **Refuse if a registered `.meta` is inside the root.** If
   `~/junk/sub` is a workspace, an agent started in `~/junk` could
   change `~/junk/sub.meta`. So at creation we append each `.meta`'s
   path to a registry, `~/.local/state/bulkhead/workspaces` (one path
   per line, outside every grant), and refuse a root that contains
   any of them. That's a `grep`, with no walk of the tree.
3. **Require write access.** If you can't write the root, or can't
   create `DIR.meta` and its subdirectories, fail with a message
   saying which. No fallback location for now; that keeps it simple.
4. **Notice moves.** If `DIR.meta/workspace` names another path, say
   so and update it (you moved both; that's fine). If `DIR.meta` is
   new, say so, and add "if you moved this workspace, move its old
   `.meta` beside it". `vm-setup.sh` lists registered `.meta`
   directories whose workspace is gone.

The `.meta` and its subdirectories must exist before nono starts:
nono binds grants at sandbox start, so a directory created later
stays denied.

Where the code goes: `anon-access` already runs every harness's
command, so steps 1 to 4 go there (or in `bulkhead-compartment-info`,
called from there), and every harness gets them. `nopi`'s port would
move to `policy/` later, once we know nono can take a profile
fragment by path through `--extends` (to check).

## Migration

At launch, outside the sandbox: if `DIR.meta` doesn't exist and
`DIR/.bulkhead` does, move `.bulkhead`'s contents (less its
`.gitignore`) to `DIR.meta/state`, and move
`~/.local/state/bulkhead/logs/KEY` to `DIR.meta/logs`. Both are
harmless when there's nothing to move. Then drop the `.bulkhead`
code, the git-tracked check, and the logs directory's grant notes.

## Tests

- `ci.sh`: `bulkhead-compartment-info` refusals (each forbidden
  pattern, `~` and its ancestors, a registered `.meta` inside the
  root, an unwritable root), plus `--dry-run` showing binds from
  `DIR.meta/state`.
- Outside nono, on the VM: `tests/compartment-test.sh` extended to
  migrate a workspace with an old `.bulkhead`, then check that an
  agent can't read `DIR.meta/logs` or `DIR.meta/policy` and can't
  write `DIR.meta/workspace`.

## Open questions

- Should the agent get read-only access to `policy/`, so it can see
  why something's allowed? `nono why --self` may be enough.
- Should `.tmp` and `.cache` (today in the current directory, from
  `anon-access`) move to `state/`? They're agent-owned, so the
  workspace is fine; moving them would only tidy it.
- The registry trusts that every `.meta` was made by our code. A
  `.meta` you make by hand isn't registered, so step 2 can't see it.

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
