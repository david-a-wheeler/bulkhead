# tests/report.sh: how every test script ends, so a failure is loud and
# a full pass is plainly marked. Source it, then:
#   report_begin NAME          at the start
#   report_on_exit             first thing in the script's EXIT trap
#   report_clean PATH...       then, in the trap, for its scratch files
#   report_end FAILED [TOTAL]  at the end; its status is the script's
# A script that set -e stops early (status not 0) gets a loud banner
# too, so an unexpected error can't pass for a clean run.

report_name=test
report_done=false
report_status=0

report_begin() {
  report_name="$1"
}

# report_banner LINE: LINE between rules, on stderr.
report_banner() {
  {
    echo "########################################################################"
    echo "$1"
    echo "########################################################################"
  } >&2
}

# It returns 0, so under set -e the rest of the trap (e.g.,
# report_clean) still runs; the script still exits with its own status,
# since the trap doesn't call exit.
report_on_exit() {
  report_status=$?
  if ! "$report_done" && [ "$report_status" -ne 0 ]; then
    report_banner "FAILED: $report_name stopped early (status $report_status), after the checks above."
  fi
  return 0
}

# report_clean PATH...: after a pass, remove each PATH; after a failure
# (or a stop partway through), keep them for you to examine, and say so.
report_clean() {
  if [ "$report_status" -eq 0 ]; then
    rm -rf "$@"
  else
    for report_path in "$@"; do
      [ ! -e "$report_path" ] || echo "Kept $report_path for you to examine; delete it when you're done." >&2
    done
  fi
}

report_end() {
  report_done=true
  if [ "$1" -eq 0 ]; then
    if [ -n "${2:-}" ]; then
      echo "PASSED: $report_name: all $2 checks passed."
    else
      echo "PASSED: $report_name: every check passed."
    fi
    return 0
  fi
  report_banner "FAILED: $report_name: $1 ${2:+of $2 }checks failed (see the FAIL lines above)."
  return 1
}
