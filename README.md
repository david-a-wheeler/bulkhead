# bulkhead

Setup for a host + guest VM setup for running AI coding agents safely.
Currently supported: macOS host, Ubuntu Linux guest (via UTM). See
[architecture.md](architecture.md) for the why.

## Usage

This repo is meant to be a git checkout on the host and on every VM. To
bring a machine's config up to date with what's checked in:

```
git pull
./host-setup.sh   # on the macOS host
./vm-setup.sh     # on each Ubuntu VM (lftux, mytux, ...)
```

Both scripts are safe to re-run any time: they converge the machine to
match `config.sh`, never accumulate changes. Neither touches secrets.
Re-running after any change (a new VM, an edited `config.sh`, a rotated
secret) is always just "repeat the relevant steps below"; nothing here is
destructive or accumulates state.

### First-time setup (order matters)

A few pieces depend on each other, so the first pass needs this order:

1. **On each VM**: `git pull && ./vm-setup.sh`. Installs `qemu-guest-agent`
   (step 2 needs it) and wires up the git credential helper: `git
   push`/`fetch` won't actually succeed yet, since the secrets server has
   no secret to give out until step 3.
2. **On the host**: `./host-setup.sh`. Starts the secrets server, generates
   the host's SSH key, builds `~/.ssh/config` from `utmctl` (now that
   qemu-guest-agent is running from step 1), and pushes the key straight to
   each VM with `ssh-copy-id`. It'll ask for that VM's login password once
   per VM; after that, key auth just works. No commit, no second VM pass.
