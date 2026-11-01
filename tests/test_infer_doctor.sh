#!/bin/sh
# test_infer_doctor.sh: check infer-doctor.sh's awk programs on sample
# input: infer-doctor-flags.awk on a backend's command line, and
# infer-doctor-requests.awk on llama-server log lines (real ones, from
# llama.cpp b11669). infer-doctor.sh itself needs macOS. Run by ci.sh.
set -u

TESTS="$(cd "$(dirname "$0")" && pwd)"
fail=0
failed() {
  echo "FAIL: $1" >&2
  fail=1
}

got="$(printf '%s\n' '/opt/llama.cpp/b11669/llama-server --host 127.0.0.1 --port 8999 -ngl 99 -fa on --no-slots --cache-ram 0 --reasoning-budget-message "Consider it, then answer." --reasoning-budget -1 stray --jinja' |
  awk -f "$TESTS/../infer-doctor-flags.awk")"
want='program /opt/llama.cpp/b11669/llama-server
--host 127.0.0.1
--port 8999
-ngl 99
-fa on
--no-slots
--cache-ram 0
--reasoning-budget-message "Consider it, then answer."
--reasoning-budget -1
? stray
--jinja'
[ "$got" = "$want" ] || failed "infer-doctor-flags.awk gave:
$got"

# Two finished requests (one without drafting) and one under way, with
# the other lines llama-server writes around them.
log='0.00.051.709 I srv    load_model: loading model '"'"'/Users/Shared/models/Qwen3.8-27B-Q8_0.gguf'"'"'
649.00.000.001 I slot get_availabl: id  0 | task -1 | selected slot by LCP similarity, f_sim_best = 0.849 (> 0.100 thold), f_keep = 0.870
649.00.000.002 I slot launch_slot_: id  0 | task 98395 | processing task, is_child = 0
649.20.231.190 I slot print_timing: id  0 | task 98395 | prompt eval time =    5047.76 ms /   956 tokens (    5.28 ms per token,   189.39 tokens per second)
649.20.231.197 I slot print_timing: id  0 | task 98395 |        eval time =   16484.56 ms /   314 tokens (   52.67 ms per token,    18.99 tokens per second)
649.20.231.198 I slot print_timing: id  0 | task 98395 |       total time =   21532.32 ms /  1270 tokens
649.20.231.212 I slot print_timing: id  0 | task 98395 | draft acceptance = 0.52500 (  231 accepted /   440 generated), mean len =  3.89
649.20.231.300 I slot      release: id  0 | task 98395 | stop processing: n_tokens = 48992, truncated = 0
651.07.768.088 I slot print_timing: id  0 | task 98480 | prompt eval time =     767.15 ms /    59 tokens (   13.00 ms per token,    76.91 tokens per second)
651.07.768.090 I slot print_timing: id  0 | task 98480 |        eval time =  102369.14 ms /  1505 tokens (   68.06 ms per token,    14.69 tokens per second)
651.07.768.300 I slot      release: id  0 | task 98480 | stop processing: n_tokens = 50556, truncated = 0
652.00.000.002 I slot launch_slot_: id  0 | task 99041 | processing task, is_child = 0
652.10.000.000 I slot print_timing: id  0 | task 99041 | n_gen =    150, tg =   8.77 t/s, tg_3s =   8.66 t/s'
got="$(printf '%s\n' "$log" | awk -v last=3 -f "$TESTS/../infer-doctor-requests.awk")"
want='task      context   prompt  prompt/s   output  output/s  accept  mean
98395       48992      956     189.4      314      19.0     52%  3.89
98480       50556       59      76.9     1505      14.7       -     -
99041           -        -         -        -         -       -     -'
[ "$got" = "$want" ] || failed "infer-doctor-requests.awk gave:
$got"
got="$(printf '%s\n' "$log" | awk -v last=1 -f "$TESTS/../infer-doctor-requests.awk" | tail -n 1)"
[ "$got" = '99041           -        -         -        -         -       -     -' ] ||
  failed "infer-doctor-requests.awk with last=1 gave: $got"
got="$(printf 'no requests here\n' | awk -f "$TESTS/../infer-doctor-requests.awk")"
[ "$got" = "no requests in the log" ] || failed "infer-doctor-requests.awk with no requests gave: $got"

[ "$fail" -eq 0 ] && echo "infer-doctor: all checks passed."
exit "$fail"
