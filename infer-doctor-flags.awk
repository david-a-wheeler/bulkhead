# infer-doctor-flags.awk: print a backend's command line, as llama-swap's
# /running reports it, one option per line with its value, if any:
# "program PATH", then e.g. "--ctx-size 262144" or "--no-slots". A
# double-quoted value stays one value. A word that doesn't follow an
# option is printed after "?". infer-doctor.sh uses this; see
# tests/test_infer_doctor.sh.
#
# Usage: awk -f infer-doctor-flags.awk   (one command line per input line)

# is_option WORD: true if WORD is an option, e.g., -c or --ctx-size, but
# not a value such as -1.
function is_option(word) {
  return word ~ /^--?[A-Za-z]/
}

{
  n = 0
  rest = $0
  while (1) {
    sub(/^[ \t]+/, "", rest)
    if (rest == "")
      break
    if (substr(rest, 1, 1) == "\"") {
      rest = substr(rest, 2)
      end = index(rest, "\"")
      if (end == 0)
        end = length(rest) + 1
      words[++n] = "\"" substr(rest, 1, end - 1) "\""
      rest = substr(rest, end + 1)
    } else {
      end = index(rest, " ")
      if (end == 0)
        end = length(rest) + 1
      words[++n] = substr(rest, 1, end - 1)
      rest = substr(rest, end)
    }
  }
  if (n == 0)
    next
  print "program " words[1]
  for (i = 2; i <= n; i++) {
    if (!is_option(words[i]))
      print "? " words[i]
    else if (i < n && !is_option(words[i + 1])) {
      print words[i] " " words[i + 1]
      i++
    } else
      print words[i]
  }
}
