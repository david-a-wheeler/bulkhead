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
# "heroku authorizations -j" through it. Checked against `apt-mark
# showmanual` on lftux and deliberately left out anything project-specific
# rather than universal: ruby, postgresql, and the heroku CLI are for one
# project (BadgeApp) and don't belong in a generic bulkhead repo;
# cmake, autoconf, bison, pkg-config, and the lib*-dev packages are
# ruby-build's prerequisites for compiling Ruby, same story; graphviz
# looked like it might be a project's doc-generation dependency rather
# than a general tool. Add project-specific packages by hand in that
# project's own setup, not here. "apt-get install -y" is naturally
# idempotent (a no-op once everything's already at the latest version), so
# this one line covers first install and every later re-run.
sudo apt-get update
sudo apt-get install -y openssh-server avahi-daemon nftables curl cups \
  qemu-guest-agent git shellcheck make build-essential vim python3 jq

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
  -o /tmp/githubcli-archive-keyring.gpg
sudo install -m 644 /tmp/githubcli-archive-keyring.gpg \
  /etc/apt/keyrings/githubcli-archive-keyring.gpg
rm -f /tmp/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y gh
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
if [ -z "$HOST_GATEWAY_IP" ]; then
  echo "ERROR: couldn't determine the default gateway; can't scope the secrets-server firewall rule safely." >&2
  exit 1
fi
render_template "$SCRIPT_DIR/nftables.template.conf" /tmp/nftables.conf.rendered \
  NFTABLES_ALLOWED_TCP_PORTS_NFT HOST_GATEWAY_IP SECRETS_SERVER_PORT
sudo cp /tmp/nftables.conf.rendered /etc/nftables.conf
rm -f /tmp/nftables.conf.rendered
sudo nft -f /etc/nftables.conf

echo "== Hardening CUPS (unix socket only, no TCP listener) =="
# Only comments an uncommented "Listen localhost:631" line, so this is
# already safe to re-run: once commented, the pattern no longer matches.
sudo sed -i '/^[[:space:]]*Listen localhost:631/s/^/#/' /etc/cups/cupsd.conf
sudo systemctl restart cups

echo "== Installing/updating nono =="
# nono ships prebuilt .deb/.rpm on GitHub Releases; no real apt repo
# backs it (confirmed earlier: apt-cache policy showed nothing), so this
# fetches the latest release's .deb for this VM's architecture directly
# and dpkg -i's it, the same way it's actually installed on lftux already
# (confirmed via dpkg.log: a direct "dpkg -i" of a downloaded .deb, not
# apt/a script). Re-running this always grabs whatever's currently latest,
# so updating nono is just re-running vm-setup.sh. Cargo/Homebrew (the
# project's other documented options) would mean a whole extra toolchain
# just to build a 25 MB tool we can get prebuilt.
nono_arch="$(dpkg --print-architecture)"
nono_deb_url="$(curl -fsSL https://api.github.com/repos/nolabs-ai/nono/releases/latest \
  | grep -o "https://github.com/nolabs-ai/nono/releases/download/[^\"]*_${nono_arch}\.deb" \
  | head -1)"
if [ -n "$nono_deb_url" ]; then
  # Version comes from the release tag in the URL path
  # (.../download/v0.74.0/...), not the .deb filename. That decouples this
  # from nono's asset-naming convention, only relying on GitHub's own
  # release-asset URL structure. dpkg-query fails (nonzero) if nono-cli
  # isn't installed yet, which is expected, not an error; old_version
  # just stays empty in that case.
  nono_new_version="$(printf '%s' "$nono_deb_url" | sed -n 's#.*/releases/download/\([^/]*\)/.*#\1#p')"
  nono_new_version="${nono_new_version#v}"
  nono_old_version="$(dpkg-query -W -f='${Version}' nono-cli 2>/dev/null || true)"
  if [ -n "$nono_old_version" ] && [ "$nono_old_version" = "$nono_new_version" ]; then
    echo "nono is already up to date (version $nono_new_version)."
  else
    curl -fsSL "$nono_deb_url" -o /tmp/nono-cli.deb
    sudo dpkg -i /tmp/nono-cli.deb
    rm -f /tmp/nono-cli.deb
    if [ -n "$nono_old_version" ]; then
      echo "Updated nono: $nono_old_version -> $nono_new_version"
    else
      echo "Installed nono $nono_new_version (was not previously installed)."
    fi
  fi
else
  echo "WARNING: couldn't find a nono .deb release for architecture $nono_arch; install manually:" >&2
  echo "  https://github.com/nolabs-ai/nono/releases" >&2
fi

echo "== Installing nono's default profile (nono-default-profile.json) =="
# "default" is nono's own reserved profile name: nolabs-ai/claude (and
# every other pack pulled below) declares "extends": "default" in its own
# profile.json, and a user profile of that name takes precedence over
# nono's built-in one. So this is the one place to grant filesystem access
# every harness needs (currently just $HOME/.rbenv and $HOME/.gitconfig),
# instead of a per-harness flag noclaude alone would have to carry.
# install_unless_locally_newer, not a plain cp: same reasoning as
# claude-CLAUDE.md below, an edit made directly to the installed copy
# (e.g. via nono's own profile tooling) shouldn't be silently clobbered.
mkdir -p "$HOME/.config/nono/profiles"
install_unless_locally_newer "$SCRIPT_DIR/nono-default-profile.json" \
  "$HOME/.config/nono/profiles/default.json"

