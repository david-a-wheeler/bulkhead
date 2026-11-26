# shellcheck shell=sh
# common.sh: shell functions shared by host-setup.sh and vm-setup.sh.
# Sourced only (no shebang needed): must stay POSIX sh, since it's sourced
# by both host-setup.sh/host-secrets.sh (macOS) and vm-setup.sh (Ubuntu's
# dash). Host-only, OS-specific functions (Keychain, utmctl) live in
# host-backend.sh instead, not here, since vm-setup.sh has no use for them.
#
# Source this after config.sh:
#   . "$(dirname "$0")/config.sh"
#   . "$(dirname "$0")/common.sh"

# Usage: macos_only <script-name-for-the-error-message>
# Exits with a clear error if this isn't running on macOS. Call this right
# after sourcing config.sh/common.sh (sourcing them is harmless on any
# platform, just variable/function definitions, so it's fine for the
# check to come after that, not before).
macos_only() {
  [ "$(uname -s)" = "Darwin" ] ||
    die "$1 is for the macOS host only (this machine reports '$(uname -s)')."
}

# Usage: linux_only <script-name-for-the-error-message>
# Exits with a clear error if this isn't running on Linux (the Ubuntu VMs).
linux_only() {
  [ "$(uname -s)" = "Linux" ] ||
    die "$1 is for the Ubuntu VMs only (this machine reports '$(uname -s)')."
}

# Usage: die <message>
# Prints "ERROR: <message>" to stderr and exits.
die() {
  echo "ERROR: $1" >&2
  exit 1
}

# Usage: retry <seconds> <command...>
# Runs <command> once a second until it succeeds, failing after
# <seconds> more tries.
retry() {
  n="$1"
  shift
  until "$@"; do
    [ "$n" -gt 0 ] || return 1
    sleep 1
    n=$((n - 1))
  done
}

# Usage: render_template <template-file> <dest-file> <VAR1> [<VAR2> ...]
# Substitutes every "@@VAR@@" in <template-file> with the current value of
# shell variable VAR (one already set, typically by config.sh), for each VAR
# named, writing the result to <dest-file>. Always fully overwrites <dest-file>
# so reruns can't leave a partially-substituted file behind.
render_template() {
  template="$1"
  dest="$2"
  shift 2
  sed_script=""
  for var in "$@"; do
    eval "val=\$$var"
    # Escape backslash, our '|' delimiter, and '&' (special in sed replacements).
    escaped=$(printf '%s' "$val" | sed -e 's/[\&|]/\\&/g')
    sed_script="${sed_script}s|@@${var}@@|${escaped}|g
"
  done
  sed -e "$sed_script" "$template" > "$dest"
}

# Usage: install_managed_block <block-content-file> <target-file>
# Inserts (or replaces) a marker-delimited block in <target-file>, leaving
# every other line in the file untouched. Safe to re-run: it always removes
# any previous bulkhead block before appending the current one, so the
# block never duplicates and always reflects the repo's current content.
install_managed_block() {
  block_file="$1"
  target="$2"
  begin_marker="# >>> bulkhead >>>"
  end_marker="# <<< bulkhead <<<"
  touch "$target"
  tmp="$(mktemp)"
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
  ' "$target" > "$tmp"
  {
    cat "$tmp"
    echo "$begin_marker"
    cat "$block_file"
    echo "$end_marker"
  } > "$tmp.new"
  # Leave the file alone when nothing changes.
  cmp -s "$tmp.new" "$target" || cat "$tmp.new" > "$target"
  rm -f "$tmp" "$tmp.new"
}

# Prints a file's mtime as a Unix timestamp. Tries GNU stat's syntax first
# (Ubuntu VMs), falls back to BSD stat's (macOS host): the two disagree on
# flags and neither errors usefully on the other's, so this is the portable
# way to get one number out of either.
_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

# Usage: install_unless_locally_newer <src-file> <dest-file>
# Copies <src-file> to <dest-file>, unless <dest-file> already exists,
# differs in content from <src-file>, AND is newer than it: in that case
# someone edited the installed copy directly rather than the repo, so this
# warns and prints the command to pull that edit back into the repo instead
# of silently overwriting it.
install_unless_locally_newer() {
  src="$1"
  dest="$2"
  if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
    if [ "$(_mtime "$dest")" -gt "$(_mtime "$src")" ]; then
      echo "WARNING: $dest is newer than $src and differs; leaving it alone." >&2
      echo "  To pull those changes back into the repo, run:" >&2
      echo "  cp \"$dest\" \"$src\"" >&2
      return 0
    fi
  fi
  cp "$src" "$dest"
}

