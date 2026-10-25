# AGENTS.md

Notes for AI coding agents working on this repo. Read `README.md` first
(what each file does) and `architecture.md` (why it's built this way).

## What bulkhead is

Setup scripts for running AI coding agents safely: a macOS host runs
Linux guest VMs (via UTM), and agents run inside those VMs under the
nono sandbox. The VMs run Ubuntu today, and that's what we build and
test for, but we may use other distributions later, so keep VM-side
code portable where it's practical (e.g., don't assume an Ubuntu-only
path or tool when a portable one works as well). The host holds every secret (in Keychain) and releases one
only after a human approves it; VMs never store long-lived credentials.
The host can also run a sandboxed local inference engine (llama-swap)
that VMs reach through SSH tunnels; see `local-ai-plan.md`.

You're probably running inside one of those VMs, under nono, right now.
So you can't run the host-side scripts (they're macOS-only), and you
shouldn't try to get secrets: `noclaude` strips `BULKHEAD_AUTH_SESSION`
on purpose, so `git push`, `gh-session`, and similar calls fail for you.
That's the design working, not a bug to fix.

## The setup scripts are idempotent

`host-setup.sh` (on the macOS host) and `vm-setup.sh` (on each Linux
VM) are safe to re-run any time. They converge the machine to match
`config.sh` (plus any `config.local.sh`), and never accumulate changes.
Keep it that way when you edit them:

- Check before you change: skip work that's already done, and don't
  rewrite a file whose content wouldn't change.
- Use `common.sh`'s helpers (e.g., block insertion into dotfiles,
  `git_config_set`, `install_unless_locally_newer`) rather than appending
  or overwriting directly.
- Cleanup of leftovers from older layouts is fine, but it must be
  harmless when there's nothing to clean up.

## Running the setup scripts can break a running nono sandbox

nono decides at sandbox start what you can reach, and it binds some
grants to the filesystem objects that exist then. A single-file grant
(e.g., `~/.gitconfig`) follows the file's inode, and a directory that
didn't exist at start stays denied even after it's created. So if
`vm-setup.sh` (or anything else) replaces such a file by rename, or
creates a newly granted directory, you'll get `Permission denied` on
it afterward. For example, `git config --global` replaces `~/.gitconfig`,
after which every git command in the sandbox fails.

The fix is for the human to restart the agent's session under nono.
Don't edit the nono profile or `chmod` things to work around it. Don't
run `vm-setup.sh` yourself unless asked; if you are, expect to need a
restart afterward and say so.

## Testing: ci.sh

`./ci.sh` is the CI test script: shellcheck, `dash -n` syntax checks,
template rendering, awk lint, the logic tests in `tests/`, and the
Python unit tests. The GitHub Actions workflow
(`.github/workflows/ci.yml`) just runs it, so a local run checks the
same things. It runs on Linux, including inside a VM, given shellcheck,
dash, jq, node, gcc, and Python with PyYAML (gawk is optional; without
it the awk lint is skipped). Run it yourself after every change; don't
wait for GitHub's CI run to find problems. Also add a new plain script to its `PLAIN_SCRIPTS`
list so it gets checked too.

## Conventions

- Shell scripts are POSIX `sh` (checked with `dash -n` and shellcheck),
  since they must run on macOS and on more than one Linux distribution.
  Awk programs must be POSIX awk.
- A `*.template.*` file gets rendered (`@@VAR@@` placeholders
  substituted) before install; anything else is copied or run as-is.
- Put long embedded programs (awk, jq, Python) in their own files, so
  they can be linted and tested on their own.
- Per-machine files are gitignored: `config.local.sh` and
  `models.local.yaml`. Don't commit them.
- Temporary files go in the repo directory with a `,` prefix (also
  gitignored), not in `/tmp`.
- Prefer existing, trusted tools over new code, and don't add code that
  needs root unless there's no other way.
- Prose (docs, comments, commit messages) is concise and plain: no em
  dashes, no hype, and no AI-writing filler phrases.
  `check-prose-style.sh` rejects common cases (as a Claude Code hook,
  and via `git-commit-msg` for commit messages). `claude-CLAUDE.md` is
  the VMs' global instructions for every project, not just this one;
  it's in this repo only so `vm-setup.sh` can install it.
- Don't push. The human decides what's ready to share.
