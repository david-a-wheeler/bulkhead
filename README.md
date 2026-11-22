# bulkhead

Setup for a host + guest VM setup for running AI coding agents safely.
Currently supported: macOS host, Ubuntu Linux guest (via UTM). See
[architecture.md](architecture.md) for the why.

The host can also run a local AI engine (llama-swap, sandboxed) that VMs
reach through SSH tunnels; see [local-ai-plan.md](local-ai-plan.md). It
serves two roles of model, and runs at most one of each at a time
(see below). It's designed for zero data retention (ZDR): it never
writes your prompts or its replies anywhere, and keeps them only in RAM,
discarding them when the model unloads; see local-ai-plan.md's "Zero data retention
(ZDR)" for what that covers and what it doesn't. The roles:

- A **generalist** can chat (a llama-server model, e.g., Qwen3.8-27B).
  You'd normally keep one loaded; it unloads only after a day without
  requests, since reloading it means reprocessing your conversation.
- A **specialist** does something a generalist can't, such as making
  images (an sd-server model, e.g., FLUX.2-klein). It loads beside the
  generalist only when you ask for it, and unloads soon after (each sets
  its own `ttl`, at most an hour).

Requesting another generalist swaps out the current one, and likewise
for specialists. A model's role follows from its `cmd`.

Each host has its own list of models, `models.local.yaml` (gitignored).
It starts as a copy of the repo's `initial-models.yaml`, and from then
on it's yours: `./manage-models.sh` adds, removes, and updates models
(including the initial ones) and sets the default, and
`./install-models.sh` has the engine serve the result. On a VM, `compart pi
--list-models` shows the generalists the engine serves now (specialists
don't appear, since pi can only chat), and `compart pi --model FOO` runs pi
against the model named FOO instead of the default.

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

### The local AI engine's API key

`host-setup.sh` creates the engine's API key in
`~/.config/bulkhead/infer-api-key` on the Mac (see `local-ai-plan.md`).
A VM can use the engine only if it has a copy of that file; `vm-setup.sh`
sets up pi, `compart pi`, and `infer-logs` only on a VM that has one.

**To give a VM the key**, run this on the Mac, from this repo, after
changing `mytux` to the VM's name:

```
vm=mytux
ssh "$vm" mkdir -p .config/bulkhead
scp ~/.config/bulkhead/infer-api-key "$vm":.config/bulkhead/
```

Then run `./vm-setup.sh` on that VM.

**To rotate the key**, e.g., because it may have leaked (in a paste, a
log, or a command line) or to cut off a VM, run this on the Mac, from
this repo:

```
rm -f ~/.config/bulkhead/infer-api-key
./host-setup.sh
```

`host-setup.sh` creates a new key and restarts the engine with it, so
every VM's old key stops working. Then give the new key to each VM that
should keep using the engine, as above (including its `./vm-setup.sh`,
which restarts `infer-logs` with the new key). Restart any running
`compart pi`, since it reads the key when it starts. On a VM you're cutting
off, delete its old copy: `rm ~/.config/bulkhead/infer-api-key`.

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
- `host-models.sh`: the rules for the list of models, and turning it
  into llama-swap's config. `manage-models.sh`, `install-models.sh`, and
  `host-setup.sh` source it. The list-checking awk program is in
  `host-models-check.awk`, which `infer_models_ok` runs by name, so it
  can be read and tested on its own.
- `host-install.sh`: where the engine's files go, and installing them
  root-owned, each checked before it replaces the running engine's.
  `host-setup.sh` and `install-models.sh` source it.
- `host-setup.sh`: host setup (macOS today).
- `manage-models.sh`: manages the host's models, without sudo: `list`
  them; `add` a generalist from its GGUF file's Hugging Face link (with
  its vision projector, if the repository has one), or a specialist
  from the sd-server arguments you'd use (`--sd-args`, each model file
  written as its link); `remove` any model; `default` to show or set
  the default; `sync` to download what the list names (only GGUF and
  safetensors, matching their published SHA-256); `outdated` and
  `update` to find and install publishers' updates; and `prune` to find
  files no model uses, with how to serve each (and with `--delete`,
  delete them). It changes only
  `models.local.yaml` and `MODELS_DIR`, never the repo. `default` and
  `add --default` set the default with `manage-models-set-default.awk`.
- `install-models.sh`: has the engine serve `models.local.yaml`: checks
  it, installs llama-swap's config from it (with sudo, asking for your
  password), and restarts the engine (unless `--no-restart`).
