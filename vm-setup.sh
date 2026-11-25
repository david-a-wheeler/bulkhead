#!/bin/sh
# vm-setup.sh: idempotent setup for an Ubuntu VM (lftux, mytux, ...).
#
# Run this after every "git pull" of this repo to converge the VM to the
# repo's current config. Safe to re-run any time; it only ever brings state
# in line with config.sh, never accumulates changes.
#
# Needs sudo (apt, systemctl, writing /etc/nftables.conf, /etc/cups/cupsd.conf,
# /usr/local/bin). Does not touch secrets; see host-secrets.sh, run on the
# macOS host, for that.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

# This script is Linux-only for now (might loosen this later), but only
# Ubuntu VMs are supported today, so fail clearly rather than let
# apt/systemctl/etc. produce confusing errors on a machine without them.
linux_only "vm-setup.sh"

# apt_get ARGS...: sudo apt-get, but if another apt or dpkg holds its
# lock (e.g., unattended-upgrades, often just after boot), wait up to
# 15 minutes for it instead of failing. apt says it's waiting, and why.
apt_get() {
  sudo apt-get -o DPkg::Lock::Timeout=900 "$@"
}

# Local tempdir, not /tmp: same reasoning as anon-access's TMPDIR (/tmp is
# shared across every user/process on the VM). Only defaults TMPDIR if the
# caller hasn't already set one; an already-set TMPDIR (e.g. from a caller
# that scopes its own) is used as-is, never overridden. Exported, not just
# set: it needs to reach mktemp too (common.sh's install_managed_block),
# not only the explicit "$TMPDIR/..." paths below. Created this early
# since the very next step already needs it.
: "${TMPDIR:=$SCRIPT_DIR/.tmp}"
export TMPDIR
mkdir -p "$TMPDIR"

# install_rendered TEMPLATE DEST MODE VAR...: renders the repo's TEMPLATE
# with VAR... (see render_template), and installs it root-owned as DEST
# with MODE.
install_rendered() {
  ir_template="$1" ir_dest="$2" ir_mode="$3"
  shift 3
  render_template "$SCRIPT_DIR/$ir_template" "$TMPDIR/rendered" "$@"
  sudo install -m "$ir_mode" "$TMPDIR/rendered" "$ir_dest"
  rm -f "$TMPDIR/rendered"
}

echo "== Installing base packages =="
# openssh/avahi/cups/nftables per architecture.md's discovery+services
# phase. curl has to land here, before anything else (the gh repo setup
# right below, the Claude Code installer further down) tries to use it,
# and a fresh VM image can't be assumed to have it already. Node.js/npm are
# deliberately NOT installed here: Claude Code's native installer (below)
# is self-contained. qemu-guest-agent lets the host ask UTM's utmctl for
# this VM's current IP (see host-setup.sh); without it running here,
# "ssh <this-vm-name>" from the host has nothing to go on.
#
# git/shellcheck/make/build-essential/vim/python3: general-purpose dev
# tools worth having on every VM regardless of project (vim in particular
# because EDITOR/VISUAL below are set to it; python3 because
# secrets-client (which vm-git-helper below shells out to on every git
# push/fetch) is a Python script, so it's a hard requirement for the
# git-auth bridge, not just a nicety; it's not worth assuming it's
# preinstalled). jq is here for the same reason:
# rotate-heroku-key.sh's revoke-the-old-authorization step filters
# "heroku authorizations -j" through it. ripgrep (rg) because AI harnesses
# such as pi use it for their search tools, and would otherwise download
# their own copy. wl-clipboard (wl-copy, wl-paste) so command-line tools
# can reach the Wayland desktop's clipboard; e.g., Claude Code uses it to
# paste images. speech-dispatcher, alsa-utils (aplay), and python3-venv
# for spoken output with Piper (vm-piper-install.sh, below). gawk so
# ci.sh can lint our awk programs ("gawk --posix --lint"); they're
# POSIX awk and run under Ubuntu's default mawk, so gawk is only for
# checking them, and ci.sh skips that check without it. Checked
# against `apt-mark showmanual` on lftux and deliberately left out anything project-specific
# rather than universal: ruby, postgresql, and the heroku CLI are for one
# project (BadgeApp) and don't belong in a generic bulkhead repo;
# cmake, autoconf, bison, pkg-config, and the lib*-dev packages are
# ruby-build's prerequisites for compiling Ruby, same story; graphviz
# looked like it might be a project's doc-generation dependency rather
# than a general tool. Add project-specific packages by hand in that
# project's own setup, not here. "apt-get install -y" is naturally
# idempotent (a no-op once everything's already at the latest version), so
# this one line covers first install and every later re-run. weston
# is each compartment's display (see bulkhead-display).
apt_get update
apt_get install -y openssh-server avahi-daemon nftables curl cups \
  qemu-guest-agent git shellcheck make build-essential vim python3 jq \
  ripgrep wl-clipboard speech-dispatcher alsa-utils python3-venv bubblewrap passt \
  gawk weston

