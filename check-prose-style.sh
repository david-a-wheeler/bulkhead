#!/usr/bin/env bash
# Blocks Write/Edit/NotebookEdit calls that introduce text matching common
# "signs of AI writing": filler AI-vocabulary words, promotional-puffery
# clichés, canned AI-assistant stock phrases, structural contrast clichés,
# em dashes, and a required-full-name check. Mechanical check, PreToolUse
# so the bad content never lands. The actual style rules come from
# whatever CLAUDE.md / system prompt governs this session; this hook just
# enforces the character-level tells at write time so they never need a
# manual re-read pass.
#
# Performance note: the phrase list below is a plain multi-line variable
# assignment (no `cat`/heredoc subshell needed to build it), and it's
# checked with one `grep -oF -f` call against the whole list at once
# (grep does the looping in C, not bash). -o reports the matched
# substrings directly, so there's no second pass to figure out what
# matched. Violations accumulate in a plain "; "-joined string rather
# than a bash array, since a string append does everything needed here.
set -euo pipefail

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

case "$tool_name" in
  Write) field='.tool_input.content' ;;
  Edit) field='.tool_input.new_string' ;;
  NotebookEdit) field='.tool_input.new_source' ;;
  *) exit 0 ;;
esac

text="$(printf '%s' "$input" | jq -r "${field} // empty")"
[ -z "$text" ] && exit 0

violations=""

if printf '%s' "$text" | grep -qF '—'; then
  violations="${violations}em dash character: avoid this and similar constructs, use a colon, semicolon, parentheses, or two sentences instead; "
fi

# Name accuracy: the middle initial is required; always write out
# "David A. Wheeler" in full, never the shortened "David Wheeler".
if printf '%s' "$text" | grep -qF "David Wheeler"; then
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

matches="$(printf '%s' "$text" | grep -oiF -f <(printf '%s\n' "$phrase_list") | tr '[:upper:]' '[:lower:]' | sort -u || true)"
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

pattern_matches="$(printf '%s' "$text" | grep -oiE -f <(printf '%s\n' "$pattern_list") | tr '[:upper:]' '[:lower:]' | sort -u || true)"
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
dash_matches="$(printf '%s' "$text" | grep -vE '^[[:space:]]*[-*+][[:space:]]' \
    | grep -oiE '[[:alpha:]]{2,} (--|-) [[:alpha:]]{2,}' | tr '[:upper:]' '[:lower:]' | sort -u || true)"
if [ -n "$dash_matches" ]; then
  dash_list="$(printf '%s' "$dash_matches" | sed 's/^/"/;s/$/"; /' | tr -d '\n')"
  warn_msg="Heuristic flag (not a hard rule): found ${dash_list}each a word/hyphen(s)/word shape that's sometimes a disguised em dash. Double-check: if it's joining or breaking a clause the way an em dash would, rewrite it (colon, semicolon, parentheses, or two sentences). Known non-issues, ignore these: CLI/git end-of-options syntax (e.g. \"git diff -- path/to/file\"), a markdown list's \"term - description\" separator, and ordinary word ranges (\"Monday - Friday\")."
  jq -n --arg msg "$warn_msg" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow", systemMessage:$msg, additionalContext:$msg}}'
fi

exit 0