3. **On the host**: `./host-secrets.sh set GH_TOKEN`. Without
   this, every `git push`/`fetch` from a VM gets denied (no secret in
   Keychain to release), and so does `gh-session gh ...` (`gh` reads the
   same secret; see architecture.md's Secrets Server section).

After that: `ssh lftux`/`scp x lftux:` works from the host, and a human
shell's `git push`/`git fetch` on a VM triggers a host approval prompt (a
macOS dialog today) and succeeds; the same command run via `noclaude`
fails immediately instead (see architecture.md's Secrets Server section).

Want Heroku access from a VM too? `./rotate-heroku-key.sh` (set
`config.sh`'s `HEROKU_API_KEY_VM` first to lock it to one VM), then
`heroku-session` on the VM; see architecture.md's Secrets Server section.
Optional, and independent of the git setup above.

Adding a new VM later: create it in UTM, then just repeat step 1 (on the
new VM) and step 2 (on the host); no `config.sh` edits, no commits needed,
and steps you've already done for other VMs (like the Keychain secret in
step 3) already cover it.

**If `ssh <vmname>` still doesn't work** after all of the above: `utmctl
ip-address` depends on UTM's QEMU Guest Agent channel being enabled for
that VM (usually on by default for UTM-created VMs). Check the VM's
Settings > QEMU in UTM if it's not showing up in `~/.ssh/config`. If
`ssh-copy-id` failed for a VM (host-setup.sh prints a warning naming it),
re-run `./host-setup.sh` once the VM's actually reachable.

## Network egress is restricted

VMs can only reach a handful of outbound ports by default: SSH (22),
HTTP/HTTPS (80/443), DNS, and the host secrets server; see `config.sh`'s
`NFTABLES_ALLOWED_TCP_PORTS`. This is deliberate (see architecture.md's
Security Controls Summary), not a bug. If something inside a VM can't
reach the network and you're not sure why, this is the first thing to
check. Add the port to `NFTABLES_ALLOWED_TCP_PORTS` in `config.sh` and
re-run `vm-setup.sh`, rather than disabling nftables to work around it.

## Files

- `config.sh`: person/machine-specific values (name, email, ports, ...).
  Reusing this repo for your own setup? Rather than editing this tracked
  file, copy `config.local.sh.example` to `config.local.sh` (gitignored)
  and set overrides there. `config.sh` sources it last, so anything set
  there wins, and your `git pull`s of this repo stay clean.
- `common.sh`: shared shell functions (`host-setup.sh`/`vm-setup.sh` source
  it): template rendering, idempotent block-insertion into dotfiles, git
  config niceties, and a "don't clobber a locally-edited file" install helper.
- `host-backend.sh`: the host-side calls that are specific to *how* this
  host stores secrets and enumerates guests (`store_secret`,
  `retrieve_secret`, `secret_exists`, `delete_secret`, `enumerate_guests`),
  named after what they do rather than how. Today there's exactly one
  implementation of each (macOS Keychain, UTM's `utmctl`); see
  architecture.md's "Currently supported" note.
- `host-setup.sh`: host setup (macOS today).
- `secrets-server.template.py`, `com.user.secretsserver.template.plist`:
  the host-side secrets server (see architecture.md) and its LaunchAgent.
  Serves any secret `host-secrets.sh` has stored under Keychain's
  `KEYCHAIN_PREFIX` (`bulkhead-` by default; see `config.sh`); that
  prefix is what marks a secret as servable at all, nothing else to
  declare. Logs one JSONL record per request (approved/denied/errored,
  never the secret itself) to `/tmp/secrets-server.log`, flushed
  immediately; `tail -f` it while diagnosing.
- `host-secrets.sh`: add/rotate/delete the named secrets `secrets-server.py`
  serves. Include `@vm-hostname` in a name to lock that secret to one
  specific VM instead of leaving it available to any of them; include a
  trailing `!` to mark it as releasable without a human approval dialog
  (the two compose: `name@vm-hostname!` is both). Every secret defaults
  to requiring approval, so this only ever happens by deliberately
  choosing that name (e.g. `host-secrets.sh set 'GH_PUBLIC_TOKEN!'`).
  `list` shows every currently servable secret, `!` and all, scanning
  Keychain directly rather than relying on a declared list. `set` accepts
  a bare Enter to leave an already-existing secret unchanged, so a script
  rotating several secrets in one run (see `rotate-github-pat.sh`) can
  skip the ones that haven't actually expired.
- `rotate-github-pat.sh`: rotates both GitHub PATs this repo stores, one
  after another: `GH_TOKEN` (backs git's HTTPS auth and `gh`, since `gh`
  reads a token straight out of the `GH_TOKEN`/`GITHUB_TOKEN` env vars, no
  `gh auth login` involved) and `GH_PUBLIC_TOKEN` (a "Public Repositories
  (read-only)" fine-grained PAT `anon-access` uses so `gh` works for a
  sandboxed AI agent reading public data, without ever handing it real
  access; see architecture.md's Secrets Server section). Doesn't touch
  `config.sh` or the currently active secrets, so there's no window where
  switching too early could break `git push`; press Enter at either
  prompt to leave that one secret alone if it hasn't actually expired.
- `rotate-heroku-key.sh`: same idea as `rotate-github-pat.sh`, for
  `HEROKU_API_KEY`. Set `config.sh`'s `HEROKU_API_KEY_VM` to store it
  locked to one VM instead of available to any of them. Once you've
  confirmed the new key works, it also finds and revokes any older Heroku
  authorization for you (via `heroku-session`, so it never touches
  `~/.netrc`), since a fresh one gets minted every time and the old one
  would otherwise stay valid.
- `vm-setup.sh`: guest VM setup (Ubuntu today).
- `vm-git-helper`: the VM-side git credential helper. Plain file, not a
  template: git invokes it as `vm-git-helper NAME get|store|erase`, with
  `NAME` baked into a `credential.<url>.helper` config line per host by
  `vm-setup.sh` (from `config.sh`'s `GIT_SECRETS`), so it never has to
  parse git's own stdin protocol or carry a host->name lookup table
  itself; `store`/`erase` are no-ops, `get` shells out to
  `secrets-client --get` below.
- `secrets-client.template.py`: generic VM-side CLI for fetching any named
  secret from `secrets-server.py`, installed without a `.py` extension
  (`secrets-client`, not `secrets-client.py` - callers shouldn't need to
  know this happens to be Python). `secrets-client [--as ENV_NAME]
  [--context TEXT] NAME [COMMAND...]` fetches `NAME` once (one approval
  dialog) and runs `COMMAND` (default: an interactive `$SHELL`) as a
  *child* process with the secret set under `NAME` (or `ENV_NAME`, with
  `--as`) only there, so a burst of commands needs one click instead of
  one per command, and the secret is gone again once you exit; the
  default `--context` shown in the dialog is `COMMAND` itself (or
  `$SHELL`). `secrets-client --get NAME` prints the secret to stdout
  instead, without running anything - this is what `vm-git-helper` and
  `anon-access` build on.
- `heroku-session`, `gh-session`: two-line wrapper scripts
  (`exec secrets-client HEROKU_API_KEY/GH_TOKEN "$@"`) - thin, memorable
  names for `secrets-client`'s two current recurring callers. Add another
  one the same way for a new recurring secret; a once-off use can just
  call `secrets-client NAME ...` directly.
- `anon-access`: strips auth-related env vars (`SSH_AUTH_SOCK`,
  `BULKHEAD_AUTH_SESSION`, `HEROKU_API_KEY`, GitHub Enterprise
  tokens) before running a command, or an interactive shell if none
  given; a blocklist, not an allowlist, by design (see the script's own
  comment for why). Replaces `GH_TOKEN`/`GITHUB_TOKEN` rather than merely
  unsetting them, with `GH_PUBLIC_TOKEN` fetched from `secrets-server.py`
  (stored as `GH_PUBLIC_TOKEN!`; see `host-secrets.sh`'s trailing-`!`
  no-confirmation naming convention), since `gh` refuses to run at all
  without some token, even for public data.
  Part of a move toward small, single-purpose, any-shell-callable files
  instead of bash-only functions in `vm-bash-aliases-block.sh`; `noclaude`
  below is the first caller.
- `noclaude`: `exec anon-access nono run --profile nolabs-ai/claude
  --allow-cwd -- claude "$@"` (a handful of lines total). Running
  through `anon-access` gets the sandboxed agent every one of its
  protections (see above) for free, rather than `noclaude` maintaining
  its own separate, easy-to-forget-to-update env var list; it also means
  `gh` works for public reads inside the sandbox, same as any other
  `anon-access` caller. `--profile nolabs-ai/claude` is nono's own
  maintained profile for Claude Code (installed by `vm-setup.sh`),
  rather than a hand-rolled `--allow` list this repo would have to keep
  in sync with what Claude Code actually needs at runtime. Plain
  executable file, not a bash function: any shell can run it.
- `nono-default-profile.json`: filesystem access every nono-sandboxed
  harness should have beyond what its own pack grants (currently
  `~/.rbenv` and `~/.gitconfig`). Installed by `vm-setup.sh` to
  `~/.config/nono/profiles/default.json`, nono's own reserved "default"
  profile name; `nolabs-ai/claude` and every other pack below already
  declares `"extends": "default"`, so this one file covers all of them,
  not just `noclaude`. Same `install_unless_locally_newer` treatment as
  `claude-CLAUDE.md` below: an edit made straight to the installed copy
  isn't silently overwritten.
- `nftables.template.conf`: VM egress firewall ruleset.
- `vm-bash-aliases-block.sh`: the managed block installed into each VM's
  `~/.bash_aliases`: editor and `BULKHEAD_AUTH_SESSION`. Not a
  template (nothing left to substitute since `noclaude` moved out to its
  own file above). Bash-only for now: a shell like zsh doesn't source
  `~/.bash_aliases` by default; supporting another shell would mean a
  separate file in that shell's own syntax, not just installing this one
  elsewhere.
- `claude-CLAUDE.md`: global Claude Code instructions, installed to each
  VM's `~/.claude/CLAUDE.md` (Claude Code runs in the VMs, not on the host,
  so this isn't installed by host-setup.sh). If you've edited the installed
  copy directly and it's newer than this file, vm-setup.sh warns instead of
  overwriting it; see the printed command to pull your edit back in here.
A `*.template.*` file gets rendered (placeholders substituted) before
install; anything else is copied or run as-is.