echo "== Enabling services =="
sudo systemctl enable --now ssh avahi-daemon nftables cups qemu-guest-agent

echo "== Adding the GitHub CLI (gh) apt repo and installing gh =="
# Official install method (see https://github.com/cli/cli/blob/trunk/docs/install_linux.md):
# add GitHub's own apt repo and keyring, then install gh from it. Unlike
# nono further down, this one has a real repo behind it, so it's safe to
# automate. Deliberately NOT gated behind "is gh already installed": these
# are just idempotent file writes, and doing them unconditionally means a
# corrupted keyring/repo file or a key rotation gets fixed on the next run
# too, not just on first install. curl writes to a temp file first (rather
# than piping into "sudo tee") so a failed download is caught here via
# set -e, instead of silently producing an empty keyring that only fails
# later, confusingly, inside apt-get update. This needs its own apt-get
# update (the one above ran before this repo existed), so gh install is
# two "apt-get update"s total rather than the one everything else shares.
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o "$TMPDIR/githubcli-archive-keyring.gpg"
sudo install -m 644 "$TMPDIR/githubcli-archive-keyring.gpg" \
  /etc/apt/keyrings/githubcli-archive-keyring.gpg
rm -f "$TMPDIR/githubcli-archive-keyring.gpg"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt_get update
apt_get install -y gh
# This installs the gh binary only; nothing here ever runs "gh auth login".
# That command persists a long-lived token into this VM (a system keyring
# if one's running, else a plaintext file), exactly the kind of resident
# credential this repo's whole design keeps out of VMs. gh-session (see
# below) gets gh the same GH_TOKEN secret git already uses, ephemerally,
# per burst of commands, instead.

echo "== Claude Code (native installer) =="
# Asked once ever (see ask_once in common.sh) when claude isn't already
# on PATH: no point asking whether to install something clearly already
# there, and re-checking "command -v claude" here (rather than persisting
# that fact anywhere) means this self-corrects if claude's ever
# uninstalled later, instead of trusting a flag that could go stale.
# want_claude is captured once and reused below (for the CLAUDE.md step)
# rather than re-running "command -v claude" there too. Right after a
# fresh install in this same run, that check could false-negative: the
# native installer's ~/.local/bin only lands on PATH via the
# .bash_aliases block this script installs, which a fresh shell hasn't
# sourced yet mid-run.
if command -v claude >/dev/null 2>&1; then
  echo "Claude Code is already installed."
  want_claude=true
elif ask_once install-claude-code "Install Claude Code on this VM?"; then
  curl -fsSL https://claude.ai/install.sh | bash
  want_claude=true
else
  echo "Skipping Claude Code install (recorded preference)."
  want_claude=false
fi

echo "== Rendering and applying nftables egress ruleset =="
# SECRETS_SERVER_PORT gets its own rule scoped to the host's gateway
# address (see nftables.template.conf) rather than being folded into the
# general NFTABLES_ALLOWED_TCP_PORTS set, which would let the VM reach ANY
# host on that port instead of just the secrets server. Missing this port
# entirely was a real incident: the VM couldn't reach the secrets server
# at all, and nothing failed loudly; git just fell back to an interactive
# username prompt. So it's handled explicitly here rather than left to
# config.sh.
nft_ports="$(printf '%s' "$NFTABLES_ALLOWED_TCP_PORTS" | sed 's/^ *//; s/ *$//; s/ /, /g')"
NFTABLES_ALLOWED_TCP_PORTS_NFT="$nft_ports"
HOST_GATEWAY_IP="$(ip route | awk '/^default/ { print $3; exit }')"
[ -n "$HOST_GATEWAY_IP" ] ||
  die "couldn't determine the default gateway; can't scope the secrets-server firewall rule safely."
install_rendered nftables.template.conf /etc/nftables.conf 755 \
  NFTABLES_ALLOWED_TCP_PORTS_NFT HOST_GATEWAY_IP SECRETS_SERVER_PORT
sudo nft -f /etc/nftables.conf

echo "== Hardening CUPS (unix socket only, no TCP listener) =="
# Only comments an uncommented "Listen localhost:631" line, so this is
# already safe to re-run: once commented, the pattern no longer matches.
sudo sed -i '/^[[:space:]]*Listen localhost:631/s/^/#/' /etc/cups/cupsd.conf
sudo systemctl restart cups

echo "== Installing/updating nono =="
# A separate script, so you can also update nono without the rest of
# this. If it fails, keep going with whatever nono is installed.
"$SCRIPT_DIR/install-nono-deb.sh" ||
  echo "WARNING: couldn't install or update nono (see above)." >&2

