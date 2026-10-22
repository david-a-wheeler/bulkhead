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
. "$SCRIPT_DIR/host-models.sh"

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
  [ -n "$gid" ] || die "no unused ID from 400 to 499 for the $MACOS_INFER_USER group."
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
  [ -n "$uid" ] || die "no unused user ID from 400 to 499 for $MACOS_INFER_USER."
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
# Near the end, since a download can take a while. See host-models.sh
# for the checks. A here-document, not a pipe, so the loop runs in this
# shell and set -e can stop the script.
prepare_models_dir
while read -r url sha256 license subdir; do
  [ -n "$url" ] || continue
  download_model "$url" "$sha256" "$license" "$subdir"
done <<EOF
$MODEL_DOWNLOADS
EOF

echo "== Installing the local AI engine (llama.cpp and llama-swap) =="
# See local-ai-plan.md. llama-swap, which starts llama-server on demand,
# runs as a launchd daemon as MACOS_INFER_USER, under a sandbox profile
# that denies outbound network (except to its backend), file writes
# (except the Metal shader cache), and reads under /Users (except the
# models). No code of ours runs as root: launchd starts it, and the one
# sudoers rule below allows only restarting it.
#
# Each release goes in its own root-owned directory under /opt. The
# daemon's files name those directories, so a new release changes them
# and restarts the engine. A "current" symlink in each records what's
# installed, and the commands are linked through it into /usr/local/bin
# for your own use. config.sh's INFER_COOLING_DAYS, *_MIN, and *_PIN
# settings choose the releases.
INFER_ETC=/usr/local/etc/infer
INFER_PROFILE="$INFER_ETC/infer.sb"
INFER_CONFIG="$INFER_ETC/llama-swap.yaml"
INFER_PLIST="/Library/LaunchDaemons/$INFER_LABEL.plist"
INFER_SUDOERS=/etc/sudoers.d/infer
# The backends listen here: the generalist (a llama-server) on one port
# and the specialist (an sd-server) on the other, at most one of each at
# a time (see infer_llama_swap_yaml in host-models.sh).
INFER_GENERALIST_PORT=8999
INFER_SPECIALIST_PORT=8998
LLAMA_OPT=/opt/llama.cpp
SWAP_OPT=/opt/llama-swap
SD_OPT=/opt/stable-diffusion.cpp
infer_tmp="$SCRIPT_DIR/.tmp/infer"
rm -rf "${infer_tmp:?}"
mkdir -p "$infer_tmp"
command -v jq >/dev/null 2>&1 || die "jq is missing (macOS 15 and later include /usr/bin/jq)."

# The daemon runs what's in these directories, so only root may change
# them: otherwise a process running as you could swap in its own engine
# and see the secure VM's prompts. (An old Intel Homebrew install, e.g.,
# made parts of /usr/local yours.)
for d in /opt "$LLAMA_OPT" "$SWAP_OPT" "$SD_OPT" /usr/local /usr/local/etc "$INFER_ETC"; do
  sudo mkdir -p "$d"
  owner_mode="$(stat -f '%Su %Sp' "$d")"
  case "$owner_mode" in
    "root d"????-??-?) ;;
    *)
      echo "  To fix it: sudo chown root $d && sudo chmod go-w $d" >&2
      die "$d must be owned by root and writable only by root; it's $owner_mode."
      ;;
  esac
done

cooling_cutoff="$(cooling_cutoff)" ||
  die "config.sh's INFER_COOLING_DAYS isn't a number of days."

