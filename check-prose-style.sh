#!/bin/sh
# Blocks Write/Edit/NotebookEdit calls that introduce text matching common
# "signs of AI writing".
#
# Usage:
#   check-prose-style.sh          As a Claude Code PreToolUse hook: reads
#                                 the hook's JSON on stdin, prints its
#                                 decision as JSON, and exits 0.
#   check-prose-style.sh --text   Checks plain text on stdin, e.g., a
#                                 commit message. Prints nothing if it's
#                                 clean, else one message per line on
#                                 stderr. Exits 0 if clean (heuristic
#                                 warnings don't count), 1 on violations,
#                                 2 on usage errors.
#
# It's written to have reasonable performance (e.g., grep a pattern list)
# yet be easy to read.
#
# It's POSIX sh, with two exceptions where POSIX has no equivalent:
# grep's -o option and its \< and \> word boundaries. GNU, BSD (including
# macOS), and BusyBox grep all support both. BSD's [[:<:]] and [[:>:]]
# aren't POSIX either, and GNU grep rejects them.

set -eu

usage() {
  echo "Usage: check-prose-style.sh [--text]"
}
mode=hook
case $# in
  0) ;;
  1) case $1 in
       --text) mode=text ;;
       -h|--help) usage; exit 0 ;;
       *) usage >&2; exit 2 ;;
     esac ;;
  *) usage >&2; exit 2 ;;
esac

# Treat all text as UTF-8, whatever locale the hook is run with, so
# tools see “ and ” as single characters.
export LC_ALL=C.UTF-8

# Remove curly-double-quoted text (“...”) from stdin, including the
# end or beginning of such a quote, so quoting a source
# that uses a banned word or an em dash isn't flagged.
strip_quotes() {
  sed -e 's/“[^”]*”//g' -e 's/^[^“]*”//' -e 's/“[^”]*$//'
}

# Get the text to check and, for a hook's Edit, the text it replaces.
# A pipeline's status is its last command's, so set -e still catches a
# jq failure, e.g., bad JSON or a missing jq. Never eval anything
# derived from this input.
# $(cat) is much faster than bash's "read -d ''" on large input, since
# read must fetch one byte per system call from a pipe.
input="$(cat)"
old=""
if [ "$mode" = text ]; then
  text="$input"
else
  text="$(printf '%s\n' "$input" | jq -r '
    if .tool_name == "Write" then .tool_input.content
    elif .tool_name == "Edit" then .tool_input.new_string
    elif .tool_name == "NotebookEdit" then .tool_input.new_source
    else empty end // empty')"
  # Skip a jq when there's clearly no old_string. This test can only be
  # wrong in the safe direction: a false match just runs jq for nothing.
  case $input in
    *'"old_string"'*)
      old="$(printf '%s\n' "$input" | jq -r 'if .tool_name == "Edit" then .tool_input.old_string else empty end // empty')"
      [ -n "$old" ] && old="$(printf '%s\n' "$old" | strip_quotes)"
      ;;
  esac
fi
text="$(printf '%s\n' "$text" | strip_quotes)"
[ -z "$text" ] && exit 0

# Print what "grep -oi <args>" finds in the new text more often than in
# the old text, so an edit isn't blocked for keeping text that was
# already there (which would push the AI to rewrite someone else's
# words). Comparisons ignore case; each hit is printed once, as it first
# appears in the new text. The old text's hits reach awk through
# ENVIRON, which (unlike awk -v) doesn't process backslash escapes.
# grep exits 1 when it finds nothing, hence || true.
new_hits() {
  old_hits=""
  if [ -n "$old" ]; then
    old_hits="$(printf '%s\n' "$old" | grep -oi "$@")" || true
  fi
  printf '%s\n' "$text" | grep -oi "$@" | OLD_HITS="$old_hits" awk '
    BEGIN { n = split(ENVIRON["OLD_HITS"], a, "\n")
            for (i = 1; i <= n; i++) old[tolower(a[i])]++ }
    old[tolower($0)]-- > 0 { next }
    !seen[tolower($0)]++'
}

# Violation messages, one per line.
violations=""
nl='
'