echo "== Installing nono's default profile (nono-default-profile.json) =="
# "default" is nono's own reserved profile name: nolabs-ai/claude (and
# every other pack pulled below) declares "extends": "default" in its own
# profile.json, and a user profile of that name takes precedence over
# nono's built-in one. So this is the one place to grant filesystem access
# every harness needs (e.g., $HOME/.gitconfig and the global git hooks it
# names), and the network allowlist every harness shares (see
# agent-network-plan.md), instead of per-harness flags.
# install_unless_locally_newer, not a plain cp: same reasoning as
# agents-AGENTS.md below, an edit made directly to the installed copy
# (e.g. via nono's own profile tooling) shouldn't be silently clobbered.
# nono-claude-profile.json (bulkhead-claude) adds only Claude Code's own
# hosts; it's a profile rather than compart claude flags because nono ignores
# NONO_ALLOW_DOMAIN when the command line has --allow-domain.
mkdir -p "$HOME/.config/nono/profiles"
install_unless_locally_newer "$SCRIPT_DIR/nono-default-profile.json" \
  "$HOME/.config/nono/profiles/default.json"
install_unless_locally_newer "$SCRIPT_DIR/nono-claude-profile.json" \
  "$HOME/.config/nono/profiles/bulkhead-claude.json"
# bulkhead-sh (nono-sh-profile.json) is for compart sh.
install_unless_locally_newer "$SCRIPT_DIR/nono-sh-profile.json" \
  "$HOME/.config/nono/profiles/bulkhead-sh.json"
# bulkhead-broad (nono-broad-profile.json) allows GET and HEAD to the
# whole web; compart adds it to every launch outside ~/sensitive.
install_unless_locally_newer "$SCRIPT_DIR/nono-broad-profile.json" \
  "$HOME/.config/nono/profiles/bulkhead-broad.json"
# bulkhead-loopback (nono-loopback-profile.json) lets programs bind
# random ports on the compartment's own loopback; compart adds it to
# every launch.
install_unless_locally_newer "$SCRIPT_DIR/nono-loopback-profile.json" \
  "$HOME/.config/nono/profiles/bulkhead-loopback.json"

echo "== Installing nono agent profiles (config.sh's NONO_AGENT_PROFILES) =="
# One pack per supported harness (compart claude's --profile nolabs-ai/claude
# is one of these); add another "namespace/name" to NONO_AGENT_PROFILES
# to support a new one, nothing else here changes. A missing pack is
# installed (obviously current, so no outdated check needed); an already
# installed one is left alone, with a notice printed if a newer version
# exists, so upgrading stays a deliberate, on-request choice per VM.
outdated_notices=""
for pack in $NONO_AGENT_PROFILES; do
  if nono list --installed --json 2>/dev/null \
      | jq -e --arg p "$pack" '.packages[$p]' >/dev/null 2>&1; then
    outdated_json="$(nono outdated --json 2>/dev/null)" || outdated_json='[]'
    versions="$(printf '%s' "$outdated_json" \
      | jq -r --arg p "$pack" '.[] | select(.key == $p) | "\(.installed) \(.latest)"')"
    if [ -n "$versions" ]; then
      installed="${versions%% *}"
      latest="${versions##* }"
      if [ "$installed" != "$latest" ]; then
        # Not "nono profile diff": confirmed it can silently miss a real
        # change (a new filesystem grant), so it's not safe to suggest as
        # a review step. Just the update command itself, one per line, so
        # a run with several outdated packs can be copy-pasted as a block.
        outdated_notices="${outdated_notices}  nono pull $pack --force  # Update $installed->$latest
"
      fi
    fi
  else
    nono pull "$pack"
  fi
done
if [ -n "$outdated_notices" ]; then
  printf '\nNOTE: newer nono agent profiles are available; update any of these when ready:\n%s\n' "$outdated_notices"
fi

echo "== Speech: Piper as speech-dispatcher's default voice =="
# A local neural voice for spd-say and everything else that uses
# speech-dispatcher, including agents under nono (nono-default-profile.json
# grants its socket). Both run as you, without sudo; see each script.
"$SCRIPT_DIR/vm-piper-install.sh"
"$SCRIPT_DIR/vm-speech-setup.sh"

echo "== Installing vm-git-helper (git credential helper) =="
# Plain file, no templating needed: it takes the secret name as an
# argument rather than having one baked in (see below), so it's
# installed the same way as heroku-session/gh-session, not rendered.
sudo install -m 755 "$SCRIPT_DIR/vm-git-helper" /usr/local/bin/

