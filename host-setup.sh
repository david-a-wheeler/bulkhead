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

echo "== Downloading local AI models into $MODELS_DIR (if missing) =="
# Near the end, since a download can take a while. Each goes to FILE.partial
# first (rerunning resumes it), so an unfinished or wrong download never
# looks like a model. A checksum mismatch deletes it and stops. Files
# are read-only; SHA256SUMS and SOURCES.tsv record each one's checksum
# and source. A here-document, not a pipe, so the loop runs in this
# shell and set -e can stop the script.
#
# Only formats that can't run code when loaded are allowed: GGUF and
# safetensors, both just a header plus raw numbers. Pickle-based formats
# (PyTorch's .bin, .pt, .pth, and .ckpt, and plain .pkl) can run
# arbitrary code when loaded, so a URL with one of those extensions is
# refused before downloading, and every download's first bytes must show
# GGUF (the bytes "GGUF") or safetensors (an 8-byte header length, then
# the JSON header's "{"); anything else is deleted and stops the script.
mkdir -p "$MODELS_DIR"
chmod 755 "$MODELS_DIR"
tmutil addexclusion "$MODELS_DIR"
[ -f "$MODELS_DIR/SOURCES.tsv" ] ||
  printf 'file\tsource_url\tlicense\tadded\n' > "$MODELS_DIR/SOURCES.tsv"
while read -r url sha256 license subdir; do
  # A multi-file model (e.g., an image model) names a subdirectory.
  file="${subdir:+$subdir/}$(basename "$url")"
  [ -f "$MODELS_DIR/$file" ] && continue
  case "$file" in
    *.bin | *.pt | *.pth | *.ckpt | *.pkl | *.pickle)
      echo "ERROR: $file is a pickle-based format, which can run code when loaded; refusing to download it." >&2
      exit 1
      ;;
  esac
  if [ -n "$subdir" ]; then
    mkdir -p "$MODELS_DIR/$subdir"
    chmod 755 "$MODELS_DIR/$subdir"
  fi
  echo "Downloading $file"
  curl -fL -C - -o "$MODELS_DIR/$file.partial" "$url"
  if [ "$(shasum -a 256 "$MODELS_DIR/$file.partial" | cut -d ' ' -f 1)" != "$sha256" ]; then
    rm -f "$MODELS_DIR/$file.partial"
    echo "ERROR: $file doesn't match its SHA-256; deleted it." >&2
    exit 1
  fi
  # The first 9 bytes as hex: 18 digits.
  case "$(head -c 9 "$MODELS_DIR/$file.partial" | od -An -tx1 | tr -d ' \n')" in
    47475546*) ;;          # GGUF
    ????????????????7b) ;; # safetensors
    *)
      rm -f "$MODELS_DIR/$file.partial"
      echo "ERROR: $file is neither GGUF nor safetensors; deleted it." >&2
      exit 1
      ;;
  esac
  mv "$MODELS_DIR/$file.partial" "$MODELS_DIR/$file"
  chmod 444 "$MODELS_DIR/$file"
  printf '%s  %s\n' "$sha256" "$file" >> "$MODELS_DIR/SHA256SUMS"
  printf '%s\t%s\t%s\t%s\n' "$file" "$url" "$license" "$(date +%Y-%m-%d)" >> "$MODELS_DIR/SOURCES.tsv"
done <<EOF
$MODEL_DOWNLOADS
EOF