# github_api PATH: get PATH under a repository from GitHub's REST API.
# Unauthenticated, which allows 60 requests an hour; this makes a few.
github_api() {
  curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$1"
}
# version_older A B: true if release tag A (vX.Y.Z or vN) is older than B.
version_older() {
  jq -en --arg a "$1" --arg b "$2" \
    'def v: ltrimstr("v") | split(".") | map(tonumber); ($a | v) < ($b | v)' >/dev/null
}
# cooled_release REPO TAG_REGEX: print the tag of the newest release
# (not a draft or prerelease) whose tag matches TAG_REGEX (which must
# start with ^v) and that's at least INFER_COOLING_DAYS old, or nothing
# if none of the 20 newest matching tags is. It lists the tags, then
# gets their releases one at a time, newest first. Listing releases
# instead is far slower: llama.cpp publishes a prerelease for nearly
# every commit, so each page of 100 releases is about 8 MB and took 2
# minutes (2026-10-19).
cooled_release() {
  github_api "$1/git/matching-refs/tags/v" > "$infer_tmp/tags.json" || return 1
  tags="$(jq -r --arg re "$2" '
    [.[].ref | ltrimstr("refs/tags/") | select(test($re))]
    | sort_by(ltrimstr("v") | split(".") | map(tonumber)) | reverse | .[:20][]' \
    "$infer_tmp/tags.json")" || return 1
  for tag in $tags; do
    code="$(curl -sSL -o "$infer_tmp/release.json" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$1/releases/tags/$tag")" || return 1
    case "$code" in
      200) ;;
      404) continue ;; # A tag without a release.
      *) return 1 ;;
    esac
    if jq -e --arg cutoff "$cooling_cutoff" \
        '((.draft or .prerelease) | not) and .published_at <= $cutoff' \
        "$infer_tmp/release.json" >/dev/null; then
      echo "$tag"
      return 0
    fi
  done
}
# pick_release REPO TAG_REGEX MIN PIN: print the release tag to install:
# the newest one that's old enough (see cooled_release), but not one
# older than MIN; or PIN, if set.
pick_release() {
  if cooled="$(cooled_release "$1" "$2")"; then
    if [ -z "$cooled" ] || { [ -n "$3" ] && version_older "$cooled" "$3"; }; then
      cooled="$3"
    fi
  else
    # Can't reach GitHub; a pin needs it only to install.
    [ -n "$4" ] || return 1
    cooled=""
  fi
  if [ -n "$4" ]; then
    echo "WARNING: $1 is pinned to $4${cooled:+ (without it, the choice would be $cooled)}. Clear the pin in config.sh when you can." >&2
    echo "$4"
  else
    [ -n "$cooled" ] || return 1
    echo "$cooled"
  fi
}
# fetch_asset REPO TAG NAME: download release TAG's file NAME into
# $infer_tmp, checked against the SHA-256 GitHub publishes for it.
fetch_asset() {
  github_api "$1/releases/tags/$2" > "$infer_tmp/release.json" || return 1
  sha256="$(jq -r --arg n "$3" '.assets[] | select(.name == $n) | .digest // empty' "$infer_tmp/release.json")"
  case "$sha256" in
    sha256:*) sha256="${sha256#sha256:}" ;;
    *)
      echo "ERROR: GitHub lists no SHA-256 for $3 in $1 $2." >&2
      return 1
      ;;
  esac
  # Anyone with write access to the repository (or a stolen token) can
  # replace a release's files at any time, and GitHub computes the
  # SHA-256 above from whatever file is there now. So an old release
  # doesn't mean an old file, and the cooling period alone wouldn't stop
  # a file swapped in yesterday. Accept a file only if it was last
  # changed within an hour of its release's publication (the normal
  # upload), or hasn't changed for the whole cooling period.
  replaced="$(jq -r --arg n "$3" --arg cutoff "$cooling_cutoff" '
    (.published_at | fromdateiso8601 + 3600 | todateiso8601) as $upload_window
    | .assets[] | select(.name == $n) | .updated_at
    | if . <= $upload_window or . <= $cutoff then empty else . end' "$infer_tmp/release.json")"
  if [ -n "$replaced" ]; then
    echo "ERROR: $3 in $1 $2 was replaced at $replaced, after its release was published; not using it." >&2
    return 1
  fi
  curl -fsSL -o "$infer_tmp/$3" "https://github.com/$1/releases/download/$2/$3" || return 1
  if [ "$(shasum -a 256 "$infer_tmp/$3" | cut -d ' ' -f 1)" != "$sha256" ]; then
    rm -f "${infer_tmp:?}/${3:?}"
    echo "ERROR: $3 from $1 $2 doesn't match its SHA-256." >&2
    return 1
  fi
}
# choose_llama_build: print the llama.cpp build (bNNNNN) to install. A
# stable release names its build in its nightly-tag.txt; a pin may name
# a build directly.
choose_llama_build() {
  tag="$(pick_release ggml-org/llama.cpp '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    "$LLAMA_CPP_MIN" "$LLAMA_CPP_PIN")" || return 1
  case "$tag" in
    b*) build="$tag" ;;
    *)
      fetch_asset ggml-org/llama.cpp "$tag" nightly-tag.txt || return 1
      build="$(tr -d '[:space:]' < "$infer_tmp/nightly-tag.txt")"
      ;;
  esac
  printf '%s\n' "$build" | grep -qE '^b[0-9]+$' || return 1
  echo "$build"
}
# choose_swap_version: print the llama-swap version (NNN) to install.
choose_swap_version() {
  tag="$(pick_release mostlygeek/llama-swap '^v[0-9]+$' "$LLAMA_SWAP_MIN" "$LLAMA_SWAP_PIN")" ||
    return 1
  echo "${tag#v}"
}
# choose_sd_tag: print the stable-diffusion.cpp release to install (see
# config.sh's SD_CPP_PIN): the newest release old enough to install
# (see cooled_release). Its tags aren't versions, so unlike
# cooled_release this lists releases; at about two a day, 100 cover the
# cooling period.
choose_sd_tag() {
  if [ -n "$SD_CPP_PIN" ]; then
    echo "WARNING: stable-diffusion.cpp is pinned to $SD_CPP_PIN. Clear the pin in config.sh when you can." >&2
    echo "$SD_CPP_PIN"
    return 0
  fi
  github_api "leejet/stable-diffusion.cpp/releases?per_page=100" > "$infer_tmp/releases.json" || return 1
  jq -er --arg cutoff "$cooling_cutoff" '[.[]
    | select(((.draft or .prerelease) | not) and .published_at <= $cutoff
      and (.tag_name | test("^master-[0-9]+-[0-9a-f]+$")))]
    | max_by(.published_at) | .tag_name' "$infer_tmp/releases.json"
}
# release_or_installed NAME DIR COMMAND...: print the release COMMAND
# chooses, or if it can't (e.g., GitHub is unreachable), the one
# installed in DIR, with a warning.
release_or_installed() {
  name="$1"
  dir="$2"
  shift 2
  "$@" && return 0
  [ -L "$dir/current" ] || return 1
  echo "WARNING: couldn't choose a $name release; keeping $(readlink "$dir/current")." >&2
  readlink "$dir/current"
}
llama_build="$(release_or_installed llama.cpp "$LLAMA_OPT" choose_llama_build)" ||
  die "couldn't choose a llama.cpp release to install."