# One credential.<url>.helper per GIT_SECRETS entry, each with its
# secret name baked directly into the config line: git resolves which
# one applies to a given remote itself (by URL), so vm-git-helper never
# has to parse "host=" out of git's own stdin protocol or carry a
# host->name lookup table of its own. Plain "git config" (not --add):
# idempotent, re-running this always leaves exactly one entry per host,
# never accumulating duplicates.
for pair in $GIT_SECRETS; do
  host="${pair%%:*}"
  secret="${pair#*:}"
  # Absolute path, not bare "vm-git-helper": a bare name here is a git
  # convention meaning "run git-credential-<name>" (like "store" means
  # git-credential-store), not "execute this literally" - confirmed
  # directly, a bare name fails with "'credential-vm-git-helper' is not
  # a git command" instead of ever running our script.
  git_config_set "credential.https://${host}.helper" "/usr/local/bin/vm-git-helper ${secret}"
done

echo "== Installing secrets-client (generic secrets-server CLI, used by heroku-session/gh-session) =="
# Installed without a ".py" extension (see secrets-client.template.py):
# callers shouldn't need to know or care this happens to be Python.
install_rendered secrets-client.template.py /usr/local/bin/secrets-client 755 SECRETS_SERVER_PORT

echo "== Installing heroku-session, gh-session, and anon-access (secrets-client wrappers) =="
# Plain files, no templating needed: install directly rather than via
# render_template. Any shell can run these (they're just executables on
# $PATH).
sudo install -m 755 "$SCRIPT_DIR/heroku-session" "$SCRIPT_DIR/gh-session" "$SCRIPT_DIR/anon-access" /usr/local/bin/
# anon-access checks each workspace and sets up its dossier
# (bulkhead-workspace, which reads workspace-forbidden), then runs
# everything through bulkhead-compartment (bubblewrap, in a network
# namespace from pasta), which reads compartment-paths and
# netns-resolv.conf. compart also runs bulkhead-git-check (which reads
# git-config-entries.awk and git-config-risks), bulkhead-snapshot
# (which runs snapshot-feed.py), and bulkhead-grant-check (which reads
# compartment-paths). compart runs bulkhead-display too, for each
# compartment's own display. See compartments.md.
# bulkhead-copy-claude-history is transitional.
sudo install -m 755 "$SCRIPT_DIR/bulkhead-compartment" \
  "$SCRIPT_DIR/bulkhead-workspace" "$SCRIPT_DIR/bulkhead-git-check" \
  "$SCRIPT_DIR/bulkhead-snapshot" "$SCRIPT_DIR/bulkhead-grant-check" \
  "$SCRIPT_DIR/bulkhead-copy-claude-history" "$SCRIPT_DIR/bulkhead-display" /usr/local/bin/
# The helpers bulkhead-workspace replaced.
for f in bulkhead-compartment-info bulkhead-workspace-prepare \
  bulkhead-workspace-nono-args bulkhead-workspace-ports; do
  [ ! -e "/usr/local/bin/$f" ] || sudo rm -f "/usr/local/bin/$f"
done
sudo install -d -m 755 /usr/local/libexec/bulkhead
sudo install -m 644 "$SCRIPT_DIR/compartment-paths" "$SCRIPT_DIR/workspace-forbidden" \
  "$SCRIPT_DIR/netns-resolv.conf" "$SCRIPT_DIR/git-config-entries.awk" \
  "$SCRIPT_DIR/git-config-risks" "$SCRIPT_DIR/snapshot-feed.py" /usr/local/libexec/bulkhead/
sudo install -m 755 "$SCRIPT_DIR/new-session-keyring" /usr/local/libexec/bulkhead/
orphans="$(/usr/local/bin/bulkhead-workspace orphans)"
if [ -n "$orphans" ]; then
  cat >&2 <<EOF
WARNING: these dossiers' workspaces are gone:
$orphans
  Each holds a workspace's logs and harness state (e.g., Claude's
  transcripts and memory). If you moved the workspace, move its dossier
  with mv (see compartments.md, "Moving a workspace"); if you deleted
  it, delete the dossier.
EOF
fi

echo "== Installing compart (runs AI harnesses in compartments) =="
# Plain files, no templating needed: the sandbox policy every harness
# shares (files and network) comes from nono-default-profile.json
# (installed above). compart runs anon-access, but install order
# doesn't matter: nothing runs it until this script has finished.
# noclaude and nopi are the old names for "compart claude" and
# "compart pi", kept as shims. claude-unsandboxed is the last-resort
# failsafe for when nono itself won't run.
sudo install -m 755 "$SCRIPT_DIR/compart" "$SCRIPT_DIR/noclaude" \
  "$SCRIPT_DIR/nopi" "$SCRIPT_DIR/claude-unsandboxed" /usr/local/bin/

