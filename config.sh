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
# downloaded once. host-setup.sh downloads each model in MODEL_DOWNLOADS
# whose file isn't in MODELS_DIR yet. One file per line: URL, then its
# SHA-256 from the publisher (e.g., on Hugging Face), then its license,
# then (for a model made of several files, such as an image model) the
# subdirectory of MODELS_DIR to put it in. The SHA-256 pins each file.
# To add a model, run ./add-model.sh on the Mac, which fills these in and
# appends them to config.local.sh; ./add-model.sh --check and --update
# find and install publishers' updates.
MODELS_DIR="/Users/Shared/models"
MODEL_DOWNLOADS="https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-Q8_0.gguf a680f44a06920e5d689774823782006aa3acc8db95750323373b24139b67e348 apache-2.0
https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q4_K_M.gguf 322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482 apache-2.0
https://huggingface.co/ggml-org/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_0.gguf da2572f16c06133561ce56accaa822216f2391ef4d37fba427801cd6736417d4 apache-2.0
https://huggingface.co/leejet/FLUX.2-klein-4B-GGUF/resolve/main/flux-2-klein-4b-Q8_0.gguf 0bba6951258ec8f92d51114a8fa13e66828297bfff58a738f52729b3ef66fa28 apache-2.0 flux2-klein-4b
https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q8_0.gguf eed555233267a33c7e8ee31682762cc7751b3f6d224039086e0e846f05fffa5d apache-2.0 flux2-klein-4b
https://huggingface.co/black-forest-labs/FLUX.2-klein-4B/resolve/main/vae/diffusion_pytorch_model.safetensors ca70d2202afe6415bdbcb8793ba8cd99fd159cfe6192381504d6c4d3036e0f04 apache-2.0 flux2-klein-4b"

# The models the local AI engine serves, and their settings (e.g.,
# sampling defaults), are in infer-models.yaml, plus any you add in
# infer-models.local.yaml.

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

# nono agent packs vm-setup.sh installs (see `nono search <name>` for
# others). One of these, nolabs-ai/claude, is what noclaude runs under.
# Filesystem access every pack should have beyond what its own profile
# grants (toolchain dirs, etc.) isn't configured here: edit
# nono-default-profile.json instead, since every pack below extends
# nono's "default" profile, which is what that file becomes on install.
NONO_AGENT_PROFILES="nolabs-ai/claude nolabs-ai/goose nolabs-ai/pi"


# Local, uncommitted overrides: anything set here wins, since this loads
# last. $SCRIPT_DIR is already set by whichever script sourced this one
# (host-setup.sh, vm-setup.sh, host-secrets.sh all set it before sourcing
# config.sh). Silently does nothing if config.local.sh doesn't exist; see
# config.local.sh.example to create one.
if [ -f "$SCRIPT_DIR/config.local.sh" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/config.local.sh"
fi
