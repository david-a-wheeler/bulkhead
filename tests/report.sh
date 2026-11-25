# tests/report.sh: how every test script ends, so a failure is loud and
# a full pass is plainly marked. Source it, then:
#   report_begin NAME REPO     at the start; also sets TMPDIR (below)
#   report_on_exit             first thing in the script's EXIT trap
#   report_track PATH...       for scratch files outside TMPDIR
#   report_clean PATH...       then, in the trap, for its scratch files
#   report_end FAILED [TOTAL]  at the end; its status is the script's
# A script that set -e stops early (status not 0) gets a loud banner
# too, so an unexpected error can't pass for a clean run.

report_name=test
report_done=false
report_status=0

# report_begin NAME REPO: name the test, and point TMPDIR (so every
# mktemp, and every tool that honors TMPDIR) at a new directory that no
# agent can change while we use it. Outside a sandbox, it's in REPO's
# dossier (scratch/), outside the workspace, where agents can't write.
# Inside one (a compartment or nono), the dossier isn't writable, so
# it's in the TMPDIR we have; with no dossier (e.g., GitHub's CI), the
# system's temporary directory. A test that another runs (e.g., ci.sh)
# shares the outer test's directory; the one that made it removes it
# after a pass (see report_clean).
report_own_tmpdir=""
report_begin() {
  report_name="$1"
  [ -z "${BULKHEAD_TEST_TMPDIR:-}" ] || return 0
  report_base="${TMPDIR:-/tmp}"
  if [ -z "${BULKHEAD_COMPARTMENT:-}${NONO_CAP_FILE:-}" ] &&
    report_dossier="$(cd "$2" && ./bulkhead-workspace dossier 2> /dev/null)" &&
    [ -d "$report_dossier" ] && mkdir -p "$report_dossier/scratch"; then
    report_base="$report_dossier/scratch"
  fi
  report_own_tmpdir="$(mktemp -d "$report_base/$1.XXXXXX")"
  # While we run, we hold this lock (on fd 8, which children inherit),
  # so a pass elsewhere won't remove our files (see report_sweep).
  if command -v flock > /dev/null 2>&1; then
    exec 8> "$report_own_tmpdir/.report-lock"
    flock -n 8 || true
  fi
  BULKHEAD_TEST_TMPDIR="$report_own_tmpdir"
  TMPDIR="$report_own_tmpdir"
  export BULKHEAD_TEST_TMPDIR TMPDIR
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

# report_track PATH...: note scratch directories (made by mktemp)
# outside the TMPDIR report_begin made, so that if this run fails or
# stops, a later pass can remove them too.
report_tracked=""
report_track() {
  [ -n "$report_own_tmpdir" ] || return 0
  for report_path in "$@"; do
    printf '%s\n' "$report_path" >> "$report_own_tmpdir/.report-paths"
    report_tracked="$report_tracked$report_path
"
  done
}

# report_sweep: quietly remove what earlier runs of this test kept
# (their TMPDIRs, and the paths they tracked), except any still running
# (holding its lock). A TMPDIR from before the locks has none, so we
# leave it alone if it changed in the last 10 minutes. We only remove a
# tracked path that looks like one this run tracked (the same mktemp
# template), so a planted list can't send us elsewhere.
report_sweep() {
  [ -n "$report_own_tmpdir" ] && command -v flock > /dev/null 2>&1 || return 0
  for report_old in "${report_own_tmpdir%.*}".*; do
    [ -d "$report_old" ] && [ ! -L "$report_old" ] || continue
    if [ -f "$report_old/.report-lock" ] && [ ! -L "$report_old/.report-lock" ]; then
      flock -n "$report_old/.report-lock" true 2> /dev/null || continue
    elif [ -n "$(find "$report_old" -prune -mmin -10)" ]; then
      continue
    fi
    if [ -f "$report_old/.report-paths" ] && [ ! -L "$report_old/.report-paths" ]; then
      while IFS= read -r report_path; do
        case "${report_path##*.}" in "" | */*) continue ;; esac
        printf '%s' "$report_tracked" | while IFS= read -r report_mine; do
          if [ "${report_path%.*}" = "${report_mine%.*}" ] && [ -d "$report_path" ] && [ ! -L "$report_path" ]; then
            rm -rf "$report_path"
          fi
        done
      done < "$report_old/.report-paths"
    fi
    rm -rf "$report_old"
  done
}

# report_clean [PATH...]: after a pass, remove each PATH (and the TMPDIR
# report_begin made), and what earlier failed or stopped runs kept;
# after a failure (or a stop partway through), keep them for you to
# examine, and say so.
report_clean() {
  set -- "$@" ${report_own_tmpdir:+"$report_own_tmpdir"}
  if [ "$report_status" -eq 0 ]; then
    rm -rf "$@"
    report_sweep
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