- `install-nono-deb.sh`: installs nono, or updates it to the latest
  release, on Debian, Ubuntu, or another dpkg system. nono has no apt
  repository, so this downloads the release's `.deb` from GitHub, checks
  its sha256 digest, and installs it with `sudo dpkg -i`. Run by
  `vm-setup.sh`; run it yourself (outside any sandbox) to update just
  nono, then restart agent sessions.
- `initial-models.yaml`: the models a new host starts with, with their
  sampling defaults and files, in llama-swap's format. Its opening
  comment has the rules for `models.local.yaml`.
- `model-candidates.md`: local models worth considering, mainly for
  code and math, with their trade-offs and sources.
- `multi-agent-plan.md`: options (not yet implemented) for serving a
  main agent and several sub-agents from one local model without each
  one discarding the others' context.
- `infer-check.sh`: run on the Mac to check that the engine really
  serves each model (a few tokens, or one image to look at), showing
  why when one fails.
- `infer-doctor.sh`: run on the Mac when a client seems stuck or slow.
  It reports obvious problems (on battery or Low Power Mode, swap or
  memory pressure, a request making no progress, a closed tunnel, a
  recent sleep unload) and what to try, plus each loaded model's
  settings and the last few requests' context, speed, and draft
  acceptance. It only reads, so it can't disturb a running job.
  `infer-doctor-flags.awk` and `infer-doctor-requests.awk` do its
  parsing.
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
- `vm-piper-install.sh`: installs Piper, a local neural text-to-speech
  engine, for you (no sudo) in `~/.local/share/piper`: the exact Python
  packages in `piper-requirements.txt`, the voices in `config.sh`'s
  `PIPER_VOICES` (pinned by SHA-256), and `speechd-piper`. Run by
  `vm-setup.sh`.
- `vm-speech-setup.sh`: makes Piper speech-dispatcher's default output
  module, so `spd-say` (and anything else that uses speech-dispatcher)
  speaks with the first `PIPER_VOICES` voice; espeak-ng stays available
  (`spd-say -o espeak-ng`). It silently checks that spoken text can't
  run commands; `--say` also speaks a test sentence. Run by
  `vm-setup.sh`.
- `speechd-piper`: what speech-dispatcher's Piper module runs to speak:
  text on stdin, and speech-dispatcher's voice, rate, and volume as
  arguments, converted to Piper's settings.
- `piper-requirements.txt`: the exact Python packages for Piper.
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
  instead of bash-only functions in `vm-bash-aliases-block.sh`; `compart claude`
  below is the first caller.
  It first runs `bulkhead-workspace prepare`, then runs the command
  through `bulkhead-compartment`, passing on any of its options (e.g.,
  `--forward-port`).
- `bulkhead-workspace`: finds a directory's workspace and sets up its
  dossier (see `compartments.md`), before any sandbox starts, so every
  script agrees on them. The workspace is `~/projects/NAME` or
  `~/sensitive/NAME`, with its dossier beside it (`NAME.dossier`), or
  else the directory itself, with its dossier in
  `~/.local/state/bulkhead/dossiers`, after you confirm on the terminal
  (or give `prepare --yes`). It refuses `~` and anything above it, and
  anything matching `workspace-forbidden`. The dossier holds what's
  about the workspace but mustn't be under its agent's control
  (`logs/`, `policy/`, `git/`), mustn't arrive with its contents (`state/`, the
  harness's private files), or passes between you and the agent
  (`inbox/`, `outbox/`). `prepare` notices a workspace moved with its
  dossier, and (for now) moves older layouts in; `orphans` lists
  dossiers whose workspace is gone (`vm-setup.sh` warns about them).
  Move a workspace's dossier with it, using `mv`. The dossier's
  `policy/local-ports` (ports on the agent's own loopback) and
  `policy/expose-ports` (ports you can also reach from the VM) are one
  port number per line; `compart` reads them.
- `bulkhead-compartment`: runs a command in its directory's
  compartment using bubblewrap, so one project's agent can't leave
  anything for another's to read or run: each compartment gets a
  private `/tmp` (its `$TMPDIR`), `~/.claude` (transcripts, history,
  config), Claude's caches and sockets, and so on, per
  `compartment-paths`, from its dossier's `state/`. Shared setup (e.g.,
  `~/.claude/CLAUDE.md`, settings, skills, plugins) is mounted
  read-only, so change it from outside a compartment. It runs bwrap
  under pasta (from `passt`), so each run gets its own network
  namespace: its own loopback, a route out, and DNS through the VM's
  resolver, but no VM ports except each `--forward-port` (e.g.,
  `compart pi`'s for the local AI engine). Each `--expose-port` (from
  the dossier's `expose-ports`) has pasta forward that port from the
  VM's `127.0.0.1` to the agent. It fails rather than run without a
  compartment; `BULKHEAD_NO_COMPARTMENT=1` skips it.
  `tests/compartment-test.sh` (run by hand, outside nono) checks it.
- `bulkhead-git-check`: run by `compart` before and after each
  session; shows you any change to the settings a workspace's git
  repositories give git (config, includes, hooks, and where each
  repository lives) since you approved them, says what each can do
  (from `git-config-risks`), and asks you to approve it. Unapproved, a
  session won't start. `git-config-entries.awk` turns git's config
  listing into its lines. See `compartments.md`, "Git runs commands
  from local files".
- `workspace-forbidden`: the data `bulkhead-workspace` reads:
  shell patterns for directories no agent may start in (e.g.,
  `~/projects`, `~/.*`, `*.dossier`, `/tmp/*`). Installed in
  `/usr/local/libexec/bulkhead/`.
- `bulkhead-copy-claude-history`: copies a project's Claude Code
  history (transcripts and auto-memory) from the real `~/.claude` into
  its compartment, without overwriting, so `--resume` and memory carry
  over. Run it once per project, outside any compartment. Transitional:
  it goes away once your old projects have their history.
- `compartment-paths`: the data `bulkhead-compartment` reads: which
  paths are private per compartment, read-only shared, or the
  compartment's `$TMPDIR` (the directory's `.tmp`). Installed in
  `/usr/local/libexec/bulkhead/`.