echo "== Configuring git niceties =="
configure_git_niceties

echo "== Installing commit-msg git hook (check-prose-style --text) =="
# Checks every commit message in every repository, whoever writes it (a
# human, Claude Code, goose, pi, ...), so it's installed even without
# Claude Code. Root-owned under /usr/local, like the other tools here,
# so a sandboxed agent can't edit it (though "git commit --no-verify"
# still skips it: it's a style check, not a security control). A global
# core.hooksPath disables every repository's own .git/hooks, so each
# other client-side hook name links to git-hook-passthrough, which runs
# the repository's hook of that name if it has one and you've approved
# it (in ~/.config/bulkhead/approved-git-hooks); commit-msg runs the
# passthrough after its check. reference-transaction is left out, since a hook
# there would run on every ref update. A repository can't set its own
# core.hooksPath (e.g., husky does) once make-git-safety-env's settings
# (below) are in your environment.
sudo install -m 755 "$SCRIPT_DIR/check-prose-style.sh" /usr/local/bin/check-prose-style
git_hooks_dir=/usr/local/libexec/bulkhead/git-hooks
current_hooks_path="$(git config --global --get core.hooksPath || true)"
if [ -n "$current_hooks_path" ] && [ "$current_hooks_path" != "$git_hooks_dir" ]; then
  echo "WARNING: git's global core.hooksPath is already $current_hooks_path;" >&2
  echo "  leaving it alone, so commit messages won't be checked." >&2
else
  sudo mkdir -p "$git_hooks_dir"
  sudo install -m 755 "$SCRIPT_DIR/git-commit-msg" "$git_hooks_dir/commit-msg"
  sudo install -m 755 "$SCRIPT_DIR/git-hook-passthrough" "$git_hooks_dir/passthrough"
  for hook in applypatch-msg pre-applypatch post-applypatch pre-commit \
      pre-merge-commit prepare-commit-msg post-commit pre-rebase \
      post-checkout post-merge pre-push post-rewrite pre-auto-gc \
      sendemail-validate; do
    sudo ln -sfn passthrough "$git_hooks_dir/$hook"
  done
  git_config_set core.hooksPath "$git_hooks_dir"
fi

echo "== Pinning git settings that run commands (environment.d, ~/.profile) =="
# An agent can write its workspace's .git, so a repository's own config
# could make git run a command the next time you run git there. These
# settings override a repository's config for the keys they cover (see
# make-git-safety-env and compartments.md). They take effect at your
# next login; until then, run: set -a; . FILE; set +a
git_safety_dir="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d"
git_safety_env="$git_safety_dir/50-bulkhead-git-safety.conf"
mkdir -p "$git_safety_dir"
"$SCRIPT_DIR/make-git-safety-env" > "$TMPDIR/git-safety.conf"
if ! cmp -s "$TMPDIR/git-safety.conf" "$git_safety_env"; then
  cp "$TMPDIR/git-safety.conf" "$git_safety_env"
  echo "  Updated $git_safety_env; log in again to use it everywhere."
fi
rm -f "$TMPDIR/git-safety.conf"
install_managed_block "$SCRIPT_DIR/vm-profile-block.sh" "$HOME/.profile"

echo "== Installing global agent instructions (~/.agents/AGENTS.md) =="
# One set of instructions for every harness, so they can't drift apart.
# Each harness that doesn't read ~/.agents/AGENTS.md itself gets a
# pointer to it: Claude Code's CLAUDE.md imports it, and pi's AGENTS.md
# is a symlink to it (below). Every harness's sandbox can read ~/.agents.
mkdir -p "$HOME/.agents"
install_unless_locally_newer "$SCRIPT_DIR/agents-AGENTS.md" "$HOME/.agents/AGENTS.md"