swap_version="$(release_or_installed llama-swap "$SWAP_OPT" choose_swap_version)" ||
  die "couldn't choose a llama-swap release to install."
sd_tag="$(release_or_installed stable-diffusion.cpp "$SD_OPT" choose_sd_tag)" ||
  die "couldn't choose a stable-diffusion.cpp release to install."
echo "llama.cpp $llama_build, llama-swap $swap_version, stable-diffusion.cpp $sd_tag"
LLAMA_SERVER="$LLAMA_OPT/$llama_build/llama-server"
SWAP_BIN="$SWAP_OPT/$swap_version/llama-swap"
SD_SERVER="$SD_OPT/$sd_tag/sd-server"

# install_release REPO TAG NAME DEST [SUBDIR]: unless DEST exists,
# download release TAG's tarball or zip NAME (see fetch_asset) and unpack
# it (or just its SUBDIR) into DEST, root-owned. It's unpacked as you,
# then copied, so the archive's own file owners don't matter. It refuses
# an archive with a name that could unpack outside its directory, or
# that unpacks to anything that could reach outside it (see
# archive_names_ok and unpacked_tree_ok in common.sh).
install_release() {
  [ -d "$4" ] && return 0
  fetch_asset "$1" "$2" "$3" || exit 1
  case "$3" in
    *.zip) unzip -Z1 "$infer_tmp/$3" > "$infer_tmp/names" ;;
    *) tar tzf "$infer_tmp/$3" > "$infer_tmp/names" ;;
  esac || die "couldn't list $3 from $1 $2."
  archive_names_ok < "$infer_tmp/names" ||
    die "$3 from $1 $2 has names that could unpack outside its directory; not installing it."
  mkdir "$infer_tmp/unpack"
  case "$3" in
    *.zip) unzip -q "$infer_tmp/$3" -d "$infer_tmp/unpack" ;;
    *) tar xzf "$infer_tmp/$3" -C "$infer_tmp/unpack" ;;
  esac
  unpacked_tree_ok "$infer_tmp/unpack" ||
    die "$3 from $1 $2 has links or special files that could reach outside it; not installing it."
  sudo rm -rf "${4:?}.partial"
  sudo cp -R "$infer_tmp/unpack${5:+/$5}" "$4.partial"
  sudo chown -R root:wheel "$4.partial"
  sudo chmod -R go-w "$4.partial"
  sudo mv "$4.partial" "$4"
  rm -rf "${infer_tmp:?}/unpack" "${infer_tmp:?}/names" "${infer_tmp:?}/${3:?}"
}
install_release ggml-org/llama.cpp "$llama_build" "llama-$llama_build-bin-macos-arm64.tar.gz" \
  "$LLAMA_OPT/$llama_build" "llama-$llama_build"