echo "== Installing the local AI engine (llama.cpp and llama-swap) =="
# See local-ai-plan.md. llama-swap, which starts llama-server on demand,
# runs as a launchd daemon as MACOS_INFER_USER, under a sandbox profile
# that denies outbound network (except to its backend), file writes
# (except the Metal shader cache), and reads under /Users (except the
# models). No code of ours runs as root: launchd starts it, and the one
# sudoers rule below allows only restarting it. Everything is
# root-owned, so neither _infer nor you (without sudo) can change it.
# Pinned releases with checked SHA-256s; update them only deliberately.
LLAMA_BUILD=b11721
LLAMA_TARBALL="llama-$LLAMA_BUILD-bin-macos-arm64.tar.gz"
LLAMA_SHA256=2ace55512ee1ab4e2703f80c135c2a92d40d3367a5b3a98d21b103ffa7f0eb82
SWAP_VERSION=265
SWAP_TARBALL="llama-swap_${SWAP_VERSION}_darwin_arm64.tar.gz"
SWAP_SHA256=01d8d543198973dcfa52fd263e5696230ee1a77fb204f48c5d542761a67623b0
INFER_LIBEXEC=/usr/local/libexec/bulkhead/infer
INFER_ETC=/usr/local/etc/bulkhead
INFER_PROFILE="$INFER_ETC/infer.sb"
INFER_CONFIG="$INFER_ETC/llama-swap.yaml"
INFER_LABEL=local.bulkhead.infer
INFER_PLIST="/Library/LaunchDaemons/$INFER_LABEL.plist"
INFER_SUDOERS=/etc/sudoers.d/bulkhead-infer
# Each backend llama-server listens here, one at a time.
INFER_BACKEND_PORT=8999
INFER_KEY_FILE="$HOME/.config/bulkhead/infer-api-key"
LLAMA_DIR="$INFER_LIBEXEC/llama-$LLAMA_BUILD"
SWAP_DIR="$INFER_LIBEXEC/llama-swap-$SWAP_VERSION"
SWAP_BIN="$SWAP_DIR/llama-swap"
infer_tmp="$SCRIPT_DIR/.tmp/infer"
rm -rf "$infer_tmp"
mkdir -p "$infer_tmp"

# install_release URL SHA256 DEST [SUBDIR]: download a release tarball,
# check its SHA-256, and unpack it (or just its SUBDIR) into DEST,
# root-owned, unless DEST exists. It's unpacked as you, then copied, so
# the tarball's own file owners don't matter.
install_release() {
  [ -d "$3" ] && return 0
  tarball="$infer_tmp/$(basename "$1")"
  curl -fL -o "$tarball" "$1"
  if [ "$(shasum -a 256 "$tarball" | cut -d ' ' -f 1)" != "$2" ]; then
    echo "ERROR: $tarball doesn't match its SHA-256." >&2
    exit 1
  fi
  mkdir "$infer_tmp/unpack"
  tar xzf "$tarball" -C "$infer_tmp/unpack"
  sudo mkdir -p "$(dirname "$3")"
  sudo rm -rf "$3.partial"
  sudo cp -R "$infer_tmp/unpack${4:+/$4}" "$3.partial"
  sudo chown -R root:wheel "$3.partial"
  sudo chmod -R go-w "$3.partial"
  sudo mv "$3.partial" "$3"
  rm -rf "$infer_tmp/unpack" "$tarball"
}
# The llama.cpp tarball holds one directory, llama-BUILD.
install_release \
  "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_BUILD/$LLAMA_TARBALL" \
  "$LLAMA_SHA256" "$LLAMA_DIR" "llama-$LLAMA_BUILD"
install_release \
  "https://github.com/mostlygeek/llama-swap/releases/download/v$SWAP_VERSION/$SWAP_TARBALL" \
  "$SWAP_SHA256" "$SWAP_DIR"
"$SWAP_BIN" -version

# The API key: clients send it as "Authorization: Bearer KEY". Copy it
# to each VM that should use the engine (see vm-setup.sh).
if [ ! -s "$INFER_KEY_FILE" ]; then
  mkdir -p "$(dirname "$INFER_KEY_FILE")"
  (umask 077 && printf 'sk-%s\n' "$(head -c 32 /dev/urandom | base64 | tr -d '/+=')" > "$INFER_KEY_FILE")
fi
chmod 600 "$INFER_KEY_FILE"
infer_key="$(cat "$INFER_KEY_FILE")"

