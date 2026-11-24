#!/bin/sh
# test_speechd_piper.sh: check how speechd-piper turns
# speech-dispatcher's rate and volume into Piper's settings, passes the
# text on stdin, and refuses bad arguments. It runs a copy in a Piper
# layout with stand-ins for piper and aplay that record what they get.
# Run by ci.sh.
set -eu
# shellcheck source=SCRIPTDIR/report.sh
. "$(dirname "$0")/report.sh"
report_begin test_speechd_piper.sh

TESTS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS/.." && pwd)"
mkdir -p "$REPO/.tmp"
work="$(mktemp -d "$REPO/.tmp/test-speechd-piper.XXXXXX")"
trap 'report_on_exit; report_clean "${work:?}"' EXIT
fail=0
failed() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

home=$work/piper
mkdir -p "$home/bin" "$home/venv/bin" "$home/voices" "$work/path"
cp "$REPO/speechd-piper" "$home/bin/"
printf 'model\n' > "$home/voices/en_US-test-medium.onnx"
printf '{"audio": {"sample_rate": 16000}}\n' > "$home/voices/en_US-test-medium.onnx.json"
cat > "$home/venv/bin/piper" <<EOF
#!/bin/sh
echo "\$*" > "$work/piper-args"
cat > "$work/piper-text"
printf 'audio'
EOF
cat > "$work/path/aplay" <<EOF
#!/bin/sh
echo "\$*" > "$work/aplay-args"
cat > "$work/aplay-audio"
EOF
chmod +x "$home/venv/bin/piper" "$work/path/aplay"

# speak RATE VOLUME: run it on "Hello, it's me." and print piper's args.
speak() {
  rm -f "$work/piper-args"
  echo "Hello, it's me." | PATH="$work/path:$PATH" \
    "$home/bin/speechd-piper" en_US-test-medium "$1" "$2"
  sed "s|$home|HOME|" "$work/piper-args"
}

check() {
  got=$(speak "$1" "$2")
  [ "$got" = "--model HOME/voices/en_US-test-medium.onnx --length-scale $3 --volume $4 --output-raw" ] ||
    failed "rate $1, volume $2 gave: $got"
}
check 0 100 1.000 1.000
check 100 100 0.500 1.000
check -100 0 2.000 0.500
check 50 -100 0.707 0.000
check 900 -900 0.500 0.000

speak 0 100 > /dev/null
[ "$(cat "$work/piper-text")" = "Hello, it's me." ] || failed "piper got text: $(cat "$work/piper-text")"
[ "$(cat "$work/aplay-args")" = "-q -r 16000 -f S16_LE -c 1 -t raw -" ] ||
  failed "aplay got: $(cat "$work/aplay-args")"
[ "$(cat "$work/aplay-audio")" = "audio" ] || failed "aplay didn't get piper's audio"

# refused ARGS...: speechd-piper must fail, without running piper.
refused() {
  rm -f "$work/piper-args"
  if echo hi | PATH="$work/path:$PATH" "$home/bin/speechd-piper" "$@" 2>/dev/null ||
      [ -e "$work/piper-args" ]; then
    failed "accepted: $*"
  fi
}
refused ../voices/en_US-test-medium 0 100
refused "en_US test" 0 100
refused "" 0 100
refused en_US-missing-medium 0 100
refused en_US-test-medium 1-2 100
refused en_US-test-medium - 100
refused en_US-test-medium 0 1.5
# shellcheck disable=SC2016 # a literal $(id), as text from a client
refused en_US-test-medium 0 '$(id)'
refused en_US-test-medium 0
refused en_US-test-medium 0 100 extra

report_end "$fail"