# Usage: confirmation_done <name>
# True if <name> has previously been confirmed done (see mark_confirmed).
# For a manual step with no reliable way to check its actual state (a
# GUI-only System Settings toggle, say); lets it prompt once instead of on
# every run. Stored per-checkout under confirmations/ (gitignored: host and
# each VM confirm their own steps independently, and it's not something
# anyone else's clone should inherit).
confirmation_done() {
  [ -f "$SCRIPT_DIR/confirmations/$1" ]
}

# Usage: mark_confirmed <name>
# Records that <name> is done, so confirmation_done <name> is true from
# here on.
mark_confirmed() {
  mkdir -p "$SCRIPT_DIR/confirmations"
  touch "$SCRIPT_DIR/confirmations/$1"
}

# Usage: confirm_once <name>
# Prompts once for whether <name> is actually done, defaulting to "no" (a
# bare Enter means "keep asking next run," not "assume it's done"): only
# an explicit yes calls mark_confirmed. Call this after printing whatever
# instructions <name> needs, and only inside an
# `if ! confirmation_done <name>; then ... fi` block, so it's never shown
# again once confirmed.
confirm_once() {
  name="$1"
  printf '%s' "Confirmed these are set, so stop asking? [y/N] "
  read -r response
  case "$response" in
    y | Y | yes | YES) mark_confirmed "$name" ;;
    *) : ;;
  esac
}

# Usage: ask_once <name> <question>
# Asks <question> [y/N] exactly once ever (per checkout) and remembers the
# answer under confirmations/<name> (gitignored, same as
# confirmation_done/mark_confirmed): unlike confirm_once, a "no" is
# remembered permanently here too, not re-asked next run, since this is
# for a one-time preference (e.g. "install this optional thing?") rather
# than polling whether a manual step got done yet. Returns success if the
# stored or freshly-given answer is yes, failure if no. Delete
# confirmations/<name> to be asked again.
ask_once() {
  name="$1"
  question="$2"
  flag="$SCRIPT_DIR/confirmations/$name"
  if [ -f "$flag" ]; then
    [ "$(cat "$flag")" = "yes" ]
    return
  fi
  printf '%s [y/N] ' "$question"
  read -r response
  mkdir -p "$SCRIPT_DIR/confirmations"
  case "$response" in
    y | Y | yes | YES)
      echo "yes" > "$flag"
      return 0
      ;;
    *)
      echo "no" > "$flag"
      return 1
      ;;
  esac
}

# Usage: cooling_cutoff
# Prints the time INFER_COOLING_DAYS ago (UTC) as YYYY-MM-DDTHH:MM:SSZ,
# or dies if INFER_COOLING_DAYS isn't a number of days. Releases and
# model updates newer than this are too new to install. Works with
# macOS's date and GNU date. Run it as x="$(cooling_cutoff)" under set
# -e, so its death stops the caller too.
cooling_cutoff() {
  case "$INFER_COOLING_DAYS" in
    "" | *[!0-9]*) die "config.sh's INFER_COOLING_DAYS isn't a number of days." ;;
  esac
  date -u -v-"${INFER_COOLING_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "$INFER_COOLING_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ
}

