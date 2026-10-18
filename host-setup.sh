#!/bin/sh
# host-setup.sh: idempotent setup for the macOS host. POSIX sh throughout
# (no bash-only features), same as vm-setup.sh: what /bin/sh actually is
# on macOS isn't worth relying on either way.
#
# Run this after every "git pull" of this repo to converge the host to the
# repo's current config. Safe to re-run any time. Some steps have no
# reliable non-interactive equivalent (GUI-only System Settings toggles);
# those print exact instructions and wait for you to confirm, rather than
# guessing at a scriptable equivalent that might silently do the wrong
# thing (e.g. create an admin account, or toggle the wrong power setting).
#
# Does not touch secrets; see host-secrets.sh for that (run it once after
# the first host-setup.sh, and again whenever a token needs rotating).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/host-backend.sh"

# This script is macOS-only for now. Real incident: this got run on an
# Ubuntu VM by mistake, and its Mac-specific checks further down produced
# misleading results (no /Users, no _infer account, neither of which
# means anything on Linux) instead of just saying "wrong machine." Might
# loosen this later (e.g. a Linux host), but that's not supported today.
macos_only "host-setup.sh"

# Disabled: the check below was added after "ls /Users" failed with
# ENOENT, which looked like a Full Disk Access problem, but that test was
# run over an ssh session into the Linux VM, which has no /Users at all
# (it has /home); nothing was actually confirmed broken on macOS itself.
# Left here commented out, not deleted, in case FDA does turn out to be a
# real precondition later; uncomment and verify against an actual Mac
# shell first.
#
# echo "== Checking for Full Disk Access =="
# if ! ls /Users >/dev/null 2>&1; then
#   cat <<EOF >&2
# ERROR: can't read /Users: this terminal app doesn't have Full Disk
# Access, which recent macOS requires for account/directory lookups (id,
# dscl) that later steps in this script depend on.
#
# Fix: System Settings > Privacy & Security > Full Disk Access > enable it
# for whatever app you're running this script from (Terminal, iTerm2, etc.),
# then re-run this script.
# EOF
#   exit 1
# fi

echo "== Locking down home directory (macOS grants 'staff' group read by default) =="
chmod go-rwx "$HOME"

echo "== Creating the $MACOS_INFER_USER role account (if missing) =="
# We run local inference engines (llama.cpp, Stable Diffusion, ...) under
# an account "_infer" that can't read a real home directory. Thus, a compromised
# inference engine can't reach user files or keys. This _infer is a hidden role
# account, not a user created in System Settings. A user created in System Settings
# gets more perms, e.g., a login shell, a password, the "staff" group (whose members can read
# group-readable files across the system), sometimes File Sharing
# groups, and possibly a Secure Token that can unlock FileVault. This
# _infer account gets none of that: its own group, no interactive shell, no password, and
# /var/empty as its home. launchd needs none of those to run a daemon
# as it (UserName). dscl, not sysadminctl -addUser, since the latter
# creates a home directory and may grant a Secure Token.
#
# Everything else refers to the account by name. Its numeric ID only
# matters here, since dscl won't pick one: use the lowest ID from 400 to
# 499 (under 500, the range macOS uses for system and role accounts)
# that no user or group has, for both the group and the user. Scan
# rather than assume, since Apple's own accounts use some of that range.
#
# free_id KIND...: print the lowest ID from 400 to 499 that no user
# (KIND=Users) or group (KIND=Groups) in the listed KINDs has.
free_id() {
  for kind in "$@"; do
    if [ "$kind" = Users ]; then key=UniqueID; else key=PrimaryGroupID; fi
    dscl . -list "/$kind" "$key"
  done | awk '{ used[$2] = 1 }
    END { for (id = 400; id < 500; id++) if (!(id in used)) { print id; exit } }'
}
if ! dscl . -read "/Groups/$MACOS_INFER_USER" >/dev/null 2>&1; then
  gid="$(free_id Users Groups)"
  if [ -z "$gid" ]; then
    echo "ERROR: no unused ID from 400 to 499 for the $MACOS_INFER_USER group." >&2
    exit 1
  fi
  sudo dscl . -create "/Groups/$MACOS_INFER_USER"
  sudo dscl . -create "/Groups/$MACOS_INFER_USER" PrimaryGroupID "$gid"
  sudo dscl . -create "/Groups/$MACOS_INFER_USER" RealName "Local AI inference"
  sudo dscl . -create "/Groups/$MACOS_INFER_USER" Password '*'
