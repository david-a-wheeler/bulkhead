#!/usr/bin/env bash
# Blocks Write/Edit/NotebookEdit calls that introduce text matching common
# "signs of AI writing".
#
# It's written to have reasonable performance (e.g., grep a pattern list)
# yet be easy to reead.

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

# One jq call reads the hook's JSON from stdin and emits just the text
# being written (nothing for other tools), so the JSON is never stored.
text="$(jq -r '
  if .tool_name == "Write" then .tool_input.content
  elif .tool_name == "Edit" then .tool_input.new_string
  elif .tool_name == "NotebookEdit" then .tool_input.new_source
  else empty end // empty')"
text="$(strip_quotes <<< "$text")"
[ -z "$text" ] && exit 0

violations=""

if grep -qF '—' <<< "$text"; then
  violations="${violations}em dash character: avoid this and similar constructs, use a colon, semicolon, parentheses, or two sentences instead; "
fi

# Name accuracy: the middle initial is required; always write out
# "David A. Wheeler" in full, never the shortened "David Wheeler".
if grep -qF "David Wheeler" <<< "$text"; then
  violations="${violations}incomplete name: \"David Wheeler\" found; \"David A. Wheeler\" is required instead; "
fi

# Literal AI-giveaway words/phrases. Curated from published "signs of AI
# writing" lists (Wikipedia's Signs_of_AI_writing, AI-detector
# word-frequency studies) down to the subset unlikely to appear in
# ordinary Rails/security prose, so this stays a low-noise mechanical
# filter rather than banning working vocabulary (deliberately excludes
# words with real technical meaning here, e.g. "landscape"/"ecosystem"/
# "robust"). No '$' or backtick characters appear below, so the plain
# double-quoted multi-line assignment is safe (no unwanted expansion).
phrase_list="dive into
diving into
let's dive in
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
it's important to note that
it is important to note that
it's worth noting that
it is worth noting that
needless to say
a plethora of
as an ai language model
as an ai assistant
i'm just an ai
i hope this helps
i hope that helps
great question
in conclusion,
in summary,
to summarize,"

matches="$(grep -oiF -e "$phrase_list" <<< "$text" | tr '[:upper:]' '[:lower:]' | sort -u)"
if [ -n "$matches" ]; then
  while IFS= read -r m; do
    violations="${violations}banned AI-giveaway phrase: \"$m\"; "
  done <<< "$matches"
fi

# Structural AI tell patterns checked as extended regexes (grep -E).
# Same one-call-against-the-whole-list shape
# as the phrase list above, so adding a new pattern is a one-line change.
pattern_list="it's not (just|only) [^.!?]{0,80} it's 
isn't (just|only) [^.!?]{0,80} it's 
plays a (key|pivotal|vital|crucial) role
in today's (ever-evolving|fast-paced|digital age)"

pattern_matches="$(grep -oiE -e "$pattern_list" <<< "$text" | tr '[:upper:]' '[:lower:]' | sort -u)"
if [ -n "$pattern_matches" ]; then
  while IFS= read -r m; do
    violations="${violations}banned pattern: \"$m\"; "
  done <<< "$pattern_matches"
fi

if [ -n "$violations" ]; then
  reason="AI-writing-tell violation(s): ${violations}Rewrite in the style requested for this session before writing this file."
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$reason}}'
  exit 0
fi

# Soft heuristic, not a hard rule: "word - word" or "word -- word"
# (letters on both sides, spaces around one or two hyphens) is sometimes
# a disguised em dash. The bullet-list filter (grep -v) drops the
# single biggest false-positive source in this repo's own docs: markdown
# "- term - description" lines (see AGENTS.md's command lists), where
# the dash is a field separator, not clause-joining. CLI/git
# end-of-options syntax (e.g. "git diff -- path/to/file") isn't
# line-filterable the same way, so it's named as a known non-issue in
# the warning text instead. Never denies, only "allow" + a message: the
# false-positive rate here is too high to block on.
dash_matches="$(grep -vE '^[[:space:]]*[-*+][[:space:]]' <<< "$text" \
    | grep -oiE '[[:alpha:]]{2,} (--|-) [[:alpha:]]{2,}' | tr '[:upper:]' '[:lower:]' | sort -u)"
if [ -n "$dash_matches" ]; then
  dash_list="$(sed 's/^/"/;s/$/"; /' <<< "$dash_matches" | tr -d '\n')"
  warn_msg="Heuristic flag (not a hard rule): found ${dash_list}each a word/hyphen(s)/word shape that's sometimes a disguised em dash. Double-check: if it's joining or breaking a clause the way an em dash would, rewrite it (colon, semicolon, parentheses, or two sentences). Known non-issues, ignore these: CLI/git end-of-options syntax (e.g. \"git diff -- path/to/file\"), a markdown list's \"term - description\" separator, and ordinary word ranges (\"Monday - Friday\")."
  jq -n --arg msg "$warn_msg" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow", systemMessage:$msg, additionalContext:$msg}}'
fi

exit 0
