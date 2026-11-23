# Giving idle VM RAM back to a Mac (tried, removed)

In November 2026 the Mac swapped because VMs held RAM they weren't
using. Linux keeps file cache until something else needs the RAM, so an
idle VM still holds every page it has touched. We tried to fix that from
the guest, and it didn't work on a macOS host, so we removed it.

## What we tried

- A systemd timer in each VM that, when the VM was idle, evicted cold
  file cache with cgroup v2's `memory.reclaim` (with `swappiness=0`).
- A virtio balloon with free page reporting (UTM QEMU argument
  `-device virtio-balloon-pci,free-page-reporting=on`), so QEMU learns
  which guest pages are free and discards them.
- Booting the guest with `init_on_free=1`, so freed pages are zeros the
  Mac's compressor should store almost free.

## What we measured

On an 8 GB Ubuntu VM under UTM's QEMU on an Apple silicon Mac, with the
balloon's free page reporting negotiated and `init_on_free=1` on:
dropping 2.6 GiB of guest cache didn't shrink the QEMU process. Its
`phys_footprint` stayed at 11 GB, and its dirty resident memory didn't
drop, even under real memory pressure (`memory_pressure -l warn`).

## Why

QEMU's `ram_block_discard_range()` (`system/physmem.c`) discards
reported pages with `madvise(MADV_DONTNEED)`. On Linux that frees them;
macOS treats it as a hint, and keeps the pages and their accounting.
A fix would be for QEMU to use `MADV_FREE_REUSABLE` on macOS, as
browsers there do; that might be worth reporting upstream.

Whether `init_on_free`'s zero pages cost the Mac less real RAM can't be
seen per process: macOS counts a compressed page at full size in the
process's footprint, and the footprint is what drives its decisions.

Also beware: `footprint -p`'s headline counts only dirty resident
memory. Use the `phys_footprint` line (`footprint` prints it under
"Auxiliary data"), or `top`'s MEM column, which includes compressed
memory.

## What works on a Mac today

- Give each VM only the RAM it needs (UTM: Settings > System >
  Memory). A VM's worst case on the Mac is about its RAM size plus
  QEMU's overhead (about 3 GB more for the 8 GB VM above), so this caps
  it. A VM using 2.5 GiB for programs does fine with 4 GB; the guest
  just caches less.
- Let the guest's swap absorb the occasional shortfall. Its writes go
  to the VM's disk image, a file on the Mac, so (unless UTM turns off
  host caching for it) they land in the Mac's file cache, which is
  reclaimable and isn't charged to QEMU. If a VM swaps heavily all the
  time (`vmstat 5` in the guest), give it more RAM.
- Suspend VMs you aren't using (UTM's suspend, or
  `utmctl suspend NAME`), or restart a VM that's been idle a while;
  quitting QEMU returns all of its memory.

Don't add zram in the guest. It keeps compressed pages in guest RAM,
which QEMU can never return, and the Mac's compressor would retry
compressing them for little gain. Disk swap moves them into the Mac's
reclaimable file cache instead.
