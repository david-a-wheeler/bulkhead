# AGENTS.md

Notes for AI coding agents working on this repo.

## What bulkhead is

Setup scripts for running AI coding agents safely: a macOS host runs
Linux guest VMs (via UTM), and agents run inside those VMs under the
nono sandbox. The host holds every secret (in Keychain) and releases one
only after a human approves it; VMs never store long-lived credentials.
The host can also run a sandboxed local inference engine (llama-swap)
that VMs reach through SSH tunnels. VMs run Ubuntu today, but keep
VM-side code portable where it's practical.

Don't read the long docs up front; look things up as you need them:

- `README.md`: its "Files" section says what each file does.
- `architecture.md`: why the security design is the way it is.
- `local-ai-plan.md` (long): the inference engine's design notes and
  history. Read only the section you need.
- `model-candidates.md`: notes on candidate models. Rarely relevant.

You're probably running inside one of those VMs, under nono, right now.
So you can't run the host-side scripts (they're macOS-only), and you
can't get secrets: `noclaude` strips `BULKHEAD_AUTH_SESSION` on purpose,
so `git push`, `gh-session`, and similar calls fail for you. That's the
design working, not a bug to fix.

## The setup scripts are idempotent

`host-setup.sh` (host) and `vm-setup.sh` (each VM) are safe to re-run
any time; they converge the machine to match `config.sh` (plus any
`config.local.sh`). Keep it that way:

- Check before you change: skip work that's already done, and don't
  rewrite a file whose content wouldn't change.
- Use `common.sh`'s helpers (e.g., dotfile block insertion,
  `git_config_set`, `install_unless_locally_newer`) rather than
  appending or overwriting directly.
- Cleanup of older layouts must be harmless when there's nothing to
  clean up.

## Setup scripts can break a running nono sandbox

nono binds some grants at sandbox start: a single-file grant (e.g.,
`~/.gitconfig`) follows the file's inode, and a granted directory that
didn't exist then stays denied. So replacing such a file by rename
(e.g., `git config --global`) or creating such a directory causes
`Permission denied` afterward. The fix is for the human to restart the
session; don't edit the nono profile or `chmod` around it. Don't run
`vm-setup.sh` unless asked, and if you do, say a restart may be needed.

## Testing: ci.sh

Run `./ci.sh` after every change (GitHub CI just runs the same script).
It runs shellcheck, `dash -n`, template rendering, awk lint, `tests/`,
and the Python unit tests. It needs shellcheck, dash, jq, node, gcc, and
Python with PyYAML (gawk optional). Add any new plain script to its
`PLAIN_SCRIPTS` list.

## Conventions

- Shell scripts are POSIX `sh`; awk programs are POSIX awk.
- A `*.template.*` file gets `@@VAR@@` placeholders substituted before
  install; anything else is copied or run as-is.
- Put long embedded programs (awk, jq, Python) in their own files, so
  they can be linted and tested on their own.
- Don't commit the gitignored per-machine files `config.local.sh` and
  `models.local.yaml`.
- Temporary files go in the repo directory with a `,` prefix, not `/tmp`.
- Prefer existing, trusted tools over new code; avoid needing root.
- Prose (docs, comments, commit messages) is concise and plain: no em
  dashes, no hype, no AI-writing filler. `check-prose-style.sh` enforces
  common cases. `claude-CLAUDE.md` is the VMs' global instructions for
  every project; it's here only so `vm-setup.sh` can install it.
- Don't push. The human decides what's ready to share.