if [ "$want_claude" = true ]; then
  echo "== Pointing Claude Code at the global agent instructions (CLAUDE.md) =="
  mkdir -p "$HOME/.claude"
  install_unless_locally_newer "$SCRIPT_DIR/claude-CLAUDE.md" "$HOME/.claude/CLAUDE.md"

  echo "== Installing check-prose-style.sh (AI-writing-tell PreToolUse hook) =="
  # Same install_unless_locally_newer treatment as agents-AGENTS.md above:
  # an edit made straight to the installed copy isn't silently overwritten.
  mkdir -p "$HOME/.claude/hooks"
  install_unless_locally_newer "$SCRIPT_DIR/check-prose-style.sh" \
    "$HOME/.claude/hooks/check-prose-style.sh"
  chmod +x "$HOME/.claude/hooks/check-prose-style.sh"

  echo "== Wiring check-prose-style.sh into ~/.claude/settings.json =="
  # A script sitting in ~/.claude/hooks does nothing on its own; Claude
  # Code only runs it once it's registered as a PreToolUse hook in
  # settings.json. That file is hand-edited too (theme, permissions,
  # other hooks), so this can't just overwrite it like
  # install_unless_locally_newer does for a whole-file install: it has to
  # merge one entry in via jq, seeding an empty "{}" first if the file's
  # missing or empty, and leaving everything else in the file untouched.
  # The "any(...)" check is what makes this idempotent: skip if an entry
  # calling this hook is already present (whatever its matcher), so
  # re-running vm-setup.sh never appends a duplicate.
  settings_file="$HOME/.claude/settings.json"
  [ -s "$settings_file" ] || printf '%s' '{}' > "$settings_file"
  jq '
    (.hooks.PreToolUse // []) as $existing
    | if ($existing | any(.hooks[]?.command == "~/.claude/hooks/check-prose-style.sh"))
      then .
      else .hooks.PreToolUse = ($existing + [{
          matcher: "Write|Edit|NotebookEdit",
          hooks: [{
            type: "command",
            command: "~/.claude/hooks/check-prose-style.sh",
            timeout: 10,
            statusMessage: "Checking prose style..."
          }]
        }])
      end
  ' "$settings_file" > "$TMPDIR/claude-settings.json.rendered"
  cp "$TMPDIR/claude-settings.json.rendered" "$settings_file"
  rm -f "$TMPDIR/claude-settings.json.rendered"
fi

echo "== Managing ~/.bash_aliases block (editor, BULKHEAD_AUTH_SESSION) =="
# Plain file, not rendered: no @@VAR@@ substitution left in it.
install_managed_block "$SCRIPT_DIR/vm-bash-aliases-block.sh" "$HOME/.bash_aliases"

echo "== Local AI: pi, compart pi, and infer-logs =="
# See local-ai-plan.md. Only a VM with the engine's API key can use the
# Mac's engine. host-setup.sh copies the key into ~/.config/bulkhead on
# each running VM that has that directory, so we create it here (no
# nono profile grants it). We install everything else either way, so
# the order of the two runs doesn't matter; compart pi and infer-logs
# wait for the key.
key_dir="$(dirname "$INFER_KEY_FILE")"
[ -d "$key_dir" ] || { mkdir -p "$(dirname "$key_dir")" && mkdir -m 700 "$key_dir"; }
[ ! -f "$INFER_KEY_FILE" ] || chmod 600 "$INFER_KEY_FILE"
pi_package=@earendil-works/pi-coding-agent
# pi needs Node.js (Claude Code, above, doesn't).
apt_get install -y nodejs npm
npm_cache="$TMPDIR/npm-cache"

# Which pi (see config.sh): the newest release that's at least
# INFER_COOLING_DAYS old, but not older than PI_MIN; or PI_PIN. npm's
# --before limits pi and its dependencies to versions published by
# then. For the floor or a pin, that's an hour after it was published,
# since pi's sibling packages (e.g., pi-tui) come out moments after it.
pi_before="$(cooling_cutoff)"
pi_spec="$pi_package@latest"
pi_floor="${PI_PIN:-$PI_MIN}"
if [ -n "$pi_floor" ]; then
  pi_floor_time="$(npm view "$pi_package" time --json --cache "$npm_cache" |
    jq -r --arg v "$pi_floor" '.[$v] // empty')"
  [ -n "$pi_floor_time" ] || die "there's no pi release $pi_floor (config.sh's PI_PIN or PI_MIN)."
  pi_floor_before="$(date -u -d "@$(($(date -u -d "$pi_floor_time" +%s) + 3600))" +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$PI_PIN" ]; then
    echo "WARNING: pi is pinned to $PI_PIN. Clear the pin in config.sh when you can." >&2
    pi_spec="$pi_package@$PI_PIN"
    pi_before="$pi_floor_before"
  else
    # The later of the two (same format, so they sort as text).
    pi_before="$(printf '%s\n' "$pi_before" "$pi_floor_before" | sort | tail -n 1)"
  fi
fi

# Installed as you into a scratch prefix, then copied root-owned where
# "npm install -g" would put it (/usr/local/lib/node_modules, linked
# from /usr/local/bin/pi), so npm never runs as root and a sandboxed
# agent can't change pi. It's copied only if anything differs,
# including its dependencies. --ignore-scripts: pi needs no install
# scripts, and this keeps its dependencies from running any.
pi_dir="/usr/local/lib/node_modules/$pi_package"
pi_have="$(jq -r .version "$pi_dir/package.json" 2> /dev/null)" || pi_have=""
echo "Downloading pi ($pi_spec) to compare with the installed one${pi_have:+ ($pi_have)}..."
rm -rf "${TMPDIR:?}/pi"
npm install -g --prefix "$TMPDIR/pi" --ignore-scripts --no-audit --no-fund \
  --cache "$npm_cache" --before "$pi_before" "$pi_spec"
