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
  } > "$target"
  rm -f "$tmp"
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
# or fails if INFER_COOLING_DAYS isn't a number of days. Releases and
# model updates newer than this are too new to install. Works with
# macOS's date and GNU date.
cooling_cutoff() {
  case "$INFER_COOLING_DAYS" in "" | *[!0-9]*) return 1 ;; esac
  date -u -v-"${INFER_COOLING_DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "$INFER_COOLING_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ
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
# <api-key>. On a VM, that's through its tunnel.
infer_engine_answers() {
  curl -sf -m 2 -H "Authorization: Bearer $1" \
    "http://127.0.0.1:$INFER_PORT/v1/models" >/dev/null
}

# Usage: infer_engine_models <api-key>
# Prints the models the local AI engine serves (llama-swap's /v1/models
# listing, as JSON), or fails if it doesn't answer on INFER_PORT. On a
# VM, that's through its tunnel.
infer_engine_models() {
  curl -sf -m 10 -H "Authorization: Bearer $1" \
    "http://127.0.0.1:$INFER_PORT/v1/models"
}

# Usage: infer_pi_models_json < LISTING
# Prints pi's ~/.pi/agent/models.json for LISTING (from
# infer_engine_models): one "mac-local" provider, reached through the
# VM's tunnel on INFER_PORT, with every model and variant the engine
# serves (see models.local.yaml on the Mac). pi reads the literal
# ${INFER_API_KEY} from its environment (nopi sets it). Fails on a model
# without capabilities.context or metadata.max_tokens, or a name with
# characters other than letters, digits, '.', '_', ':', and '-'. jq
# writes the JSON, so the listing can't inject anything into it.
# Every model so far is a reasoning model. thinkingTokenBudgetField makes
# pi send each thinking level's budget (e.g., 8192 for "medium") in the
# field llama-server reads; otherwise every level gets the server's
# --reasoning-budget. thinkingLevelMap makes "off" send
# reasoning_effort "none", which turns thinking off; otherwise pi sends
# nothing and the model still thinks.
infer_pi_models_json() {
  # shellcheck disable=SC2016
  jq --arg url "http://127.0.0.1:$INFER_PORT/v1" '{
    "$schema": "https://pi.dev/schemas/models.schema.json",
    providers: {"mac-local": {
      baseUrl: $url,
      api: "openai-completions",
      apiKey: "${INFER_API_KEY}",
      compat: {thinkingTokenBudgetField: "thinking_budget_tokens"},
      models: [.data[]
        # pi can only chat, so list only the models that output text,
        # or that report no modalities (llama-swap learns those for a
        # llama-server model only once it loads), not e.g. image models.
        | select((.architecture.output_modalities // ["text"]) | any(. == "text"))
        | if (.id | test("^[A-Za-z0-9._:-]+$") | not) then error("bad model name: \(.id)")
        elif (.context_length | type) != "number" or (.meta.llamaswap.max_tokens | type) != "number"
        then error("\(.id) lacks capabilities.context or metadata.max_tokens")
        else {
          id: .id,
          name: ((.name // .id) +
            (if .meta.llamaswap.type == "alias" then " (\(.id))" else "" end)),
          reasoning: true,
          thinkingLevelMap: {off: "none"},
          contextWindow: .context_length,
          maxTokens: .meta.llamaswap.max_tokens
        } end]
    }}
  }'
}

# Usage: infer_default_model < LISTING
# Prints the name of the model whose metadata says "default: true" in
# LISTING (from infer_engine_models), not counting its variants (whose
# type is "alias", and which repeat its metadata), or nothing if there's
# none.
infer_default_model() {
  jq -r '[.data[] | select(.meta.llamaswap.default == true and
    .meta.llamaswap.type != "alias")][0].id // empty'
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
