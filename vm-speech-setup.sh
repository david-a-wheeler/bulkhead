#!/bin/sh
# vm-speech-setup.sh: make Piper (from vm-piper-install.sh) your
# speech-dispatcher default, so spd-say, and everything else that uses
# speech-dispatcher, speaks with config.sh's first PIPER_VOICES voice.
# espeak-ng stays available (spd-say -o espeak-ng). vm-setup.sh runs it
# after vm-piper-install.sh. Safe to re-run: it rewrites a file only
# when its content changes, and restarts speech-dispatcher only then.
#
# Usage: vm-speech-setup.sh [--say]
#   --say   also speak a test sentence aloud (turn up the VM's volume)
# It also checks, silently, that text with quotes, $(...), and
# backticks can't run commands through the module's shell command,
# whenever that could have changed since it last passed.
#
# It writes ~/.config/speech-dispatcher/modules/piper.conf and a
# bulkhead block in ~/.config/speech-dispatcher/speechd.conf (copying
# the system one there first if you don't have your own, since yours
# replaces it). speech-dispatcher runs as a systemd user service started
# by its socket, outside any nono sandbox; agents under nono reach that
# socket through nono-default-profile.json's grant. Under nono, spd-say
# works but spd-say -w (wait until spoken) doesn't: it needs a semaphore
# in /dev/shm, which nono rightly denies. To add another
# output module later (e.g., the Mac's AI voices), write its .conf here
# and add its AddModule line to the block below.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"
: "${TMPDIR:=$SCRIPT_DIR/.tmp}"
export TMPDIR
mkdir -p "$TMPDIR"

say=false
case ${1:-} in
  "") ;;
  --say) say=true ;;
  *) die "usage: vm-speech-setup.sh [--say]" ;;
esac

piper_home=$HOME/.local/share/piper
conf=$HOME/.config/speech-dispatcher
[ -x "$piper_home/bin/speechd-piper" ] || die "no Piper; run vm-piper-install.sh first."
command -v spd-say >/dev/null || die "no spd-say; install speech-dispatcher."

# install_if_changed NEW DEST: move NEW to DEST unless they're the same.
changed=false
install_if_changed() {
  if cmp -s "$1" "$2"; then
    rm -f "$1"
  else
    mv "$1" "$2"
    changed=true
  fi
}

# The module: one AddVoice per installed PIPER_VOICES voice. Rate and
# volume pass through unchanged (Multiply 100 means 1.0, since these
# settings are in hundredths); speechd-piper converts them.
mkdir -p "$conf/modules"
new=$TMPDIR/piper.conf.new
{
  echo "# Written by bulkhead's vm-speech-setup.sh from config.sh's PIPER_VOICES;"
  echo "# change those and re-run it, rather than editing this."
  echo "Debug 0"
  # speech-dispatcher fills in $DATA, $VOICE, $RATE, and $VOLUME, and
  # wants the quotes around $DATA and $VOICE written as \'.
  printf '%s\n' "GenericExecuteSynth \"printf %s \\'\$DATA\\' | $piper_home/bin/speechd-piper \\'\$VOICE\\' \$RATE \$VOLUME\""
  echo "GenericRateAdd 0"
  echo "GenericRateMultiply 100"
  echo "GenericRateForceInteger 1"
  echo "GenericVolumeAdd 0"
  echo "GenericVolumeMultiply 100"
  echo "GenericVolumeForceInteger 1"
  echo "GenericDefaultCharset \"utf-8\""
  printf '%s\n' "$PIPER_VOICES" | while read -r name type _; do
    [ -n "$name" ] && [ -s "$piper_home/voices/$name.onnx.json" ] || continue
    locale=${name%%-*}
    echo "GenericLanguage \"${locale%%_*}\" \"$locale\" \"utf-8\""
    echo "AddVoice \"${locale%%_*}\" \"$type\" \"$name\""
  done | awk '!seen[$0]++'
} > "$new"
grep -q '^AddVoice' "$new" || die "no PIPER_VOICES voice is installed; run vm-piper-install.sh."
install_if_changed "$new" "$conf/modules/piper.conf"

# speechd.conf: start from the system's, drop the block an older,
# temporary script (,setup-spd-piper.sh) added, and add ours.
default_type=$(printf '%s\n' "$PIPER_VOICES" | awk 'NF { print $2; exit }')
if [ ! -f "$conf/speechd.conf" ]; then
  cp /etc/speech-dispatcher/speechd.conf "$conf/speechd.conf"
  cp -R /etc/speech-dispatcher/clients "$conf/"
  changed=true
fi
new=$TMPDIR/speechd.conf.new
awk '$0 == "# BEGIN ,setup-spd-piper.sh" { skip = 1 } !skip { print }
  $0 == "# END ,setup-spd-piper.sh" { skip = 0 }' "$conf/speechd.conf" > "$new"
block=$TMPDIR/speechd.conf.block
# Listing any AddModule stops speech-dispatcher from loading every
# installed module, so this lists each one to keep.
cat > "$block" <<EOF
AddModule "piper" "sd_generic" "piper.conf"
AddModule "espeak-ng" "sd_espeak-ng" "espeak-ng.conf"
DefaultModule piper
DefaultVoiceType "$default_type"
EOF
install_managed_block "$block" "$new"
rm -f "$block"
install_if_changed "$new" "$conf/speechd.conf"

systemctl --user is-enabled --quiet speech-dispatcher.socket ||
  systemctl --user enable speech-dispatcher.socket
systemctl --user is-active --quiet speech-dispatcher.socket ||
  systemctl --user start speech-dispatcher.socket
if $changed; then
  # Restart it if it's running; if not, it starts with the new settings
  # on the next request.
  systemctl --user try-restart speech-dispatcher.service
  echo "Updated speech-dispatcher's settings."
else
  echo "speech-dispatcher's settings are up to date."
fi

# Silently (volume -100) speak text that would run a command if the
# module's shell command didn't quote it right. It waits until the
# speech is done, which takes a while, so we skip it when nothing it
# depends on (the module's settings, speechd-piper, and
# speech-dispatcher's version) changed since it last passed. The
# marker's path is short since it's spoken too.
stamp_file=$HOME/.local/state/bulkhead/spd-quoting-test
# Without dpkg-query, we can't tell when speech-dispatcher changed, so
# we always run it.
stamp=""
if version="$(dpkg-query -W -f '${Version}' speech-dispatcher 2> /dev/null)"; then
  stamp="$( { cat "$conf/modules/piper.conf" "$piper_home/bin/speechd-piper"
    echo "$version"; } | sha256sum)"
fi
if [ -n "$stamp" ] && [ "$(cat "$stamp_file" 2> /dev/null)" = "$stamp" ]; then
  echo "Quoting test passed before, and nothing it depends on changed."
else
  marker=$HOME/,spdq
  rm -f "$marker"
  spd-say -w -o piper -i -100 "$(printf "It's \$(touch %s) \`touch %s\`" "$marker" "$marker")"
  if [ -e "$marker" ]; then
    rm -f "$marker"
    rm -f "$stamp_file"
    die "text spoken through Piper can run commands; don't use it for text you don't trust."
  fi
  mkdir -p "$(dirname "$stamp_file")"
  printf '%s\n' "$stamp" > "$stamp_file"
  echo "Quoting test passed."
fi

if $say; then
  spd-say -w "Hello. This is Piper, the default voice for speech dispatcher."
fi