fi
if ! id "$MACOS_INFER_USER" >/dev/null 2>&1; then
  gid="$(dscl . -read "/Groups/$MACOS_INFER_USER" PrimaryGroupID | awk '{ print $2 }')"
  # Match the group's ID if no user has it (e.g., the group was just
  # created above); otherwise take the next free user ID.
  if dscl . -list /Users UniqueID | awk -v id="$gid" '$2 == id { found = 1 } END { exit !found }'; then
    uid="$(free_id Users)"
  else
    uid="$gid"
  fi
  if [ -z "$uid" ]; then
    echo "ERROR: no unused user ID from 400 to 499 for $MACOS_INFER_USER." >&2
    exit 1
  fi
  sudo dscl . -create "/Users/$MACOS_INFER_USER"
  sudo dscl . -create "/Users/$MACOS_INFER_USER" UniqueID "$uid"
  sudo dscl . -create "/Users/$MACOS_INFER_USER" PrimaryGroupID "$gid"
  sudo dscl . -create "/Users/$MACOS_INFER_USER" RealName "Local AI inference"
  sudo dscl . -create "/Users/$MACOS_INFER_USER" UserShell /usr/bin/false
  sudo dscl . -create "/Users/$MACOS_INFER_USER" NFSHomeDirectory /var/empty
  sudo dscl . -create "/Users/$MACOS_INFER_USER" Password '*'
  sudo dscl . -create "/Users/$MACOS_INFER_USER" IsHidden 1
fi

echo "== Checking $MACOS_INFER_USER's group memberships =="
# Every account is in some groups through nested groups: e.g., each File
# Sharing group (com.apple.sharepoint.group.N) nests "everyone", and
# _lpoperator nests "localaccounts". So compare with "nobody", which
# has only those, and flag any other group (e.g., "staff"), which would
# give it access it shouldn't have. Group memberships are stored by
# short name, so a group can still list an old, deleted account of the
# same name. Warns rather than fixes, since removing someone else's
# group setup could be wrong.
baseline_groups="$(id -Gn nobody | tr ' ' '\n')"
extra_groups="$(id -Gn "$MACOS_INFER_USER" | tr ' ' '\n' |
  grep -vx "$MACOS_INFER_USER" | grep -vxF "$baseline_groups" | tr '\n' ' ' || true)"
if [ -n "$extra_groups" ]; then
  echo "WARNING: $MACOS_INFER_USER is in groups that nobody isn't: $extra_groups" >&2
  echo "  For a direct membership, remove it with: sudo dseditgroup -o edit -d $MACOS_INFER_USER -t user GROUP" >&2
  echo "  Otherwise, see how the group gets members: dscl . -read /Groups/GROUP GroupMembership NestedGroups" >&2
fi

echo "== Installing secrets-server.py =="
mkdir -p "$HOME/bin"
render_template "$SCRIPT_DIR/secrets-server.template.py" "$HOME/bin/secrets-server.py" \
  SECRETS_SERVER_PORT KEYCHAIN_PREFIX UTMCTL
chmod +x "$HOME/bin/secrets-server.py"
# Cleanup from pre-rename layouts (git_host_proxy.py, then
# secrets_server.py); harmless if these were never present.
rm -f "$HOME/bin/git_host_proxy.py" "$HOME/bin/secrets_server.py"

echo "== Installing the secrets-server LaunchAgent =="
mkdir -p "$HOME/Library/LaunchAgents"
render_template "$SCRIPT_DIR/com.user.secretsserver.template.plist" \
  "$HOME/Library/LaunchAgents/com.user.secretsserver.plist" HOME