# _infer's per-user cache directory, for the Metal shader cache. The
# sandbox sees real paths, and /var is a symlink to /private/var.
metal_cache="$(sudo -u "$MACOS_INFER_USER" /usr/bin/getconf DARWIN_USER_CACHE_DIR)"
case "$metal_cache" in
  /var/folders/*) METAL_CACHE="/private${metal_cache%/}/com.apple.metal" ;;
  /private/var/folders/*) METAL_CACHE="${metal_cache%/}/com.apple.metal" ;;
  *)
    echo "ERROR: unexpected cache directory for $MACOS_INFER_USER: $metal_cache" >&2
    exit 1
    ;;
esac

# Render everything first.
if ! infer_llama_swap_yaml "$infer_key" "$LLAMA_DIR/llama-server" "$INFER_BACKEND_PORT" \
    > "$infer_tmp/llama-swap.yaml"; then
  echo "ERROR: config.sh's INFER_MODELS has a malformed line." >&2
  exit 1
fi
render_template "$SCRIPT_DIR/infer.template.sb" "$infer_tmp/infer.sb" \
  INFER_BACKEND_PORT METAL_CACHE MODELS_DIR
render_template "$SCRIPT_DIR/infer.template.plist" "$infer_tmp/infer.plist" \
  INFER_LABEL MACOS_INFER_USER INFER_PROFILE SWAP_BIN INFER_CONFIG INFER_PORT
plutil -lint "$infer_tmp/infer.plist"
# Only you may restart the engine without a password, and only this way.
printf '%s ALL=(root) NOPASSWD: /bin/launchctl kickstart -k system/%s\n' \
  "$(id -un)" "$INFER_LABEL" > "$infer_tmp/sudoers"

# A few checks that the profile blocks what matters most; if one fails,
# install nothing. Run as you, with no listener needed. (The trial in
# local-ai-plan.md's "Test results" checked more.)
sandboxed() {
  /usr/bin/sandbox-exec -f "$infer_tmp/infer.sb" "$@" >/dev/null 2>&1
}
infer_check_failed=false
if ! sandboxed /usr/bin/true; then
  echo "FAIL: the sandbox profile doesn't load" >&2
  infer_check_failed=true
fi
if sandboxed /usr/bin/curl -sS -m 10 -o /dev/null https://example.com; then
  echo "FAIL: the sandbox allows outbound HTTPS" >&2
  infer_check_failed=true
fi
if sandboxed /bin/ls "$HOME"; then
  echo "FAIL: the sandbox allows reading your home directory" >&2
  infer_check_failed=true
fi
if sandboxed /usr/bin/touch /private/var/tmp/bulkhead-infer-denied; then
  rm -f /private/var/tmp/bulkhead-infer-denied
  echo "FAIL: the sandbox allows writing to /private/var/tmp" >&2
  infer_check_failed=true
fi
if [ "$infer_check_failed" = true ]; then
  echo "ERROR: sandbox checks failed; not installing the engine's configuration." >&2
  exit 1
fi

# Install only what changed, so rerunning this doesn't restart the engine
# (and unload its model) for nothing.
infer_changed=false
# install_root SRC DEST GROUP MODE: install SRC as DEST, root-owned, if
# it differs. sudo cmp, since llama-swap.yaml isn't readable by you.
install_root() {
  if ! sudo cmp -s "$1" "$2"; then
    sudo mkdir -p "$(dirname "$2")"
    sudo install -o root -g "$3" -m "$4" "$1" "$2"
    infer_changed=true
  fi
}
# The config holds the API key, so only _infer can read it.
install_root "$infer_tmp/llama-swap.yaml" "$INFER_CONFIG" "$MACOS_INFER_USER" 640
install_root "$infer_tmp/infer.sb" "$INFER_PROFILE" wheel 644
install_root "$infer_tmp/infer.plist" "$INFER_PLIST" wheel 644
# As _infer (which can read the config), never as root.
sudo -u "$MACOS_INFER_USER" "$SWAP_BIN" -config "$INFER_CONFIG" -validate
# sudo ignores sudoers.d files whose names contain a dot, so check the
# new rule there before moving it into place: a broken sudoers file can
# lock you out of sudo.
infer_sudoers_changed=false
if ! sudo cmp -s "$infer_tmp/sudoers" "$INFER_SUDOERS"; then
  sudo install -o root -g wheel -m 440 "$infer_tmp/sudoers" "$INFER_SUDOERS.new"
  if ! sudo /usr/sbin/visudo -cf "$INFER_SUDOERS.new"; then
    sudo rm -f "$INFER_SUDOERS.new"
    echo "ERROR: visudo rejected the sudoers rule." >&2
    exit 1
  fi
  sudo mv "$INFER_SUDOERS.new" "$INFER_SUDOERS"
  infer_sudoers_changed=true
fi

# stop_daemon LABEL: unload a system daemon and wait until it's gone;
# loading the label again before then fails with "Bootstrap failed: 5:
# Input/output error". Stopping it stops llama-server too.
stop_daemon() {
  sudo launchctl bootout "system/$1" 2>/dev/null || true
  n=0
  while sudo launchctl print "system/$1" >/dev/null 2>&1; do
    if [ "$n" -ge 30 ]; then
      echo "ERROR: $1 is still loaded after 30 seconds." >&2
      exit 1
    fi
    sleep 1
    n=$((n + 1))
  done
}
# wait_for_engine: wait until llama-swap answers with the API key.
wait_for_engine() {
  n=0
  until /usr/bin/curl -sf -m 2 -H "Authorization: Bearer $infer_key" \
      "http://127.0.0.1:$INFER_PORT/v1/models" >/dev/null; do
    if [ "$n" -ge 30 ]; then
      echo "ERROR: llama-swap didn't start (its output goes to /dev/null). To see why, run it by hand:" >&2
      echo "  sudo -u $MACOS_INFER_USER /usr/bin/sandbox-exec -f $INFER_PROFILE $SWAP_BIN -config $INFER_CONFIG -listen 127.0.0.1:$INFER_PORT" >&2
      exit 1
    fi
    sleep 1
    n=$((n + 1))
  done
}

# Cleanup from the trial (,infer-test/trial.sh), which used the same port.
if [ -f /Library/LaunchDaemons/local.infer-trial.plist ]; then
  stop_daemon local.infer-trial
  sudo rm -f /Library/LaunchDaemons/local.infer-trial.plist
  echo "Removed the trial daemon. You can delete /Users/Shared/infer-test and /Users/Shared/trial.sh."
fi

infer_restarted=false
if [ "$infer_changed" = true ] || ! sudo launchctl print "system/$INFER_LABEL" >/dev/null 2>&1; then
  stop_daemon "$INFER_LABEL"
  sudo launchctl bootstrap system "$INFER_PLIST"
  wait_for_engine
  code="$(/usr/bin/curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$INFER_PORT/v1/models")" || true
  if [ "$code" != 401 ]; then
    echo "ERROR: llama-swap answered a request without the API key with HTTP $code, not 401." >&2
    exit 1
  fi
  infer_restarted=true
fi
# Earlier pinned releases, no longer used.
for d in "$INFER_LIBEXEC"/*; do
  [ "$d" = "$LLAMA_DIR" ] || [ "$d" = "$SWAP_DIR" ] || sudo rm -rf "$d"
done
rm -rf "$infer_tmp"
if [ "$infer_restarted" = true ] || [ "$infer_sudoers_changed" = true ]; then
  # Check the sudoers rule: forget sudo's cached password, then restart
  # the engine without one, as infer-access will. Nothing after this
  # needs sudo.
  sudo -k
  if ! sudo -n /bin/launchctl kickstart -k "system/$INFER_LABEL"; then
    echo "ERROR: the sudoers rule in $INFER_SUDOERS doesn't allow restarting the engine." >&2
    exit 1
  fi
  wait_for_engine
  echo "Started $INFER_LABEL; the sudoers rule works."
else
  echo "$INFER_LABEL is running and up to date."
fi

echo "== host-setup.sh done =="
