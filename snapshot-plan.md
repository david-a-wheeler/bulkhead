# Snapshots: undoing an agent's damage

Status (2026-11-24): built (`bulkhead-snapshot`), but not yet used day
to day. `compartments.md`, "Snapshots", documents it; once it's proven,
this moves to `archive/`.

## Goal

Reduce data loss when an agent damages its workspace (by mistake or on
purpose). It doesn't need to be perfect. The agent mustn't be able to
change or delete the snapshots, so they live in the workspace's
dossier, and only code outside the sandbox writes them.

## What we save

- Only the files the workspace's git repository tracks, as they are in
  the working tree (not as committed), with no history. A submodule or
  a nested repository is skipped.
- Only the repository at the workspace's top; a workspace without one
  gets no snapshots.
- Each snapshot also records the repository's refs (`git
  for-each-ref`), so you can bring back a deleted or moved branch while
  its commit still exists. We don't save commits or the rest of
  `.git`: `bulkhead-git-check` already watches its config and hooks
  (see `compartments.md`, "Git runs commands from local files"), and
  most commits you care about are pushed.

## When

At launch, by `compart`, after `bulkhead-git-check`, before the agent
starts. That's the state you want back, it includes your own edits
between sessions, and unlike a snapshot at exit, it can't be skipped by
a crash. If a snapshot fails, the session doesn't start.

## How it's stored

A bare git repository at the dossier's `snapshots/`, separate from the
workspace's `.git` (which the agent can write). Each snapshot is a
root commit under `refs/snapshots/`. Measured on the human's machine,
one snapshot of every workspace is about 145 MiB packed (175 MiB
raw); later ones add only changed files.

To limit space and SSD wear:

- Skip the snapshot if nothing changed. A cache in the store of each
  file's inode, size, and change times (ctime can't be set by the
  agent) avoids even reading unchanged files.
- Write objects only by `git fast-import`, which writes one pack and
  skips objects the store already has. No loose objects.
- After each snapshot, `git repack --geometric=2 -d` merges only the
  small packs. A full repack, which drops pruned data, runs at most
  once a week, and only after pruning.

`git fast-import` stores the bytes we give it, so no repository's
filters, attributes, or config apply. The store's git runs without
your global and system config.

## Retention

Always keep the newest 3 snapshots, whatever their age; prune others
once they're more than 30 days old.

## Commands

`bulkhead-snapshot take|list|diff|restore|refs`:

- `list`: snapshots, newest first.
- `diff [SNAPSHOT] [PATH...]`: what changed since a snapshot (default
  the newest), plus tracked files the snapshot lacks.
- `restore [SNAPSHOT] [PATH...]`: put back the snapshot's files (all,
  or only those under PATHs). It first takes a snapshot of the current
  state, so a restore can be undone. It refuses while a session runs
  in the workspace (`compart` holds a shared lock for each session),
  and refuses to write below a symlinked directory. It doesn't delete
  files the snapshot lacks; `diff` lists them.
- `refs [SNAPSHOT]`: the refs it recorded.

## Not covered

- Untracked files, including new files an agent never added to git.
- History: commits that were never pushed and were garbage-collected.
- Damage within one session before you notice, since the newest
  snapshot is from its start; and damage older than what retention
  keeps.
- Paths below a symlinked directory, and file types other than
  regular files and symlinks.