- `netns-resolv.conf`: `/etc/resolv.conf` inside each compartment's
  network namespace; pasta forwards its address to the VM's resolver.
  Installed in `/usr/local/libexec/bulkhead/`.
- `compart`: runs an AI harness in this workspace's compartment, e.g.,
  `compart claude` or `compart pi --print 'Say hello'`. Each harness
  gets a case that adds only what it alone needs (its nono profile,
  setup, and extra nono options); every one ends in the same `anon-access
  nono run --profile PROFILE --allow-cwd ...`, so adding a
  harness (e.g., goose) means adding one case. For every harness, it
  adds the workspace's nono options: `--extends bulkhead-broad` outside
  `~/sensitive`, `--log-file` with the workspace's log (so nono's
  warnings don't land on the harness's screen; `nono.log` is rotated to
  `nono.log.1` at launch once it passes 1 MB), the dossier's `inbox/`
  (read-only) and `outbox/` (write-only), and an `--open-port` for each
  of its local and exposed ports. It runs `bulkhead-git-check` before
  and after the session. `compart check` runs a launch's checks
  (the dossier, port lists, and git settings), and checks that git's
  safety settings are in your environment and that no dossier is
  orphaned, but starts nothing. `noclaude` and `nopi` are
  the old names, kept as shims that run `compart claude` and
  `compart pi`.
- `compart claude` runs `anon-access nono run --profile bulkhead-claude
  --allow-cwd -- claude "$@"`. Running
  through `anon-access` gets the sandboxed agent every one of its
  protections (see above) for free, rather than `compart` maintaining
  its own separate, easy-to-forget-to-update env var list; it also means
  `gh` works for public reads inside the sandbox, same as any other
  `anon-access` caller. `bulkhead-claude` (see `nono-claude-profile.json`)
  extends `nolabs-ai/claude`, nono's own
  maintained profile for Claude Code (installed by `vm-setup.sh`),
  rather than a hand-rolled `--allow` list this repo would have to keep
  in sync with what Claude Code actually needs at runtime. Every
  compartment shares one Claude login: `bulkhead-claude` sets
  `CLAUDE_SECURESTORAGE_CONFIG_DIR` to
  `~/.local/state/bulkhead/claude-credentials`, which `compart claude` creates
  (copying in `~/.claude/.credentials.json` the first time). Plain
  executable file, not a bash function: any shell can run it.
- `infer-models.template.sh`: installed as `infer-models`, which asks
  the Mac's engine (through the tunnel) what models it serves now, and
  prints them in a form any client can use: each model's name, context
  window, maximum reply, and whether it takes images, plus the default.
  It treats the answer as untrusted, and checks it with
  `infer-models.jq` (installed in `/usr/local/libexec/bulkhead`). Each
  client's wrapper runs it at start, so changing the models on the Mac
  needs nothing done on a VM.
- `extract-chat-template.py`: writes the chat template embedded in a
  GGUF to a `.jinja` file beside it, for a model's `--chat-template`
  (and its `# generated:` line).
