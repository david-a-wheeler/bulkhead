# manage-models-set-default.awk: prints a models list with one model as
# the only one with metadata.default: true, adding that model's metadata
# section if needed. manage-models.sh's set_default runs it as:
#   awk -v n=NAME -f manage-models-set-default.awk FILE
# It's plain POSIX awk, so macOS's awk runs it.

function end_entry() {
  if (model == n && !done) {
    print "    metadata:"
    print "      default: true"
    done = 1
  }
}
/^[^ #]|^  [^ #]/ {
  end_entry()
  model = ""
  if (/^  /) { model = $0; gsub(/^  "?|"?:$/, "", model) }
}
/^    [^ #]/ { section = $1; sub(/:.*/, "", section) }
section == "metadata" && /^      default: true *$/ { next }
{ print }
model == n && /^    metadata:$/ && !done {
  print "      default: true"
  done = 1
}
END { end_entry() }
