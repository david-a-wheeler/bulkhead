#!/usr/bin/env bash
# Self-test for check-prose-style.sh: feeds it sample hook inputs and
# checks that it allows or denies each one. Run it from a directory
# containing ,check-prose-style.sh (a working copy being changed) or,
# failing that, check-prose-style.sh.
#
# Usage: ./test-check-prose-style.sh
# Exits 0 if all tests pass, 1 if any fail, 2 if there's no hook to test.
#
# Curly quotes and apostrophes in this file are test data, not mistyped
# shell quotes.
# shellcheck disable=SC1111,SC1112

set -u

# The hook must set its own locale, so test it under plain C.
export LC_ALL=C

hook=./,check-prose-style.sh
[ -e "$hook" ] || hook=./check-prose-style.sh
if [ ! -e "$hook" ]; then
  echo "test-check-prose-style: no ,check-prose-style.sh or check-prose-style.sh here" >&2
  exit 2
fi
echo "Testing $hook"

em="$(printf '\342\200\224')"
fail=0
count=0

# check NAME WANT JSON: run the hook on JSON, and check that it exits 0
# and decides WANT ("allow" or "deny").
check() {
  local out status got
  count=$((count + 1))
  out="$("$hook" <<< "$3" 2>/dev/null)"
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "FAIL: $1: hook exited $status"
    fail=1
    return
  fi
  got="$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$out")"
  got="${got:-allow}"
  if [ "$got" != "$2" ]; then
    echo "FAIL: $1: wanted $2, got $got"
    fail=1
  fi
}

# write NAME WANT CONTENT, and edit NAME WANT OLD NEW: check a Write or
# an Edit.
write() {
  check "$1" "$2" "$(printf '%s' "$3" | jq -Rs \
    '{tool_name:"Write",tool_input:{file_path:"x.md",content:.}}')"
}
edit() {
  check "$1" "$2" "$(jq -n --arg o "$3" --arg n "$4" \
    '{tool_name:"Edit",tool_input:{file_path:"x.md",old_string:$o,new_string:$n}}')"
}

# Basic checks.
write "clean text" allow 'Nothing wrong here.'
write "banned word" deny 'We leverage this.'
write "em dash" deny "This is bad ${em} really."
write "incomplete name" deny 'By David Wheeler.'
write "incomplete name, other case" deny 'By DAVID WHEELER.'
write "full name" allow 'By David A. Wheeler.'
write "pattern" deny 'It plays a pivotal role here.'
write "pattern, straight apostrophes" deny "It's not just fast, it's cheap."
write "pattern, curly apostrophes" deny 'It’s not just fast, it’s cheap.'
write "hyphen heuristic only warns" allow 'This works - mostly.'

# Text in curly double quotes (someone else's words) is ignored.
write "quoted banned word" allow 'Rohlf says “we are leveraging tools.” [R].'
write "quoted em dash" allow "It says “code${em}in particular” [A]."
write "quote fragment at line start" allow 'leveraging tooling.” [Rohlf2025].'
write "quote fragment at line end" allow 'As Rohlf said, “we are leveraging'
write "scare quotes are ignored too" allow 'A “seamless” approach.'
write "banned word after a quote" deny 'He said “hi” and we leverage it.'
write "banned word on next line" deny $'“quoted line”\nwe leverage this.'

# An Edit is only blocked for text it adds, not text it keeps.
edit "Edit keeps existing word" allow 'Mythos showcased it.' 'Mythos showcased it again.'
edit "Edit adds another copy" deny 'Mythos showcased it.' 'Mythos showcased it; a showcase.'
edit "Edit keeps em dash" allow "a${em}b" "a${em}b, c"
edit "Edit adds em dash" deny "a${em}b" "a${em}b${em}c"
edit "Edit unquotes a quoted word" deny 'He said “we leverage”.' 'We leverage it.'
edit "Edit changes only case" allow 'Leverage it.' 'leverage it.'
edit "Edit removes banned word" allow 'We leverage it.' 'We use it.'

# Other tools and inputs.
check "Bash tool is ignored" allow '{"tool_name":"Bash","tool_input":{"command":"leverage"}}'
check "NotebookEdit is checked" deny '{"tool_name":"NotebookEdit","tool_input":{"new_source":"leverage"}}'
big="$(printf 'early %s dash\n' "$em"; yes 'a line of plain text' | head -n 30000)"
write "large input, early em dash" deny "$big"

# Input text must never run as code.
dir="$(mktemp -d)"
edit "shell metacharacters" allow "\$(touch $dir/a) \`touch $dir/b\` ';" "\$(touch $dir/c)'\"\\"
count=$((count + 1))
if [ -n "$(ls -A "$dir")" ]; then
  echo "FAIL: input text ran as a command"
  fail=1
fi
rm -rf "$dir"

# Control characters are removed from messages.
count=$((count + 1))
msg="$("$hook" <<< "$(jq -n --arg c "$(printf 'It’s not just \033[31mred\007, it’s bad.')" \
  '{tool_name:"Write",tool_input:{content:$c}}')" \
  | jq -r '.hookSpecificOutput.permissionDecisionReason')"
case "$msg" in
  *[[:cntrl:]]*) echo "FAIL: message contains control characters"; fail=1 ;;
esac

# Bad JSON makes the hook exit nonzero (a visible error, not a silent pass).
count=$((count + 1))
if "$hook" <<< 'not json' >/dev/null 2>&1; then
  echo "FAIL: bad JSON didn't make the hook exit nonzero"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "All $count tests passed."
else
  echo "Some of $count tests FAILED." >&2
  exit 1
fi
