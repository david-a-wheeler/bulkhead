# infer-doctor-requests.awk: summarize the last few requests in
# llama-server's log (llama-swap's /logs/stream/upstream), one line
# each: its task number, the context it ended with, the prompt tokens
# it processed and how fast, the tokens it generated and how fast, and
# its draft acceptance and mean tokens per step, when it drafted. A
# request still under way shows only what's logged so far ("-" for the
# rest). infer-doctor.sh uses this; see tests/test_infer_doctor.sh.
#
# Usage: awk -v last=N -f infer-doctor-requests.awk   (default N: 5)

# task_seen TASK: remember TASK, in the order tasks first appear.
function task_seen(task) {
  if (!(task in seen)) {
    seen[task] = 1
    order[++tasks] = task
  }
}

# tokens_of LINE: the token count in "... = X ms / N tokens (...".
function tokens_of(line) {
  sub(/.*\/[ ]*/, "", line)
  return line + 0
}

# speed_of LINE: the speed in "..., R tokens per second)".
function speed_of(line) {
  if (!sub(/ tokens per second.*/, "", line))
    return ""
  sub(/.*,[ ]*/, "", line)
  return line + 0
}

# shown VALUE: VALUE, or "-" if there's none.
function shown(value) {
  return value == "" ? "-" : value
}

!match($0, /task [0-9]+/) { next }
{ t = substr($0, RSTART + 5, RLENGTH - 5); task_seen(t) }
/prompt eval time =/ {
  prompt_n[t] = tokens_of($0)
  prompt_speed[t] = sprintf("%.1f", speed_of($0))
  next
}
/\|[ ]+eval time =/ {
  gen_n[t] = tokens_of($0)
  gen_speed[t] = sprintf("%.1f", speed_of($0))
  next
}
/draft acceptance =/ {
  text = $0
  sub(/.*draft acceptance = /, "", text)
  accept[t] = sprintf("%.0f%%", 100 * text)
  text = $0
  sub(/.*mean len =[ ]*/, "", text)
  mean_len[t] = sprintf("%.2f", text)
  next
}
/stop processing: n_tokens = / {
  text = $0
  sub(/.*n_tokens = /, "", text)
  context[t] = text + 0
}

END {
  if (last == "")
    last = 5
  if (tasks == 0) {
    print "no requests in the log"
    exit
  }
  printf "%-8s %8s %8s %9s %8s %9s %7s %5s\n", "task", "context", "prompt", "prompt/s", "output", "output/s", "accept", "mean"
  first = tasks - last + 1
  if (first < 1)
    first = 1
  for (i = first; i <= tasks; i++) {
    t = order[i]
    printf "%-8s %8s %8s %9s %8s %9s %7s %5s\n", t, shown(context[t]), shown(prompt_n[t]),
      shown(prompt_speed[t]), shown(gen_n[t]), shown(gen_speed[t]), shown(accept[t]), shown(mean_len[t])
  }
}
