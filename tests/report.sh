# tests/report.sh: how every test script ends, so a failure is loud and
# a full pass is plainly marked. Source it, then:
#   report_begin NAME          at the start
#   report_on_exit             first thing in the script's EXIT trap
#   report_end FAILED [TOTAL]  at the end; its status is the script's
# A script that set -e stops early (status not 0) gets a loud banner
# too, so an unexpected error can't pass for a clean run.

report_name=test
report_done=false

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

report_on_exit() {
  report_status=$?
  if ! "$report_done" && [ "$report_status" -ne 0 ]; then
    report_banner "FAILED: $report_name stopped early (status $report_status), after the checks above."
  fi
  return "$report_status"
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
