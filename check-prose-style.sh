#!/usr/bin/env bash
# Blocks Write/Edit/NotebookEdit calls that introduce text matching common
# "signs of AI writing".
#
# It's written to have reasonable performance (e.g., grep a pattern list)
# yet be easy to read.

set -eu

# Treat all text as UTF-8, whatever locale the hook is run with, so
# tools see “ and ” as single characters.
export LC_ALL=C.UTF-8

# Remove curly-double-quoted text (“...”) from stdin, including the
# end or beginning of such a quote, so quoting a source
# that uses a banned word or an em dash isn't flagged.
strip_quotes() {
  sed -e 's/“[^”]*”//g' -e 's/^[^“]*”//' -e 's/“[^”]*$//'
}

# Extract the text being written and, for Edit, the text it replaces.
# Each jq runs as a plain command (not in a pipeline), so set -e catches
# a jq failure, e.g., bad JSON or a missing jq. Never eval anything
# derived from this input.
# read is a builtin, so this needs no subshell or cat process. It
# returns 1 at end of input (there's no NUL delimiter), hence || true.
IFS= read -r -d '' input || true
text="$(jq -r '
  if .tool_name == "Write" then .tool_input.content
  elif .tool_name == "Edit" then .tool_input.new_string
  elif .tool_name == "NotebookEdit" then .tool_input.new_source
  else empty end // empty' <<< "$input")"
text="$(strip_quotes <<< "$text")"
[ -z "$text" ] && exit 0
# Skip a jq when there's clearly no old_string. This test can only be
# wrong in the safe direction: a false match just runs jq for nothing.
old=""
if [[ "$input" == *'"old_string"'* ]]; then
  old="$(jq -r 'if .tool_name == "Edit" then .tool_input.old_string else empty end // empty' <<< "$input")"
  [ -n "$old" ] && old="$(strip_quotes <<< "$old")"
fi

# Print what "grep -oi <args>" finds in the new text more often than in
# the old text, so an edit isn't blocked for keeping text that was
# already there (which would push the AI to rewrite someone else's
# words). Comparisons ignore case; each hit is printed once, as it first
# appears in the new text. awk checks FILENAME, not NR == FNR, since the
# old text often has no hits, making its "file" empty. With no old
# text, only the new text needs a grep.
new_hits() {
  if [ -z "$old" ]; then
    grep -oi "$@" <<< "$text" | awk '!seen[tolower($0)]++'
    return
  fi
  awk 'FILENAME == ARGV[1] { old[tolower($0)]++; next }
       old[tolower($0)]-- > 0 { next }
       !seen[tolower($0)]++' \
    <(grep -oi "$@" <<< "$old") <(grep -oi "$@" <<< "$text")
}

violations=""

# Banned text, as extended regexes (grep -E), one per line: the em
# dash, the incomplete name (the middle initial is required: "David A.
# Wheeler", never "David Wheeler"), then AI-giveaway words/phrases,
# curated from published "signs of AI writing" lists (Wikipedia's
# Signs_of_AI_writing, AI-detector word-frequency studies).
# The first two get specific messages below; keep their case labels in sync.
pattern_list="—
David Wheeler
dive into
diving into
let['’]s dive in
unleash
unleashing
game-changing
game changer
game changing
load-bearing
delve into
delves into
delving into
tapestry
testament to
a testament
vibrant
meticulous
meticulously
intricate
intricacies
underscores the
underscoring the
showcase
showcasing
cutting-edge
cutting edge
revolutionize
revolutionary leap
paradigm shift
synergy
synergies
seamless
seamlessly
harness the
unlock the potential
unlocks the potential
leverage
leveraging
empower
empowering
stands as a testament
serves as a reminder
serves as a testament
cannot be overstated
it['’]s important to note that
it is important to note that
it['’]s worth noting that
it is worth noting that
needless to say
a plethora of
as an ai language model
as an ai assistant
i['’]m just an ai
i hope this helps
i hope that helps
great question
in conclusion,
in summary,
to summarize,
it['’]s not (just|only) [^.!?]{0,80} it['’]s 
isn['’]t (just|only) [^.!?]{0,80} it['’]s 
plays a (key|pivotal|vital|crucial) role
in today['’]s (ever-evolving|fast-paced|digital age)"

# One grep finds every new hit; then each hit gets its message.
matches="$(new_hits -E -e "$pattern_list")"
if [ -n "$matches" ]; then
  shopt -s nocasematch
  while IFS= read -r m; do
    # Remove control characters (e.g., terminal escape sequences) from
    # text we're about to echo back in a message.
    m="${m//[[:cntrl:]]/}"
    case "$m" in
      —) violations="${violations}em dash character: avoid this and similar constructs, use a colon, semicolon, parentheses, or two sentences instead; " ;;
      "David Wheeler") violations="${violations}incomplete name: \"$m\" found; \"David A. Wheeler\" is required instead; " ;;
      *) violations="${violations}banned AI-giveaway phrase: \"$m\"; " ;;
    esac
  done <<< "$matches"
fi

if [ -n "$violations" ]; then
  reason="AI-writing-tell violation(s): ${violations}Rewrite in the style requested for this session before writing this file."
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
# false-positive rate here is too high to implement a block.
dash_matches="$(grep -vE '^[[:space:]]*[-*+][[:space:]]' <<< "$text" \
    | grep -oiE '[[:alpha:]]{2,} (--|-) [[:alpha:]]{2,}' | awk '!seen[tolower($0)]++')"
if [ -n "$dash_matches" ]; then
  dash_list="$(sed 's/^/"/;s/$/"; /' <<< "$dash_matches" | tr -d '\n')"
  warn_msg="Heuristic flag (not a hard rule): found ${dash_list}each a word/hyphen(s)/word shape that's sometimes a disguised em dash. Double-check: if it's joining or breaking a clause the way an em dash would, rewrite it (colon, semicolon, parentheses, or two sentences). Known non-issues, ignore these: CLI/git end-of-options syntax (e.g. \"git diff -- path/to/file\"), a markdown list's \"term - description\" separator, and ordinary word ranges (\"Monday - Friday\")."
  jq -n --arg msg "$warn_msg" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow", systemMessage:$msg, additionalContext:$msg}}'
fi

exit 0