install_release mostlygeek/llama-swap "v$swap_version" "llama-swap_${swap_version}_darwin_arm64.tar.gz" \
  "$SWAP_OPT/$swap_version"
# stable-diffusion.cpp's zip name includes its build machine's macOS
# version, so look it up.
if [ ! -d "$SD_OPT/$sd_tag" ]; then
  sd_zip="$(github_api "leejet/stable-diffusion.cpp/releases/tags/$sd_tag" | jq -er '
    [.assets[].name | select(test("^sd-master-[0-9a-f]+-bin-Darwin-macOS-[0-9.]+-arm64\\.zip$"))]
    | if length == 1 then .[0] else error("expected one macOS zip, found \(length)") end')" ||
    die "couldn't find stable-diffusion.cpp $sd_tag's macOS zip."
  install_release leejet/stable-diffusion.cpp "$sd_tag" "$sd_zip" "$SD_OPT/$sd_tag"
fi
[ -x "$SD_SERVER" ] || die "stable-diffusion.cpp $sd_tag has no sd-server."
# Every run of the engine's programs is as _infer, never as you or
# root, from a directory it can enter.
as_infer() {
  (cd /var/empty && sudo -u "$MACOS_INFER_USER" "$@")
}
# runs_as_infer PROGRAM VERSION-OPTION: PROGRAM at least starts as
# _infer, so a bad signature, a missing library, or the wrong
# architecture shows up here, not at the engine's first request.
runs_as_infer() {
  as_infer "$1" "$2" ||
    die "$1 doesn't run as $MACOS_INFER_USER; its error, above, should say why."
}
runs_as_infer "$SWAP_BIN" -version
runs_as_infer "$LLAMA_SERVER" --version
runs_as_infer "$SD_SERVER" --version

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
metal_cache="$(as_infer /usr/bin/getconf DARWIN_USER_CACHE_DIR)"
case "$metal_cache" in
  /var/folders/*) METAL_CACHE="/private${metal_cache%/}/com.apple.metal" ;;
  /private/var/folders/*) METAL_CACHE="${metal_cache%/}/com.apple.metal" ;;
  *) die "unexpected cache directory for $MACOS_INFER_USER: $metal_cache" ;;
esac

# The models the engine serves (see infer-models.yaml), behind our
# settings. check_config, below, has llama-swap check the result.
if [ -f "$SCRIPT_DIR/infer-models.local.yaml" ]; then
  echo "Serving the models in infer-models.yaml and infer-models.local.yaml"
else
  echo "Serving the models in infer-models.yaml"
fi
with_infer_models infer_models_ok ||
  die "the models break the rules in infer-models.yaml's opening comment. infer-models.local.yaml now holds only the models you add, not a copy of infer-models.yaml."
with_infer_models infer_llama_swap_yaml "$infer_key" "$LLAMA_SERVER" "$INFER_GENERALIST_PORT" \
  "$SD_SERVER" "$INFER_SPECIALIST_PORT" \
  > "$infer_tmp/llama-swap.yaml"
render_template "$SCRIPT_DIR/infer.template.sb" "$infer_tmp/infer.sb" \
  INFER_GENERALIST_PORT INFER_SPECIALIST_PORT METAL_CACHE MODELS_DIR
render_template "$SCRIPT_DIR/infer.template.plist" "$infer_tmp/infer.plist" \
  INFER_LABEL MACOS_INFER_USER INFER_PROFILE SWAP_BIN INFER_CONFIG INFER_PORT
# Only you may restart the engine without a password, and only this way.
# The sleep watcher may also switch both power sources to Low Power Mode,
# and set each source's mode back (see infer-watch-hook.template.sh).
me="$(id -un)"
{
  printf '%s ALL=(root) NOPASSWD: /bin/launchctl kickstart -k system/%s\n' "$me" "$INFER_LABEL"
  printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a powermode 1\n' "$me"
  for source in b c; do
    for mode in 0 1 2; do
      printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -%s powermode %s\n' "$me" "$source" "$mode"
    done
  done
} > "$infer_tmp/sudoers"

# Each file's check, run on every run, so a change elsewhere (e.g., a
# macOS update that loosens the sandbox) is caught too.
# check_config FILE: llama-swap accepts FILE.
check_config() {
  as_infer "$SWAP_BIN" -config "$1" -validate
}
# check_profile FILE: a few checks that the sandbox profile FILE blocks
# what matters most. Run as you, with no listener needed. (The trial in
# local-ai-plan.md's "Test results" checked more.)
check_profile() {
  if ! /usr/bin/sandbox-exec -f "$1" /usr/bin/true; then
    echo "FAIL: the sandbox profile doesn't load" >&2
    return 1
  fi
  profile_ok=0
  sandbox_denies "$1" "outbound HTTPS" /usr/bin/curl -sS -m 10 -o /dev/null https://example.com ||
    profile_ok=1
  sandbox_denies "$1" "reading your home directory" /bin/ls "$HOME" || profile_ok=1
  sandbox_denies "$1" "writing to /private/var/tmp" \
    /usr/bin/touch /private/var/tmp/bulkhead-infer-denied || profile_ok=1
  rm -f /private/var/tmp/bulkhead-infer-denied
  return "$profile_ok"
}
# sandbox_denies PROFILE WHAT COMMAND...: fail, saying so, if the
# sandbox PROFILE lets COMMAND succeed.
sandbox_denies() {
  profile="$1"
  what="$2"
  shift 2
  if /usr/bin/sandbox-exec -f "$profile" "$@" >/dev/null 2>&1; then
    echo "FAIL: the sandbox allows $what" >&2
    return 1
  fi
}

# Stage each file, check it, and only then put them all in place, so a
# failed check leaves the running engine as it was, and the next run
# tries again. A file is checked where it will live (e.g., _infer must
# be able to read the config), as DEST.new: sudo ignores sudoers.d
# files whose names contain a dot, so a broken rule can't lock you out
# of sudo.
# stage SRC DEST GROUP MODE CHECK...: install SRC root-owned as DEST.new
# and run CHECK... DEST.new, stopping if it fails; then, if it's the
# same as DEST, discard it.
staged=""
stage() {
  src="$1"
  dest="$2"
  group="$3"
  mode="$4"
  shift 4
  sudo install -o root -g "$group" -m "$mode" "$src" "$dest.new"
  if ! "$@" "$dest.new"; then
    for f in $staged "$dest"; do
      sudo rm -f "$f.new"
    done
    die "$dest.new failed its check ($1); left $dest as it was."
  fi
  if sudo cmp -s "$dest.new" "$dest"; then
    sudo rm -f "$dest.new"
  else
    staged="$staged $dest"
  fi
}
# The config holds the API key, so only _infer can read it.
stage "$infer_tmp/llama-swap.yaml" "$INFER_CONFIG" "$MACOS_INFER_USER" 640 check_config
stage "$infer_tmp/infer.sb" "$INFER_PROFILE" wheel 644 check_profile
stage "$infer_tmp/infer.plist" "$INFER_PLIST" wheel 644 plutil -lint
stage "$infer_tmp/sudoers" "$INFER_SUDOERS" wheel 440 sudo /usr/sbin/visudo -cf
# Put everything staged in place. Only a change to the engine's own
# files needs a restart.
infer_changed=false
infer_sudoers_changed=false
for f in $staged; do
  sudo mv "$f.new" "$f"
  if [ "$f" = "$INFER_SUDOERS" ]; then
    infer_sudoers_changed=true
  else
    infer_changed=true
  fi
done
sudo ln -sfn "$llama_build" "$LLAMA_OPT/current"
sudo ln -sfn "$swap_version" "$SWAP_OPT/current"
sudo ln -sfn "$sd_tag" "$SD_OPT/current"

# Your own commands: each llama.cpp program, stable-diffusion.cpp's sd-*
# (not its start-server.sh), and llama-swap, linked into
# /usr/local/bin through "current", without replacing anything else
# there. Links to programs a newer release dropped are removed.
# link_command TARGET: link /usr/local/bin/NAME to TARGET.
link_command() {
  link="/usr/local/bin/$(basename "$1")"
  if [ -e "$link" ] || [ -L "$link" ]; then
    case "$(readlink "$link" 2>/dev/null)" in
      "$LLAMA_OPT"/* | "$SWAP_OPT"/* | "$SD_OPT"/*) ;;
      *)
        echo "WARNING: $link already exists; not replacing it." >&2
        return 0
        ;;
    esac
  fi
  sudo ln -sfn "$1" "$link"
}
sudo mkdir -p /usr/local/bin
for f in "$LLAMA_OPT/current"/* "$SD_OPT/current"/sd-*; do
  case "$f" in *.dylib) continue ;; esac
  if [ -f "$f" ] && [ -x "$f" ]; then
    link_command "$f"
  fi
done
link_command "$SWAP_OPT/current/llama-swap"
for link in /usr/local/bin/*; do
  if [ -L "$link" ] && [ ! -e "$link" ]; then
    case "$(readlink "$link")" in
      "$LLAMA_OPT"/* | "$SWAP_OPT"/* | "$SD_OPT"/*) sudo rm -f "$link" ;;
    esac
  fi
done

daemon_loaded() {
  sudo launchctl print "system/$1" >/dev/null 2>&1
}
daemon_unloaded() {
  ! daemon_loaded "$1"
}
# stop_daemon LABEL: unload a system daemon and wait until it's gone;
# loading the label again before then fails with "Bootstrap failed: 5:
# Input/output error". Stopping it stops llama-server too.
stop_daemon() {
  sudo launchctl bootout "system/$1" 2>/dev/null || true
  retry 30 daemon_unloaded "$1" || die "$1 is still loaded after 30 seconds."
}
wait_for_engine() {
  if ! retry 30 infer_engine_answers "$infer_key"; then
    echo "To see why, run it by hand: sudo -u $MACOS_INFER_USER /usr/bin/sandbox-exec -f $INFER_PROFILE $SWAP_BIN -config $INFER_CONFIG -listen 127.0.0.1:$INFER_PORT" >&2
    die "llama-swap didn't start (its output goes to /dev/null)."
  fi
}

# Cleanup from the trial (,infer-test/trial.sh), which used the same port.
if [ -f /Library/LaunchDaemons/local.infer-trial.plist ]; then
  stop_daemon local.infer-trial
  sudo rm -f /Library/LaunchDaemons/local.infer-trial.plist
  echo "Removed the trial daemon. You can delete /Users/Shared/infer-test and /Users/Shared/trial.sh."
fi

infer_restarted=false
if [ "$infer_changed" = true ] || ! daemon_loaded "$INFER_LABEL"; then
  stop_daemon "$INFER_LABEL"
  sudo launchctl bootstrap system "$INFER_PLIST"
  wait_for_engine
  code="$(/usr/bin/curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$INFER_PORT/v1/models")" || true
  [ "$code" = 401 ] ||
    die "llama-swap answered a request without the API key with HTTP $code, not 401."
  infer_restarted=true
fi
# prune_releases DIR KEEP: remove DIR's releases other than KEEP (and
# any unfinished install).
prune_releases() {
  for d in "$1"/*; do
    case "$d" in
      "$1/current" | "$1/$2") ;;
      "$1"/?*) sudo rm -rf "$d" ;;
    esac
  done
}
prune_releases "$LLAMA_OPT" "$llama_build"
prune_releases "$SWAP_OPT" "$swap_version"
prune_releases "$SD_OPT" "$sd_tag"
rm -rf "${infer_tmp:?}"
if [ "$infer_restarted" = true ] || [ "$infer_sudoers_changed" = true ]; then
  # Check the sudoers rule: restart the engine without a password, as
  # infer-access will. -k ignores sudo's cached password for just this
  # command, keeping it for a rerun.
  sudo -n -k /bin/launchctl kickstart -k "system/$INFER_LABEL" ||
    die "the sudoers rule in $INFER_SUDOERS doesn't allow restarting the engine."
  # -l only checks that the rule allows it, without running it.
  sudo -n -k -l /usr/bin/pmset -a powermode 1 >/dev/null ||
    die "the sudoers rules in $INFER_SUDOERS don't allow switching to Low Power Mode."
  wait_for_engine
  echo "Started $INFER_LABEL; the sudoers rule works."
  echo "To let VMs use it: ./infer-access.sh shared (see ./infer-access.sh status)"
else
  echo "$INFER_LABEL is running and up to date."
fi

echo "== Installing the sleep watcher (infer-watch) =="
# Before the Mac sleeps, it unloads the model, so the model's memory
# never goes into the sleep image; it also switches to Low Power Mode
# while the battery is low. See local-ai-plan.md, "Kill on sleep". It
# runs as you, as a launchd agent. I don't know of a trusted prebuilt
# tool that does this, so it's a small C program built here with Apple's
# Command Line Tools. It's rebuilt only when its source changes. There's
# no -Werror here: a new compiler or SDK may add warnings, and those
# shouldn't stop the install (ci.sh's strict build catches our mistakes).
WATCH_BIN="$HOME/bin/infer-watch"
mkdir -p "$HOME/bin" "$HOME/Library/Logs"
if [ -x "$WATCH_BIN" ] && cmp -s "$SCRIPT_DIR/infer-watch.c" "$WATCH_BIN.c"; then
  :
elif xcode-select -p >/dev/null 2>&1; then
  cc -O2 -Wall -Wextra -framework IOKit -framework CoreFoundation \
    -o "$WATCH_BIN.new" "$SCRIPT_DIR/infer-watch.c"
  mv "$WATCH_BIN.new" "$WATCH_BIN"
  cp "$SCRIPT_DIR/infer-watch.c" "$WATCH_BIN.c"
  echo "Built $WATCH_BIN."
elif [ -x "$WATCH_BIN" ]; then
  echo "WARNING: infer-watch.c changed, but there's no compiler to rebuild it; keeping the old build." >&2
  echo "  To rebuild it, run xcode-select --install, then rerun this." >&2
else
  echo "WARNING: there's no sleep watcher, since building it needs Apple's Command Line Tools." >&2
  echo "  Run xcode-select --install, then rerun this. Until then, run ./infer-access.sh off before the Mac sleeps." >&2
fi
if [ -x "$WATCH_BIN" ]; then
  render_template "$SCRIPT_DIR/infer-watch-hook.template.sh" "$HOME/bin/infer-watch-hook" \
    INFER_PORT INFER_KEY_FILE INFER_LABEL INFER_LOW_POWER_BELOW INFER_LOW_POWER_UNTIL
  chmod 755 "$HOME/bin/infer-watch-hook"
  watch_plist="$HOME/Library/LaunchAgents/$INFER_WATCH_LABEL.plist"
  render_template "$SCRIPT_DIR/infer-watch.template.plist" "$watch_plist" \
    INFER_WATCH_LABEL HOME
  plutil -lint -s "$watch_plist"
  my_uid="$(id -u)"
  watch_unloaded() {
    ! launchctl print "gui/$my_uid/$INFER_WATCH_LABEL" >/dev/null 2>&1
  }
  launchctl bootout "gui/$my_uid/$INFER_WATCH_LABEL" 2>/dev/null || true
  retry 10 watch_unloaded || die "$INFER_WATCH_LABEL is still loaded after 10 seconds."
  launchctl bootstrap "gui/$my_uid" "$watch_plist"
  echo "Started $INFER_WATCH_LABEL; its log is ~/Library/Logs/infer-watch.log."
  echo "It waits 2 minutes before it does anything. To stop it, run:"
  echo "  launchctl bootout gui/$my_uid/$INFER_WATCH_LABEL"
fi

echo "== host-setup.sh done =="