uid="$(id -u)"
# Bootout the pre-rename label too, in case it's still loaded from before
# this change; otherwise it'd sit there running the now-orphaned copy of
# git_host_proxy.py above forever.
launchctl bootout "gui/$uid/com.user.githostproxy" 2>/dev/null || true
launchctl bootout "gui/$uid/com.user.secretsserver" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$HOME/Library/LaunchAgents/com.user.secretsserver.plist"
rm -f "$HOME/Library/LaunchAgents/com.user.githostproxy.plist"

echo "== Generating an SSH key for host->VM access (if missing) =="
# Plain ed25519, no hardware key: this is just for host-initiated
# convenience logins (ssh/scp into a VM by name), not for anything
# security-critical; VMs never get host secrets this way. The private key
# never leaves the host. The public half is pushed straight to each VM
# below via ssh-copy-id, rather than committed into this repo: a public key
# isn't a secret, but it *is* machine-generated, person-specific data, so
# tracking it here would mean anyone else reusing this repo either inherits
# this key or fights constant diff noise replacing it with their own,
# same category of problem config.local.sh already solves for config.sh.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "bulkhead host->VM access"
fi

echo "== Configuring SSH access to guests (~/.ssh/config + authorized_keys) =="
# enumerate_guests (host-backend.sh) asks the hypervisor which guests are
# running and what IP each one currently has, rather than maintaining a
# manual name->IP list: nothing to update here as guests are added,
# removed, renamed, or just get a new DHCP lease.
#
# ssh-copy-id installs the key from above on each guest using its normal
# login password (typed interactively): standard, boring, and it needs
# nothing from this repo or from vm-setup.sh. It's also already
# idempotent: once a guest has the key, ssh-copy-id authenticates with it
# directly and skips re-adding it, no password needed on later runs.
# accept-new avoids an unexpected host-key prompt on a guest's first-ever
# connection; a rejected or unreachable guest only warns, so one bad guest
# can't stop the others or the rest of this script.
if guests_output="$(enumerate_guests)"; then
  ssh_config_block="$(mktemp)"
  printf '%s\n' "$guests_output" \
    | while IFS=' ' read -r vm_name vm_ip; do
        [ -n "$vm_name" ] || continue
        cat <<HOSTBLOCK >> "$ssh_config_block"
Host $vm_name
    HostName $vm_ip
    User $VM_USER
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes

HOSTBLOCK
        if ! ssh-copy-id -i "$HOME/.ssh/id_ed25519.pub" \
             -o StrictHostKeyChecking=accept-new "$VM_USER@$vm_ip"; then
          echo "WARNING: couldn't copy the host's SSH key to $vm_name ($vm_ip); 'ssh $vm_name' will need a password until this succeeds." >&2
        fi
      done
  install_managed_block "$ssh_config_block" "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"
  rm -f "$ssh_config_block"
else
  echo "WARNING: couldn't enumerate guests (utmctl missing, or 'utmctl list' failed); skipping ~/.ssh/config setup. Check UTMCTL in config.sh." >&2
fi

if ! confirmation_done battery; then
  cat <<EOF

== Power settings (System Settings > Battery) ==

These are GUI-only toggles with no reliable scriptable equivalent, so set
them by hand if you haven't already:

  1. Options > enable "Prevent automatic sleeping on power adapter when the
     display is off".
  2. Charging > (i) > ensure "Optimized Battery Charging" is enabled.
  3. Energy Mode > On power adapter > switch to "High power".
  4. System Settings > General > Software Update > (i) next to Automatic
     Updates > toggle OFF "Install macOS updates" (you still want the other
     automatic-update options on; this just avoids an update rebooting you
     mid-work).

Also: keep the case open, and the back of the laptop raised if practical,
for airflow.

EOF
  confirm_once battery
fi

echo "== Configuring git niceties =="
configure_git_niceties

echo "== host-setup.sh done =="