- `compart pi` runs pi like `compart claude` runs Claude Code, against the Mac's
  models, adding only the engine's port to the shared network allowlist
  (from `infer-models --url`). Each time, it turns `infer-models`' answer into pi's
  `models.json` with `pi-models.jq`, and starts pi with the default
  model. `compart pi --list-models` lists the models it would serve (the
  generalists, by their ID in `models.local.yaml`), and
  `compart pi --model FOO` runs pi against the model named FOO for that
  session, instead of the default. Another client (e.g., goose) would
  do the same, with its own small jq file.
- `pi-prose-style.js`: a pi extension that checks the text pi writes
  with `check-prose-style`, as Claude Code's hook does, and blocks a
  write or edit that breaks the rules. `vm-setup.sh` installs it in
  `/usr/local/libexec/bulkhead` and lists it in pi's settings.
- `pi-next-steps.js`: a pi extension that, once pi has finished its
  work, sends the text of `NEXT-STEPS.md` (in pi's working directory)
  as your next message and moves the file into `.next-steps/`, which
  keeps every version sent (e.g., to recover after a crash). So
  you can queue instructions by editing a file instead of interrupting
  pi. It has guards against looping; see its comment. Installed like
  `pi-prose-style.js`.
- `my-gen-image`: makes an image from a prompt, or edits images, with
  the Mac's image models (e.g., flux), from any client with a shell.
- `agents/`: `vm-setup.sh` copies it into `~/.agents`, where Agent
  Skills clients (e.g., pi) find skills, e.g.,
  `agents/skills/my-gen-image/SKILL.md`, which tells the model how to
  use `my-gen-image`.
- `nono-default-profile.json`: filesystem access every nono-sandboxed
  harness should have beyond what its own pack grants: `~/.rbenv`,
  `~/.gitconfig`, `~/.agents` (e.g., skills), program and header directories nono lacks (e.g.,
  `/usr/libexec` and `/usr/include`, so gcc works), the dpkg database,
  small read-only `/etc` files that programs read at startup, the
  generated spelling dictionaries (so aspell works) and Ghostscript font
  maps and CMaps under `/var/lib`, the XML and SGML catalogs, and local
  documentation: the man-page configuration and index cache (so `man`,
  `apropos`, and `whatis` work in the sandbox) plus `/usr/local/share`
  and the man, info, and doc directories under `/usr/local`, `/opt`, and
  `~/.local/share` for software installed outside the system package
  manager. Some entries are absent on
  Ubuntu (e.g. `/etc/man_db.conf`, `/usr/man`, `/opt/man`) but cover other
  distributions, because nono silently skips nonexistent paths. The catch:
  a grant applies only if the path exists when the sandbox starts, so a
  directory you create afterward stays denied until you restart the
  sandbox (see `architecture.md`). All of it is read-only, plus a
  connect-only grant for speech-dispatcher's socket, so agents can use
  `spd-say` (but not `spd-say -w`, which needs `/dev/shm`).
  Installed by `vm-setup.sh` to
  `~/.config/nono/profiles/default.json`, nono's own reserved "default"
  profile name; `nolabs-ai/claude` and every other pack below already
  declares `"extends": "default"`, so this one file covers all of them,
  not just `compart claude`. Same `install_unless_locally_newer` treatment as
  `agents-AGENTS.md` below: an edit made straight to the installed copy
  isn't silently overwritten.
  It also holds the network policy every harness shares: nono's own
  `developer` network profile, plus our additions (one line per host).
  That turns on nono's proxy: the agent can reach only allowed hosts,
  can't make DNS queries, and on hosts that accept writes (including
  model providers, Hugging Face, and Wikipedia) can make only GETs,
  HEADs, and a few read-only POSTs (e.g., git fetch and GitHub GraphQL).
  See `agent-network-plan.md` for the reasons and
  the accepted risks, and `tests/agent-network-test.sh` (run by hand)
  to check it. It also refuses known exfiltration sinks (request
  catchers, tunnels, and paste sites). This narrow list is all that
  applies under `~/sensitive`; elsewhere `anon-access` adds
  `bulkhead-broad` (below). For one more host for one run under
  `~/sensitive`, set `NONO_ALLOW_DOMAIN` (one host), e.g.,
  `NONO_ALLOW_DOMAIN=docs.example.org compart claude`.
- `nono-broad-profile.json`: the `bulkhead-broad` profile, GET and HEAD
  to every host under every TLD (one `*.<tld>` entry each), which
  `anon-access` adds to every `nono run` outside `~/sensitive`, since
  most work isn't sensitive. Generated by `update-broad-profile.sh`
  from IANA's TLD list; installed by `vm-setup.sh`.
- `update-broad-profile.sh`: regenerates `nono-broad-profile.json`. Run
  it by hand now and then.