# The release helpers below (github_api through fetch_asset) choose and
# download a GitHub project's release the way config.sh's
# INFER_COOLING_DAYS, *_MIN, and *_PIN settings describe. Before using
# them, set release_tmp (a scratch directory they may fill) and
# cooling_cutoff="$(cooling_cutoff)".
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
  github_api "$1/git/matching-refs/tags/v" > "$release_tmp/tags.json" || return 1
  tags="$(jq -r --arg re "$2" '
    [.[].ref | ltrimstr("refs/tags/") | select(test($re))]
    | sort_by(ltrimstr("v") | split(".") | map(tonumber)) | reverse | .[:20][]' \
    "$release_tmp/tags.json")" || return 1
  for tag in $tags; do
    code="$(curl -sSL -o "$release_tmp/release.json" -w '%{http_code}' \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$1/releases/tags/$tag")" || return 1
    case "$code" in
      200) ;;
      404) continue ;; # A tag without a release.
      *) return 1 ;;
    esac
    if jq -e --arg cutoff "$cooling_cutoff" \
        '((.draft or .prerelease) | not) and .published_at <= $cutoff' \
        "$release_tmp/release.json" >/dev/null; then
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
# $release_tmp, checked against the SHA-256 GitHub publishes for it.
fetch_asset() {
  github_api "$1/releases/tags/$2" > "$release_tmp/release.json" || return 1
  sha256="$(jq -r --arg n "$3" '.assets[] | select(.name == $n) | .digest // empty' "$release_tmp/release.json")"
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
    | if . <= $upload_window or . <= $cutoff then empty else . end' "$release_tmp/release.json")"
  if [ -n "$replaced" ]; then
    echo "ERROR: $3 in $1 $2 was replaced at $replaced, after its release was published; not using it." >&2
    return 1
  fi
  curl -fsSL -o "$release_tmp/$3" "https://github.com/$1/releases/download/$2/$3" || return 1
  if [ "$(shasum -a 256 "$release_tmp/$3" | cut -d ' ' -f 1)" != "$sha256" ]; then
    rm -f "${release_tmp:?}/${3:?}"
    echo "ERROR: $3 from $1 $2 doesn't match its SHA-256." >&2
    return 1
  fi
}
# Usage: archive_names_ok < NAMES
# Fails, naming each one, if any archive member name on stdin (e.g.,
# from "tar tzf") is absolute or has a ".." component, so it could unpack
# outside its directory. tar and unzip strip or refuse such names
# themselves; this keeps us from depending on which tar or unzip it is.
archive_names_ok() {
  awk '/^\// || /(^|\/)\.\.(\/|$)/ {
      print "  unsafe name: " $0 > "/dev/stderr"
      bad = 1
    }
    END { exit bad }'
}

# Usage: unpacked_tree_ok DIR
# Fails, naming each one, unless everything in DIR (an unpacked release)
# is a directory, a regular file with one link, or a symlink to a name
# in its own directory (e.g., llama.cpp's "libllama.dylib ->
# libllama.0.dylib"). So no link in DIR reaches outside it, and copying
# DIR into a root-owned place with "cp -R" (which copies symlinks as
# they are) can't leave a link to a file you could change.
unpacked_tree_ok() {
  bad="$(
    find "$1" \( -type f -links +1 \) -print -o \( ! -type f ! -type d ! -type l \) -print &&
      find "$1" -type l -exec sh -c '
        for l do
          case "$(readlink "$l")" in "" | . | .. | */*) echo "$l" ;; esac
        done' sh {} +
  )" || return 1
  [ -z "$bad" ] && return 0
  printf '%s\n' "$bad" | sed 's/^/  unsafe file: /' >&2
  return 1
}

# Usage: infer_engine_answers <api-key>
# True if the local AI engine (llama-swap) answers on INFER_PORT with
# <api-key>. On a VM, that's through its tunnel. The key reaches curl
# on its stdin, not its command line, which any process here can read.
infer_engine_answers() {
  printf 'Authorization: Bearer %s\n' "$1" |
    curl -sf -m 2 -H @- "http://127.0.0.1:$INFER_PORT/v1/models" >/dev/null
}

# git_config_set KEY VALUE: set a global git config value only if it
# differs, since every "git config --global" write replaces ~/.gitconfig
# (a new inode), which breaks sandboxes that granted the old file.
git_config_set() {
  [ "$(git config --global --get "$1" || true)" = "$2" ] ||
    git config --global "$1" "$2"
}

# Sets the git config values that make git pleasant to use day-to-day.
# GIT_USER_NAME/GIT_USER_EMAIL come from config.sh; the rest are fixed
# defaults worth having everywhere (fsck on transfer/fetch catches repo
# corruption early, autosetupremote saves a step on first push of a branch).
configure_git_niceties() {
  git_config_set user.name "$GIT_USER_NAME"
  git_config_set user.email "$GIT_USER_EMAIL"
  git_config_set init.defaultbranch main
  git_config_set push.autosetupremote true
  git_config_set transfer.fsckobjects true
  git_config_set fetch.fsckobjects true
}