if ! diff -rq --no-dereference "$TMPDIR/pi/lib/node_modules/$pi_package" "$pi_dir" >/dev/null 2>&1; then
  sudo mkdir -p "$(dirname "$pi_dir")"
  sudo rm -rf "$pi_dir"
  sudo cp -R "$TMPDIR/pi/lib/node_modules/$pi_package" "$pi_dir"
  sudo chown -R root:root "$pi_dir"
  sudo chmod -R go-w "$pi_dir"
  # A relative link (../lib/node_modules/...), so it works from here too.
  sudo cp -P "$TMPDIR/pi/bin/pi" /usr/local/bin/pi
  echo "Installed pi $(jq -r .version "$pi_dir/package.json")${pi_have:+ (was $pi_have)}."
else
  echo "pi $pi_have is already installed."
fi
rm -rf "${TMPDIR:?}/pi"

# infer-models (what the engine serves now, for any client, checked by
# infer-models.jq), and compart pi,
# which runs it each time pi starts and writes pi's models.json with
# pi-models.jq. So changing the models on the Mac needs nothing done
# here. An old models.json stays until compart pi first reaches the engine.
install_rendered infer-models.template.sh /usr/local/bin/infer-models 755 INFER_PORT
# pi reads global instructions from ~/.pi/agent/AGENTS.md, so point
# that at the shared ones, unless you've put your own file there.
pi_agents="$HOME/.pi/agent/AGENTS.md"
if [ ! -e "$pi_agents" ] && [ ! -L "$pi_agents" ]; then
  mkdir -p "$(dirname "$pi_agents")"
  ln -s "$HOME/.agents/AGENTS.md" "$pi_agents"
elif [ "$(readlink "$pi_agents" 2> /dev/null)" != "$HOME/.agents/AGENTS.md" ]; then
  echo "WARNING: $pi_agents isn't a link to ~/.agents/AGENTS.md, so pi doesn't get the shared instructions." >&2
fi
sudo install -d -m 755 /usr/local/libexec/bulkhead
sudo install -m 644 "$SCRIPT_DIR/infer-models.jq" "$SCRIPT_DIR/pi-models.jq" /usr/local/libexec/bulkhead/
# pi's thinking defaults, unless you've set your own (pi saves the
# level you pick): think at "high", with 32768 tokens for it instead of
# pi's 16384. Qwen evaluated Qwen3.8-27B's coding with up to 32768
# tokens per turn. pi treats "xhigh" as "high", so this budget is
# pi's most. Other settings in the file are kept.
pi_settings="$HOME/.pi/agent/settings.json"
mkdir -p "$(dirname "$pi_settings")"
[ -s "$pi_settings" ] || printf '%s' '{}' > "$pi_settings"
# Our pi extensions: pi-prose-style.js makes pi check what it writes
# with check-prose-style, as Claude Code's hook does, and
# pi-next-steps.js has pi act on NEXT-STEPS.md once it's done. They're
# root-owned, like the checker, so a sandboxed agent can't edit them.
sudo install -m 644 "$SCRIPT_DIR/pi-prose-style.js" \
  "$SCRIPT_DIR/pi-next-steps.js" /usr/local/libexec/bulkhead/