- `nono-claude-profile.json`: the `bulkhead-claude` profile `compart claude`
  uses: `nolabs-ai/claude` plus only Claude Code's own hosts (its API
  and login), since other harnesses don't need them. It also undoes
  the pack's shared `TMPDIR` (`~/.claude/tmp/claude-$UID`), so Claude's
  temp files go in `anon-access`'s per-directory one (which also
  keeps `nono why --self` working). It sets `DISABLE_TELEMETRY` and
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, since the network policy
  refuses that traffic anyway and each refusal fills nono's log.
  Installed by `vm-setup.sh` beside `default.json`.
- `agent-network-plan.md`: the shared network policy's design, test
  results, and rollout steps.
- `compartments.md`: what each agent's compartment can and can't do,
  each workspace's dossier (its layout, ports, inbox, and outbox) and
  where an agent may not start, and how `anon-access`, pasta, bwrap,
  and nono build it.
- `archive/`: plans that are done, kept for their reasoning and
  lessons (e.g., `workspace-dossier-plan.md`).
- `nftables.template.conf`: VM egress firewall ruleset.
- `bulkhead-reclaim-memory`, `bulkhead-reclaim-memory.template.service`,
  and `bulkhead-reclaim-memory.template.timer`: every 15 minutes, when
  the VM is idle, evict file cache beyond `VM_RECLAIM_KEEP_MB` that
  hasn't been reused lately, so the Mac gets that RAM back instead of
  swapping. It only works if the VM has a virtio balloon with free
  page reporting (UTM QEMU argument `VM_BALLOON_QEMU_ARG`);
  `host-setup.sh` and `vm-setup.sh` warn about any VM without one. Installed by `vm-setup.sh`.
- `vm-bash-aliases-block.sh`: the managed block installed into each VM's
  `~/.bash_aliases`: editor and `BULKHEAD_AUTH_SESSION`. Not a
  template (nothing left to substitute since the Claude Code wrapper moved
  out to its own file above). Bash-only for now: a shell like zsh doesn't source
  `~/.bash_aliases` by default; supporting another shell would mean a
  separate file in that shell's own syntax, not just installing this one
  elsewhere.
- `make-git-safety-env` and `vm-profile-block.sh`: settings that stop a
  repository's own `.git/config` from changing which commands your git
  runs (e.g., `core.fsmonitor`, or a credential helper that would get
  your token). `vm-setup.sh` installs the first one's output as
  `~/.config/environment.d/50-bulkhead-git-safety.conf` and the second
  into `~/.profile`, which reads that file. See `compartments.md`, "Git
  runs commands from local files".
- `git-commit-msg` and `git-hook-passthrough`: your global git hooks.
  The first checks commit messages with `check-prose-style`; the second
  runs a repository's own hook only once you've approved it in
  `~/.config/bulkhead/approved-git-hooks`.
- `agents-AGENTS.md`: the global instructions every harness shares,
  installed to each VM's `~/.agents/AGENTS.md` (agents run in the VMs,
  not on the host, so `host-setup.sh` doesn't install it). If you've
  edited the installed copy directly and it's newer than this file,
  `vm-setup.sh` warns instead of overwriting it; see the printed command
  to pull your edit back in here. Harnesses that don't read it directly
  get a pointer: `claude-CLAUDE.md` for Claude Code, and a symlink from
  `~/.pi/agent/AGENTS.md` for pi.
- `claude-CLAUDE.md`: installed as `~/.claude/CLAUDE.md`; it only
  imports `~/.agents/AGENTS.md` (Claude Code's `@` import), so there's
  one copy of the instructions.
- `check-prose-style.sh`: a Claude Code `PreToolUse` hook that blocks
  `Write`/`Edit`/`NotebookEdit` calls introducing common AI-writing tells
  (em dashes, banned filler phrases, canned stock phrases). Installed to
  each VM's `~/.claude/hooks/check-prose-style.sh` the same
  `install_unless_locally_newer` way as `agents-AGENTS.md` above, and
  wired into `~/.claude/settings.json`'s `hooks.PreToolUse` by
  `vm-setup.sh` (merged in via `jq`, so any other hand-edited settings
  survive; re-running never appends a duplicate entry).
- `ci.sh`: every check this repo has (shellcheck, syntax checks, the
  logic tests in `tests/`, and the Python unit tests), in one script;
  the GitHub CI run (on Ubuntu) and a local run always do the same
  thing. You can run it on any Linux machine with shellcheck, jq, node,
  and Python with PyYAML to verify a change.
A `*.template.*` file gets rendered (placeholders substituted) before
install; anything else is copied or run as-is.
