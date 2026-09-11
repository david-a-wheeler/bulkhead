# shellcheck shell=sh
# config.sh: person/machine-specific values shared by the setup scripts.
# Sourced only (no shebang needed): must stay POSIX sh, since it's sourced
# by both host-setup.sh/host-secrets.sh (macOS) and vm-setup.sh (Ubuntu's
# dash).
#
# Sourced (not executed) by host-setup.sh, vm-setup.sh, host-secrets.sh, and
# common.sh's render_template(). To reuse the scripts for your own setup
# without editing this tracked file (so a `git pull` of upstream changes
# stays clean), copy config.local.sh.example to config.local.sh and set
# overrides there instead; it's sourced last, after every default below,
# and is gitignored.

# Git identity (used by common.sh's configure_git_niceties).
GIT_USER_NAME="David A. Wheeler"
GITHUB_ID="david-a-wheeler"
# Make email weird to counter naive spammers
GIT_USER_EMAIL="dwheeler"'@'"dwheeler.com"

# Linux username inside every VM (lftux, mytux, ...). Scripts assume it's the
# same on each VM so one config.sh works for all of them.
VM_USER="dwheeler"

# Unprivileged macOS account that runs local inference engines, kept unable
# to read the primary user's home directory. See architecture.md.
MACOS_INFER_USER="_infer"

# Port the host secrets server (secrets-server.py) listens on, and that
# secrets-client (and any other VM-side caller) talks to.
SECRETS_SERVER_PORT="9876"

# Prefix every host-secrets.sh-managed Keychain entry is stored under. This
# is what marks a secret as servable at all: secrets-server.py only ever
# looks up prefixed names, so "not found" already means "not servable";
# there's no separate list of allowed secret names to maintain here. Locking
# a secret to one VM is a further naming convention on top of this: see
# host-secrets.sh and architecture.md's Secrets Server section.
KEYCHAIN_PREFIX="bulkhead-"

# git host -> logical secret name, space-separated "host:name" pairs.
# vm-setup.sh turns each pair into its own "git config --global
# credential.https://<host>.helper 'vm-git-helper <name>'" line: git
# itself picks which one applies to a given remote (by URL), so
# vm-git-helper never has to parse "host=" out of git's own stdin
# protocol or carry a host->name lookup table of its own; the name is
# just an argument baked into the config line. Add an entry here (and
# run host-secrets.sh set <name> on the host, then vm-setup.sh on the
# VM) to bring another git host under the proxy; no script changes needed.
#
# Every secret name here (and every name secrets-client takes) is
# spelled like the environment variable it stands in for, e.g. "GH_TOKEN"
# rather than "github-pat": that's the same personal access token gh(1)
# reads from its own GH_TOKEN/GITHUB_TOKEN environment variables (see
# "gh help environment"), so one Keychain entry backs both git's HTTPS
# auth (below) and gh's, with no separate token or config for gh to
# manage. gh's own "gh auth login" is deliberately never used: even with
# a system keyring available it leaves a long-lived credential resident
# in the VM (readable by any process in that login session, not just
# gh), which is exactly what this whole design keeps out of VMs.
# "gh-session" (a two-line wrapper over "secrets-client GH_TOKEN") gets
# the same token into a single child process's environment instead, the
# same ephemeral, human-approved pattern as everything else here.
#
# GH_PUBLIC_TOKEN (used by anon-access, not listed here since it's not a
# git host secret) is stored under the name "GH_PUBLIC_TOKEN!", not
# "GH_PUBLIC_TOKEN": a trailing "!" is what marks a Keychain entry as
# releasable without a human approval dialog (see secrets-server.template.py's
# _resolve() and host-secrets.sh); every secret defaults to requiring
# approval, so this only ever happens via a deliberate choice of name at
# "host-secrets.sh set" time, and "host-secrets.sh list" shows it directly.
GIT_SECRETS="github.com:GH_TOKEN"

# VM to lock the Heroku API key to (rotate-heroku-key.sh reads this): set
# to a VM hostname (e.g. "lftux") to restrict heroku-session on other VMs
# to a denial, or leave empty for a key any VM can use. See
# architecture.md's Secrets Server section for how VM-locking works.
HEROKU_API_KEY_VM="lftux"

# Path to UTM's utmctl CLI, not on PATH by default since it ships inside
# the app bundle. host-setup.sh uses it to look up each running VM's name
# and current IP live (`utmctl list`, `utmctl ip-address <name>`) and
# builds ~/.ssh/config Host blocks from that, so "ssh lftux"/"scp x lftux:"
# work directly; avahi's .local names don't resolve from the host, since
# mDNS doesn't cross UTM's Shared Network NAT (and bridging isn't an option
# on WiFi). Nothing here needs updating as VMs are added, removed, or
# change IP: every host-setup.sh run re-queries utmctl fresh. Requires
# qemu-guest-agent running in the VM (vm-setup.sh installs it).
UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"

# TCP ports the VM is allowed to reach outbound to ANY destination
# (besides loopback and DNS). 22=SSH, 80/443=HTTP/HTTPS. Don't add
# SECRETS_SERVER_PORT here: it gets its own rule in nftables.template.conf,
# scoped to just the host's gateway address, since that port only ever has
# one legitimate destination and shouldn't be reachable anywhere else.
NFTABLES_ALLOWED_TCP_PORTS="22 80 443"

# nono agent packs vm-setup.sh installs (see `nono search <name>` for
# others). One of these, nolabs-ai/claude, is what noclaude runs under.
# Filesystem access every pack should have beyond what its own profile
# grants (toolchain dirs, etc.) isn't configured here: edit
# nono-default-profile.json instead, since every pack below extends
# nono's "default" profile, which is what that file becomes on install.
NONO_AGENT_PROFILES="nolabs-ai/claude nolabs-ai/goose nolabs-ai/pi"

# Set to "true" to also set up the SSH reverse tunnel (RemoteForward) for
# reaching a host-side local inference engine (e.g. Ollama) from the VM.
# Off by default: architecture.md marked this speculative, and it's unrelated
# to git auth.
ENABLE_INFERENCE_SSH_TUNNEL="false"

# Local, uncommitted overrides: anything set here wins, since this loads
# last. $SCRIPT_DIR is already set by whichever script sourced this one
# (host-setup.sh, vm-setup.sh, host-secrets.sh all set it before sourcing
# config.sh). Silently does nothing if config.local.sh doesn't exist; see
# config.local.sh.example to create one.
if [ -f "$SCRIPT_DIR/config.local.sh" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/config.local.sh"
fi