jq '.defaultThinkingLevel //= "high" | .thinkingBudgets.high //= 32768
    | reduce ($ARGS.positional[] | "/usr/local/libexec/bulkhead/" + .) as $ext
        (.; .extensions |= (. // [] | if any(. == $ext) then . else . + [$ext] end))' \
  "$pi_settings" --args pi-prose-style.js pi-next-steps.js \
  > "$TMPDIR/pi-settings.json.rendered"
cmp -s "$TMPDIR/pi-settings.json.rendered" "$pi_settings" ||
  cp "$TMPDIR/pi-settings.json.rendered" "$pi_settings"
rm -f "$TMPDIR/pi-settings.json.rendered"
# my-gen-image makes and edits images with the engine's image models,
# from any client with a shell. agents/ holds what clients look for in
# ~/.agents, e.g., its skill (agents/skills/my-gen-image), where Agent
# Skills clients (e.g., pi) find it. Other files there are kept.
sudo install -m 755 "$SCRIPT_DIR/my-gen-image" /usr/local/bin/
mkdir -p "$HOME/.agents"
cp -R "$SCRIPT_DIR/agents/." "$HOME/.agents/"
if [ ! -s "$INFER_KEY_FILE" ]; then
  echo "WARNING: no $INFER_KEY_FILE yet, so compart pi and infer-logs can't use the" >&2
  echo "local AI engine; run ./host-setup.sh on the Mac to copy it here." >&2
elif /usr/local/bin/infer-models > /dev/null; then
  echo "The engine answers; compart pi asks it for its models each time pi starts."
else
  echo "WARNING: the local AI engine didn't answer through the tunnel; compart pi needs" >&2
  echo "it (on the Mac, see ./infer-access.sh)." >&2
fi
install_rendered infer-logs.template.sh /usr/local/bin/infer-logs 755 INFER_PORT
# A systemd user unit, but root-owned in /etc/systemd/user.
sudo mkdir -p /etc/systemd/user
sudo install -m 644 "$SCRIPT_DIR/infer-logs@.service" /etc/systemd/user/
systemctl --user daemon-reload
systemctl --user enable infer-logs@proxy.service infer-logs@upstream.service
# Restart, not just start, to pick up a new infer-logs.
systemctl --user restart infer-logs@proxy.service infer-logs@upstream.service
echo "Once the Mac gives this VM access (./infer-access.sh shared), try: compart pi --print 'Say hello in five words.'"
echo "Engine logs: journalctl --user -u 'infer-logs@*'"

echo "== goose (see goose.md) =="
# The newest goose release that's at least INFER_COOLING_DAYS old, but
# not older than GOOSE_MIN; or GOOSE_PIN (see config.sh). Not through
# goose's installer, which checks nothing and runs goose unsandboxed
# (see goose.md). We accept its release file only if it matches the
# SHA-256 GitHub publishes and wasn't replaced after release (see
# fetch_asset), and GitHub attests that goose's own release workflow
# built it from that tag. gh needs a token to check that; the public
# read-only one is enough. Installed root-owned, so no agent can change
# it (e.g., with "goose update").
release_tmp="$TMPDIR/goose"
rm -rf "${release_tmp:?}"
mkdir -p "$release_tmp"
cooling_cutoff="$(cooling_cutoff)"
goose_tag="$(pick_release aaif-goose/goose '^v[0-9]+\.[0-9]+\.[0-9]+$' "$GOOSE_MIN" "$GOOSE_PIN")" ||
  die "can't choose a goose release (is GitHub reachable?)."
goose_have="$(/usr/local/bin/goose --version 2> /dev/null | tr -d ' ')" || goose_have=""
goose_have="${goose_have:+v$goose_have}"
if [ "$goose_have" = "$goose_tag" ]; then
  echo "goose $goose_tag is already installed."
else
  echo "Downloading, checking, and installing goose $goose_tag${goose_have:+ (replacing $goose_have)}..."
  # The .tar.gz, not the .tar.bz2: same binary, also attested, and it
  # unpacks in about 1 second instead of 9 (measured 2026-11-24).
  goose_file="goose-$(uname -m)-unknown-linux-gnu.tar.gz"
  fetch_asset aaif-goose/goose "$goose_tag" "$goose_file" ||
    die "can't download goose $goose_tag's $goose_file."
  goose_gh_token="$(secrets-client --context "vm-setup.sh: check goose's build" --get GH_PUBLIC_TOKEN)" ||
    die "can't get GH_PUBLIC_TOKEN, which gh needs to check goose's build."
  GH_TOKEN="$goose_gh_token" gh attestation verify "$release_tmp/$goose_file" \
    --repo aaif-goose/goose --source-ref "refs/tags/$goose_tag" \
    --signer-workflow aaif-goose/goose/.github/workflows/release.yml > /dev/null ||
    die "GitHub doesn't attest that goose's release workflow built $goose_file for $goose_tag."
  tar tzf "$release_tmp/$goose_file" > "$release_tmp/names"
  archive_names_ok < "$release_tmp/names" || die "$goose_file has an unsafe file name."
  mkdir "$release_tmp/unpack"
  tar xzf "$release_tmp/$goose_file" -C "$release_tmp/unpack"
  unpacked_tree_ok "$release_tmp/unpack" || die "$goose_file has an unsafe file."
  [ -f "$release_tmp/unpack/goose" ] || die "$goose_file has no goose."
  sudo install -m 755 "$release_tmp/unpack/goose" /usr/local/bin/goose
  echo "Installed goose $goose_tag${goose_have:+ (was $goose_have)}."
fi
rm -rf "${release_tmp:?}"
# goose reads the shared instructions (~/.agents/AGENTS.md) itself, so
# remove the link to them we used to make, which made goose read them
# twice.
goose_agents="$HOME/.config/goose/AGENTS.md"
if [ "$(readlink "$goose_agents" 2> /dev/null)" = "$HOME/.agents/AGENTS.md" ]; then
  rm "$goose_agents"
fi
echo "Once the Mac gives this VM access (./infer-access.sh shared), try: compart goose run --text 'Say hello in five words.'"

echo "== vm-setup.sh done =="
