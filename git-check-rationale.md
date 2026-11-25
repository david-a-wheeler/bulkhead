# What bulkhead-git-check asks about, and why

`bulkhead-git-check` notices every change to the settings a
workspace's git repositories give git, but it shows you, and asks you
to approve, only the risky ones. Too many questions train you to say
yes without reading, and a change that isn't risky gives you nothing
to act on, only something to worry about. So we speak up only where a
change can hurt you without your noticing. This file
records where we drew that line and why; `git-config-risks` holds the
line itself, as data.

## What we ask about

We ask about a change that can:

1. run a program without your spelling it out (e.g., a filter that
   runs on a plain `git checkout`), or
2. change where, or how, a plain `git push` delivers your work.

Anything you have to spell out (e.g., `git push NAME` or `git
submodule update`) you'll notice anyway, so a change that only affects
that is recorded without a word.

The checks run outside every sandbox, as do your own git commands, so
compartment restrictions don't help here: a planted setting runs with
your full access.

## What asks

- **Programs git runs on its own:** filter drivers, diff and merge
  drivers' commands, `diff.external`, `core.fsmonitor`, `hookspath`,
  `sshcommand`, `gitproxy`, `pager`, `editor`, `askpass`, and
  `alternaterefscommand`, `pager.*`, `sequence.editor`,
  `remote.*.uploadpack`, `receivepack`, and `vcs`, `credential.*` (its
  helper runs on a plain push), and `gpg.*` (runs on a plain commit
  when signing is on).
- **`alias.*`:** a repository's alias overrides yours of the same name,
  so the `git st` you type by habit could run something else.
- **Where a plain push goes (`push-to`):** for each branch, the URL a
  plain `git push` uses, after `pushurl` and `pushInsteadOf`. We record
  that instead of the keys that pick it (`branch.*`,
  `remote.pushdefault`, and `remote.NAME.url`), so adding a remote you
  never push to by default doesn't ask, but pointing a branch (or
  `origin`) somewhere new does.
- **`remote.*.push` and `remote.*.mirror`:** `push-to` records only the
  URL, but a refspec can land your `main` on a different branch (e.g.,
  one that triggers a deploy), and a mirror push deletes the remote's
  other branches. They're rare, so asking adds little noise.
- **`lfs.*`:** `lfs.url` sends your LFS objects elsewhere, and custom
  transfer agents run programs.
- **`http.*proxy*`, `http.*ssl*`, and `remote.*.proxy`:** they don't
  change the destination, but they can let someone read or redirect
  your push on the way. They're rare.
- **`submodule.*.update`:** one starting with `!` runs a command, and
  with `submodule.recurse` set that happens on a plain pull or checkout.
- **`error`:** if git can't read a repository, we can't tell whether
  anything above applies.

## What's recorded without a word

- **Hooks:** `git-hook-passthrough` already refuses to run a hook until
  you approve its hash. One gate is enough; a second only trains you to
  say yes.
- **New repositories, `git-dir`, and `common-dir`:** a planted `.git`
  file or `.git/commondir` redirects where git reads config and hooks,
  but we list and judge what it points to, so the redirect itself
  needn't ask.
- **`url.*`:** `push-to` already shows its effect on a plain push; its
  effect on fetch and clone doesn't meet either test.
- **`include.*` and `includeif.*`:** we list and judge the included
  settings themselves.
- **Fetch destinations:** an agent can already write your working
  tree, so redirecting a fetch gains it little.
- **Everything else** (other `core.*`, `remote.*`, and `submodule.*`
  keys, and keys we don't know). A new git version could add a key that runs a program; when
  you learn of one, add it to `git-config-risks`.

## What isn't even recorded

Repositories below a directory named `.tmp` aren't searched for at
all. That's where a compartment puts its `/tmp`, so tools (and our own
tests) leave scratch repositories there, often with risky settings.
To run git in one, you'd have to go into it on purpose, so they'd only
bury a warning that matters.

Some keys change often for harmless reasons, so `git-config-entries.awk`
skips them:
the keys `git init` and `git clone` write in every repository (e.g.,
`core.filemode` and `remote.NAME.fetch`), and the keys `push-to`
replaces (`branch.*`, `remote.pushdefault`, and `remote.NAME.url` and
`pushurl`).

Removing a setting is never shown: removal can't add a program to run
or a new destination, and anything it uncovers shows up as an addition.
