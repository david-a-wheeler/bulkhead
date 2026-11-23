# git-config-entries.awk: print a repository's own git settings, one
# per line, for bulkhead-git-check. Input: the output of "git config
# --list --show-scope --includes -z" with each NUL changed to \001
# (POSIX awk can't take NUL as a separator). Records then alternate
# between a scope and an entry, "KEY\nVALUE" (or just "KEY" for a key
# with no value). We keep only the local and worktree scopes, which
# come from the repository (including files it includes), not from
# you. Output lines are "REPO<tab>config<tab>KEY=VALUE", where REPO is
# the -v repo value, in git's order, since order matters for some keys
# (e.g., an empty credential.helper resets the list).
#
# We escape backslashes and control characters in keys and values, so
# a value can't fake a line of its own or hide text with, e.g., a
# carriage return.
#
# We skip keys that can't run a command or send anything elsewhere, so
# they'd only bury the ones that can: branch.NAME.remote and
# branch.NAME.merge, which change with every branch you track and only
# name a remote (whose own settings we keep) and a ref, and the keys
# "git init" and "git clone" (including a partial clone) write in every
# repository. We keep remote.NAME.url, which says where a push goes.

BEGIN {
  RS = "\001"
  tab = sprintf("\t")
}

function escape(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/\n/, "\\n", s)
  gsub(/\t/, "\\t", s)
  gsub(/\r/, "\\r", s)
  gsub(/[\001-\037\177]/, "?", s)
  return s
}

NR % 2 == 1 {
  scope = $0
  next
}

scope == "local" || scope == "worktree" {
  i = index($0, "\n")
  if (i > 0) {
    key = substr($0, 1, i - 1)
    value = "=" substr($0, i + 1)
  } else {
    key = $0
    value = ""
  }
  if (key ~ /^branch\..*\.(remote|merge)$/ ||
      key ~ /^core\.(repositoryformatversion|filemode|bare|logallrefupdates|symlinks|ignorecase|precomposeunicode)$/ ||
      key ~ /^remote\..*\.(fetch|promisor|partialclonefilter)$/ ||
      key == "extensions.partialclone")
    next
  print repo tab "config" tab escape(key) escape(value)
}