# Banned text, as extended regexes (grep -E), one per line: the em
# dash, the incomplete name (the middle initial is required: "David A.
# Wheeler", never "David Wheeler"), then AI-giveaway words/phrases,
# curated from published "signs of AI writing" lists (Wikipedia's
# Signs_of_AI_writing, AI-detector word-frequency studies).
# The first two get specific messages below; keep their case labels in sync.
# Each entry starts with \< and ends with \> where its text starts or
# ends with a letter, so a banned word inside a longer one (e.g.,
# "empower" in "IORegisterForSystemPower") isn't flagged. That means
# inflected forms must be listed explicitly, e.g., "leverag(e|es|ed|ing)".
# A trailing space is written "[ ]" so no line ends in whitespace.
pattern_list="—
\<David Wheeler\>
\<dive into\>
\<diving into\>
\<let['’]s dive in\>
\<unleash(es|ed|ing)?\>
\<game-changing\>
\<game changers?\>
\<game changing\>
\<load-bearing\>
\<delve into\>
\<delves into\>
\<delving into\>
\<tapestr(y|ies)\>
\<testament to\>
\<a testament\>
\<vibrant(ly)?\>
\<meticulous(ly)?\>
\<intricate(ly)?\>
\<intricacies\>
\<underscores the\>
\<underscoring the\>
\<showcas(e|es|ed|ing)\>
\<cutting-edge\>
\<cutting edge\>
\<revolutioniz(e|es|ed|ing)\>
\<revolutionary leaps?\>
\<paradigm shifts?\>
\<synerg(y|ies)\>
\<seamless(ly)?\>
\<harness the\>
\<unlocks? the potential\>
\<leverag(e|es|ed|ing)\>
\<empower(s|ed|ing|ment)?\>
\<stands as a testament\>
\<serves as a reminder\>
\<serves as a testament\>
\<cannot be overstated\>
\<it['’]s important to note that\>
\<it is important to note that\>
\<it['’]s worth noting that\>
\<it is worth noting that\>
\<needless to say\>
\<a plethora of\>
\<as an ai language model\>
\<as an ai assistant\>
\<i['’]m just an ai\>
\<i hope this helps\>
\<i hope that helps\>
\<great question\>
\<in conclusion,
\<in summary,
\<to summarize,
\<it['’]s not (just|only) [^.!?]{0,80} it['’]s[ ]
\<isn['’]t (just|only) [^.!?]{0,80} it['’]s[ ]
\<plays a (key|pivotal|vital|crucial) role\>
\<in today['’]s (ever-evolving|fast-paced|digital age)\>"

# One grep finds every new hit; then each hit gets its message. Remove
# control characters except newline (e.g., terminal escape sequences)
# from text we're about to echo back in a message.
matches="$(new_hits -E -e "$pattern_list" | tr -d '\001-\011\013-\037\177')"
if [ -n "$matches" ]; then
  # A here-document, not a pipe, so the loop runs in this shell and
  # its changes to violations survive.
  while IFS= read -r m; do
    case "$(printf '%s\n' "$m" | tr '[:upper:]' '[:lower:]')" in
      —) violations="${violations}em dash character: avoid this and similar constructs, use a colon, semicolon, parentheses, or two sentences instead$nl" ;;
      "david wheeler") violations="${violations}incomplete name: \"$m\" found; \"David A. Wheeler\" is required instead$nl" ;;
      *) violations="${violations}banned AI-giveaway phrase: \"$m\"$nl" ;;
    esac
  done <<EOF
$matches
EOF
fi

if [ -n "$violations" ] && [ "$mode" = hook ]; then
  reason="AI-writing-tell violation(s): $(printf '%s' "$violations" | sed 's/$/; /' | tr -d '\n')Rewrite in the style requested for this session before writing this file."
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$reason}}'
  exit 0
fi

# Soft heuristic, not a hard rule: "word - word" or "word -- word"
# (letters on both sides, spaces around one or two hyphens) is sometimes
# a disguised em dash. We ignore markdown
# "- term - description" lines (see AGENTS.md's command lists), where
# the dash is a field separator, not clause-joining. CLI/git
# end-of-options syntax (e.g. "git diff -- path/to/file") isn't
# line-filterable the same way, so it's named as a known non-issue in
# the warning text instead. Never denies, only "allow" + a message: the
# false-positive rate here is too high to implement a block. In --text
# mode, it's reported along with any violations.
dash_matches="$(printf '%s\n' "$text" | grep -vE '^[[:space:]]*[-*+][[:space:]]' \
    | grep -oiE '[[:alpha:]]{2,} (--|-) [[:alpha:]]{2,}' | awk '!seen[tolower($0)]++')"
if [ "$mode" = text ]; then
  {
    printf '%s' "$violations"
    [ -z "$dash_matches" ] ||
      printf '%s\n' "$dash_matches" | sed 's/.*/warning (heuristic, not a violation): "&" may be a disguised em dash/'
  } | sed 's/^/check-prose-style: /' >&2
  [ -z "$violations" ] || exit 1
  exit 0
fi
if [ -n "$dash_matches" ]; then
  dash_list="$(printf '%s\n' "$dash_matches" | sed 's/^/"/;s/$/"; /' | tr -d '\n')"
  warn_msg="Heuristic flag (not a hard rule): found ${dash_list}each a word/hyphen(s)/word shape that's sometimes a disguised em dash. Double-check: if it's joining or breaking a clause the way an em dash would, rewrite it (colon, semicolon, parentheses, or two sentences). Known non-issues, ignore these: CLI/git end-of-options syntax (e.g. \"git diff -- path/to/file\"), a markdown list's \"term - description\" separator, and ordinary word ranges (\"Monday - Friday\")."
  jq -n --arg msg "$warn_msg" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow", systemMessage:$msg, additionalContext:$msg}}'
fi

exit 0
