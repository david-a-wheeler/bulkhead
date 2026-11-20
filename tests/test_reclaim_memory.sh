#!/bin/sh
# test_reclaim_memory.sh: check when bulkhead-reclaim-memory reclaims,
# how much it asks for, and what --check reports. It runs against a fake
# /proc and /sys (BULKHEAD_RECLAIM_ROOT). Run by ci.sh.
set -eu

TESTS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS/.." && pwd)"
mkdir -p "$REPO/.tmp"
work="$(mktemp -d "$REPO/.tmp/test-reclaim-memory.XXXXXX")"
trap 'rm -rf "${work:?}"' EXIT
fail=0
failed() {
  echo "FAIL: $1" >&2
  fail=1
}

# setup BALLOON_FEATURES LOAD ACTIVE_KB INACTIVE_KB: build a fake root;
# BALLOON_FEATURES "none" means no balloon device.
setup() {
  rm -rf "$work/root"
  mkdir -p "$work/root/proc" "$work/root/sys/fs/cgroup" "$work/root/sys/bus/virtio/devices/virtio0"
  printf '0x0001\n' > "$work/root/sys/bus/virtio/devices/virtio0/device"
  printf '0000011111\n' > "$work/root/sys/bus/virtio/devices/virtio0/features"
  if [ "$1" != none ]; then
    mkdir -p "$work/root/sys/bus/virtio/devices/virtio1"
    printf '0x0005\n' > "$work/root/sys/bus/virtio/devices/virtio1/device"
    printf '%s\n' "$1" > "$work/root/sys/bus/virtio/devices/virtio1/features"
  fi
  printf '%s 0.5 0.5 1/100 1234\n' "$2" > "$work/root/proc/loadavg"
  cat > "$work/root/proc/meminfo" <<EOF
MemTotal:        8000000 kB
MemFree:          500000 kB
Active(file):     $3 kB
Inactive(file):   $4 kB
EOF
  : > "$work/root/sys/fs/cgroup/memory.reclaim"
}
run() {
  BULKHEAD_RECLAIM_ROOT="$work/root" "$REPO/bulkhead-reclaim-memory" "$@"
}
reclaimed() {
  cat "$work/root/sys/fs/cgroup/memory.reclaim"
}

# Bit 5 (6th character) is free page reporting.
with=0011010000 without=0011100000

setup "$with" 0.2 1000000 2048576
run 1024 1 > /dev/null || failed "reclaim run exit status"
[ "$(reclaimed)" = "2000000K swappiness=0" ] ||
  failed "reclaim amount: $(reclaimed)"

# Recently reused (active) cache stays, even beyond KEEP_MB.
setup "$with" 0.2 3000000 500000
run 1024 1 > /dev/null || failed "capped run exit status"
[ "$(reclaimed)" = "500000K swappiness=0" ] ||
  failed "reclaim capped at inactive: $(reclaimed)"

setup "$with" 1.5 1000000 2048576
run 1024 1 || failed "busy run exit status"
[ -z "$(reclaimed)" ] || failed "reclaimed while busy"

setup "$with" 0.2 500000 600000
run 1024 1 || failed "small run exit status"
[ -z "$(reclaimed)" ] || failed "reclaimed under 64 MB"

setup "$without" 0.2 1000000 2048576
run 1024 1 || failed "no-reporting run exit status"
[ -z "$(reclaimed)" ] || failed "reclaimed without free page reporting"

setup "$with" 0.2 1 1
run --check || failed "--check with reporting"
setup "$without" 0.2 1 1
out="$(run --check)" && failed "--check passed without reporting"
case "$out" in *"without free page reporting"*) ;; *) failed "--check message: $out" ;; esac
setup none 0.2 1 1
out="$(run --check)" && failed "--check passed without a balloon"
case "$out" in *"no virtio balloon"*) ;; *) failed "--check message: $out" ;; esac

run 1x 1 2> /dev/null && failed "accepted a bad KEEP_MB"
run 2> /dev/null && failed "accepted no arguments"

exit "$fail"
