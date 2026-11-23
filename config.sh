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
# host-setup.sh creates it as a hidden role account with a group of the
# same name.
MACOS_INFER_USER="_infer"

# Local AI models, readable by MACOS_INFER_USER, writable only by you, and
# downloaded once. Which models the engine serves, their files, and
# their settings (e.g., sampling defaults) are in models.local.yaml, which
# starts as a copy of initial-models.yaml; ./manage-models.sh on the Mac
# changes it, and downloads the files.
MODELS_DIR="/Users/Shared/models"

# The local AI engine's releases. host-setup.sh installs the newest
# release of llama.cpp (a stable vX.Y.Z release, then the build it names)
# and of llama-swap that's at least INFER_COOLING_DAYS old, so we get
# improvements and security fixes, but others have had time to notice a
# bad or malicious release first. It never picks one older than the
# floor (*_MIN), e.g., the release we last tested (for llama.cpp, a
# stable release like "v0.7.0", not a build); once a newer release
# is old enough, the floor stops mattering, so there's no need to update
# it. A pin (*_PIN; for llama.cpp, a release like "v0.7.0" or a build
# like "b11721") overrides both, e.g., to hold back from a release that
# breaks something; host-setup.sh warns while one is set, so clear it
# when you can.
#
# vm-setup.sh installs pi the same way, with PI_MIN and PI_PIN (versions
# like "1.3.0"), using npm's --before, which also limits pi's
# dependencies to versions published by then.
INFER_COOLING_DAYS="7"
LLAMA_CPP_MIN="v0.7.0"
LLAMA_CPP_PIN=""
LLAMA_SWAP_MIN="v265"
LLAMA_SWAP_PIN=""
# stable-diffusion.cpp (for image models) releases each build, with tags
# like "master-964-1d0a58a", not versions, so it has a pin but no floor;
# it waits INFER_COOLING_DAYS like the others.
SD_CPP_PIN=""
PI_MIN="1.3.0"
PI_PIN=""

# Port the local AI engine (llama-swap) listens on, on the Mac's
# 127.0.0.1. A VM's SSH reverse tunnel forwards the same port on the VM's
# own 127.0.0.1 to it.
INFER_PORT="8089"

# The VM that holds sensitive data (its UTM name, as in ~/.ssh/config):
# infer-access.sh's "secure" mode gives only it access to the local AI
# engine, and "shared" mode gives every other running VM access, but
# never it. Empty until the secure VM exists; "secure" refuses to run
# until it's set.
INFER_SECURE_VM=""

# The local AI engine's launchd daemon, and the file holding its API key
# (on the Mac, and on each VM that may use it).
INFER_LABEL="local.infer"
INFER_KEY_FILE="$HOME/.config/bulkhead/infer-api-key"

# host-setup.sh copies that key to each running VM that has a
# ~/.config/bulkhead directory (vm-setup.sh creates it), except the VMs
# (UTM names, space-separated) listed here. A VM without the key can't
# use the engine even with a tunnel; infer-access.sh decides which VMs
# get a tunnel. To cut a VM off for good, list it here and rotate the
# key (see README.md).
INFER_NO_KEY_VMS=""

# The sleep watcher's launchd agent (see infer-watch.c), and when it
# switches to Low Power Mode: below INFER_LOW_POWER_BELOW percent of
# battery, until it's back to INFER_LOW_POWER_UNTIL percent or more
# while plugged in.
INFER_WATCH_LABEL="local.infer-watch"
INFER_LOW_POWER_BELOW="30"
INFER_LOW_POWER_UNTIL="40"

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

# Giving idle VM RAM back to the host (see bulkhead-reclaim-memory).
# Every VM_RECLAIM_INTERVAL (a systemd time span), if the VM's 1-minute
# load average is under VM_RECLAIM_MAX_LOAD, it evicts file cache beyond
# VM_RECLAIM_KEEP_MB, but only cache that hasn't been reused lately. A
# longer interval or bigger KEEP_MB keeps more of your files cached
# (faster) but leaves the host less RAM.
VM_RECLAIM_INTERVAL="15min"
VM_RECLAIM_KEEP_MB="1024"
VM_RECLAIM_MAX_LOAD="1"

# The QEMU argument each UTM VM needs so its freed RAM goes back to the
# host. host-setup.sh and vm-setup.sh warn about a VM without it.
VM_BALLOON_QEMU_ARG="-device virtio-balloon-pci,free-page-reporting=on"

# nono agent packs vm-setup.sh installs (see `nono search <name>` for
# others). One of these, nolabs-ai/claude, is what compart claude runs under.
# Filesystem access every pack should have beyond what its own profile
# grants (toolchain dirs, etc.) isn't configured here: edit
# nono-default-profile.json instead, since every pack below extends
# nono's "default" profile, which is what that file becomes on install.
NONO_AGENT_PROFILES="nolabs-ai/claude nolabs-ai/goose nolabs-ai/pi"

# Piper voices (local neural text-to-speech) that vm-piper-install.sh
# installs on each VM, one per line: NAME TYPE ONNX_SHA256 JSON_SHA256.
# NAME is a voice from https://huggingface.co/rhasspy/piper-voices (its
# MODEL_CARD gives its license), TYPE the speech-dispatcher voice type
# it answers to (MALE1-3, FEMALE1-3, CHILD_MALE, CHILD_FEMALE), and the
# SHA-256s pin its NAME.onnx and NAME.onnx.json. The first is the
# default voice for spd-say and everything else that uses
# speech-dispatcher (vm-speech-setup.sh). To add one, give "-" for both
# SHA-256s: vm-piper-install.sh then prints what it downloaded, for you
# to check (Hugging Face shows the .onnx's SHA-256) and paste in, and
# doesn't use it until you do. ljspeech's recordings are public domain.
PIPER_VOICES="
en_US-ljspeech-high FEMALE1 5d4f08ba6a2a48c44592eed3ce56bf85e9de3dd4e20df90541ae68a8310c029a 7e1f4634af596d83cca997fb7a931ba80b70f8a316a2655ee69c55365e0ace14
"


# Local, uncommitted overrides: anything set here wins, since this loads
# last. $SCRIPT_DIR is already set by whichever script sourced this one
# (host-setup.sh, vm-setup.sh, host-secrets.sh all set it before sourcing
# config.sh). Silently does nothing if config.local.sh doesn't exist; see
# config.local.sh.example to create one.
if [ -f "$SCRIPT_DIR/config.local.sh" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/config.local.sh"
fi