echo "== Installing nono agent profiles (config.sh's NONO_AGENT_PROFILES) =="
# One pack per supported harness (noclaude's --profile nolabs-ai/claude
# is one of these); add another "namespace/name" to NONO_AGENT_PROFILES
# to support a new one, nothing else here changes. A missing pack is
# installed (obviously current, so no outdated check needed); an already
# installed one is left alone, with a notice printed if a newer version
# exists, so upgrading stays a deliberate, on-request choice per VM.
outdated_notices=""
for pack in $NONO_AGENT_PROFILES; do
  # Cleanup for nono's "always-further" -> "nolabs-ai" namespace move.
  nono remove "always-further/${pack#*/}" >/dev/null 2>&1 || true
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

echo "== Installing vm-git-helper (git credential helper) =="
# Plain file, no templating needed: it takes the secret name as an
# argument rather than having one baked in (see below), so it's
# installed the same way as heroku-session/gh-session, not rendered.
sudo cp "$SCRIPT_DIR/vm-git-helper" /usr/local/bin/vm-git-helper
sudo chmod +x /usr/local/bin/vm-git-helper

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
  git config --global "credential.https://${host}.helper" "/usr/local/bin/vm-git-helper ${secret}"
done
# Remove the old single global credential.helper from before this
# change, but only if it's still exactly what we used to set here:
# never touch a helper set for some other reason. Left in place, it'd
# be harmless (git tries it in addition to the per-host ones above and
# it'd just fail to exec, since the file's gone below), but there's no
# reason to leave a dangling reference to a deleted script around.
if [ "$(git config --global --get credential.helper 2>/dev/null)" = "/usr/local/bin/vm-git-helper.py" ]; then
  git config --global --unset credential.helper
fi
sudo rm -f /usr/local/bin/vm-git-helper.py

echo "== Installing secrets-client (generic secrets-server CLI, used by heroku-session/gh-session) =="
# Installed without a ".py" extension (see secrets-client.template.py):
# callers shouldn't need to know or care this happens to be Python.
render_template "$SCRIPT_DIR/secrets-client.template.py" /tmp/secrets-client.rendered \
  SECRETS_SERVER_PORT
sudo cp /tmp/secrets-client.rendered /usr/local/bin/secrets-client
sudo chmod +x /usr/local/bin/secrets-client
rm -f /tmp/secrets-client.rendered
# Cleanup from the pre-rename layout (secrets-client.py); harmless if
# never present.
sudo rm -f /usr/local/bin/secrets-client.py

echo "== Installing heroku-session, gh-session, and anon-access (secrets-client wrappers) =="
# Plain files, no templating needed: install directly rather than via
# render_template. Any shell can run these (they're just executables on
# $PATH), unlike the old bash-function versions removed from
# vm-bash-aliases-block.sh below.
sudo cp "$SCRIPT_DIR/heroku-session" "$SCRIPT_DIR/gh-session" "$SCRIPT_DIR/anon-access" /usr/local/bin/
sudo chmod +x /usr/local/bin/heroku-session /usr/local/bin/gh-session /usr/local/bin/anon-access

echo "== Installing noclaude (sandboxed Claude Code wrapper) =="
# Plain file, no templating needed: extra filesystem access beyond
# --profile nolabs-ai/claude now comes from nono-default-profile.json
# (installed above), not a side file rendered here. Built fresh every
# run, same as everything else here. Runs through anon-access above
# (install order doesn't matter, same reasoning as
# vm-git-helper/secrets-client: nothing invokes noclaude until well
# after this script has finished).
sudo cp "$SCRIPT_DIR/noclaude" /usr/local/bin/noclaude
sudo chmod +x /usr/local/bin/noclaude
# Cleanup from the pre-default.json layout; harmless if never present.
sudo rm -f /usr/local/etc/noclaude-extra-options

echo "== Configuring git niceties =="
configure_git_niceties

if [ "$want_claude" = true ]; then
  echo "== Installing Claude Code global instructions (CLAUDE.md) =="
  mkdir -p "$HOME/.claude"
  install_unless_locally_newer "$SCRIPT_DIR/claude-CLAUDE.md" "$HOME/.claude/CLAUDE.md"

  echo "== Installing check-prose-style.sh (AI-writing-tell PreToolUse hook) =="
  # Same install_unless_locally_newer treatment as claude-CLAUDE.md above:
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
  ' "$settings_file" > /tmp/claude-settings.json.rendered
  cp /tmp/claude-settings.json.rendered "$settings_file"
  rm -f /tmp/claude-settings.json.rendered
fi

echo "== Managing ~/.bash_aliases block (editor, BULKHEAD_AUTH_SESSION) =="
# Plain file, not rendered: no @@VAR@@ substitution left in it.
install_managed_block "$SCRIPT_DIR/vm-bash-aliases-block.sh" "$HOME/.bash_aliases"
rm -f /tmp/bash-aliases-block.rendered

if [ "$ENABLE_INFERENCE_SSH_TUNNEL" = "true" ]; then
  # Reserved for the "MAYBE" host-inference-engine SSH reverse tunnel from
  # architecture.md. The VM side needs nothing beyond sshd (already enabled
  # above); the host-side keygen/RemoteForward setup lives in host-setup.sh.
  # Not otherwise implemented yet; architecture.md itself marked it
  # speculative, and it's unrelated to git auth.
  :
fi

echo "== vm-setup.sh done =="
