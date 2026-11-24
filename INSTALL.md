# Installing bulkhead

This covers setting up the macOS host and its Ubuntu VMs. For what
bulkhead is and why, see [README.md](README.md); for what each file
does, see [FILES.md](FILES.md).

## What you need

- A Mac (Apple silicon, for the local AI engine), running UTM.
- One or more Ubuntu VMs in UTM, each with your own login. One can be
  your "secure" VM, for sensitive work (`config.sh`'s
  `INFER_SECURE_VM`).
- This repository, checked out on the Mac and in each VM. To change
  settings for your own machines (your name, VM names, ports), copy
  `config.local.sh.example` to `config.local.sh` and edit that, rather
  than `config.sh`.

## Keeping machines up to date

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

## First-time setup (order matters)

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
macOS dialog today) and succeeds; the same command run via `compart claude`
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

## The local AI engine's API key

`host-setup.sh` creates the engine's API key in
`~/.config/bulkhead/infer-api-key` on the Mac (see `local-ai-plan.md`).
A VM can use the engine only if it has a copy of that file (and a
tunnel; see `infer-access.sh`). `vm-setup.sh` installs pi, `compart pi`,
and `infer-logs` on every VM, and creates the VM's `~/.config/bulkhead`.
`host-setup.sh` then copies the key into that directory on each running
VM, except those in `config.sh`'s `INFER_NO_KEY_VMS`, and restarts the
VM's `infer-logs`.

**To give a VM the key**, run `./vm-setup.sh` on it, then
`./host-setup.sh` on the Mac (in either order, but the VM must be
running when `host-setup.sh` runs).

**To rotate the key**, e.g., because it may have leaked (in a paste, a
log, or a command line) or to cut off a VM, run this on the Mac, from
this repo:

```
rm -f ~/.config/bulkhead/infer-api-key
./host-setup.sh
```

`host-setup.sh` creates a new key, restarts the engine with it (so
every VM's old key stops working), and copies the new key to each
running VM as above. A VM that's stopped then gets it the next time you
run `./host-setup.sh` while it's running. Restart any running
`compart pi`, since it reads the key when it starts. To cut a VM off,
first add it to `INFER_NO_KEY_VMS` (in `config.local.sh`), then rotate,
and delete its old copy: `rm ~/.config/bulkhead/infer-api-key`.

## Network egress is restricted

VMs can only reach a handful of outbound ports by default: SSH (22),
HTTP/HTTPS (80/443), DNS, and the host secrets server; see `config.sh`'s
`NFTABLES_ALLOWED_TCP_PORTS`. This is deliberate (see architecture.md's
Security Controls Summary), not a bug. If something inside a VM can't
reach the network and you're not sure why, this is the first thing to
check. Add the port to `NFTABLES_ALLOWED_TCP_PORTS` in `config.sh` and
re-run `vm-setup.sh`, rather than disabling nftables to work around it.

## The local AI engine's models

Each host has its own list of models, `models.local.yaml` (gitignored).
It starts as a copy of the repo's `initial-models.yaml`, and from then
on it's yours: `./manage-models.sh` adds, removes, and updates models
(including the initial ones) and sets the default, and
`./install-models.sh` has the engine serve the result. On a VM, `compart pi
--list-models` shows the generalists the engine serves now (specialists
don't appear, since pi can only chat), and `compart pi --model FOO` runs pi
against the model named FOO instead of the default.
