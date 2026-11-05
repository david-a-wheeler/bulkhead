#!/bin/sh
# vm-piper-install.sh: install Piper, a local neural text-to-speech
# engine (piper-tts, from OHF-Voice/piper1-gpl), for you on this VM:
# the exact packages in piper-requirements.txt, config.sh's
# PIPER_VOICES, and speechd-piper. vm-setup.sh runs it, and then
# vm-speech-setup.sh, which makes Piper speech-dispatcher's default.
# Safe to re-run: it only downloads what's missing or changed.
#
# Usage: vm-piper-install.sh
# No options. Everything goes in ~/.local/share/piper:
#   venv/                 a Python venv with Piper
#   voices/NAME.onnx      each voice, with its NAME.onnx.json
#   bin/speechd-piper     what speech-dispatcher runs to speak
# plus ~/.local/bin/piper, for running Piper yourself (e.g.,
# echo hi | piper -m ~/.local/share/piper/voices/NAME.onnx -f hi.wav).
# Needs python3-venv, jq, and curl (vm-setup.sh installs them). To
# remove it all: rm -rf ~/.local/share/piper ~/.local/bin/piper
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/common.sh"

home=$HOME/.local/share/piper
venv=$home/venv

python3 -c 'import ensurepip' 2>/dev/null ||
  die "python3 can't make a venv; install python3-venv (vm-setup.sh does)."

# The venv, with exactly the pinned packages. Comparing "pip freeze"
# first means a re-run needs no network. When they differ, it starts a
# fresh venv, so nothing an older list installed lingers. Wheels only,
# so installing never runs a package's build code.
want=$(grep -v '^#' "$SCRIPT_DIR/piper-requirements.txt" | sort)
if [ -x "$venv/bin/pip" ] &&
    [ "$("$venv/bin/pip" freeze --all --exclude pip | sort)" = "$want" ]; then
  echo "Piper's packages are up to date."
else
  rm -rf "$venv"
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --disable-pip-version-check \
    --only-binary :all: -r "$SCRIPT_DIR/piper-requirements.txt"
  echo "Installed Piper's packages."
fi
mkdir -p "$HOME/.local/bin" "$home/bin"
[ "$(readlink "$HOME/.local/bin/piper" 2>/dev/null)" = "$venv/bin/piper" ] ||
  ln -sfn "$venv/bin/piper" "$HOME/.local/bin/piper"
cmp -s "$SCRIPT_DIR/speechd-piper" "$home/bin/speechd-piper" ||
  install -m 755 "$SCRIPT_DIR/speechd-piper" "$home/bin/speechd-piper"

# Each voice is on Hugging Face as NAME.onnx and NAME.onnx.json, under
# LANG/LOCALE/SPEAKER/QUALITY/, e.g., en/en_US/ljspeech/high/.
voices=$home/voices
mkdir -p "$voices"
printf '%s\n' "$PIPER_VOICES" | while read -r name type onnx_sha json_sha; do
  [ -n "$name" ] || continue
  # LOCALE-SPEAKER-QUALITY, e.g., en_US-ljspeech-high.
  case $name in
    *[!A-Za-z0-9_-]* | *-*-*-* | *--* | -* | *-) die "PIPER_VOICES: bad voice name $name" ;;
    *-*-*) ;;
    *) die "PIPER_VOICES: bad voice name $name" ;;
  esac
  case $type in
    MALE[123] | FEMALE[123] | CHILD_MALE | CHILD_FEMALE) ;;
    *) die "PIPER_VOICES: bad voice type $type for $name" ;;
  esac
  ready=true
  locale=${name%%-*}
  rest=${name#*-}
  url="https://huggingface.co/rhasspy/piper-voices/resolve/main/${locale%%_*}/$locale/${rest%-*}/${rest##*-}/$name"
  for f in "$name.onnx $onnx_sha" "$name.onnx.json $json_sha"; do
    file=${f% *}
    sha=${f#* }
    if [ -s "$voices/$file" ] && [ "$(sha256sum < "$voices/$file" | cut -d ' ' -f 1)" = "$sha" ]; then
      continue
    fi
    echo "Downloading $file"
    retry 2 curl -fsSL -o "$voices/,$file.part" "$url${file#"$name"}"
    got=$(sha256sum < "$voices/,$file.part" | cut -d ' ' -f 1)
    if [ "$sha" = "-" ]; then
      rm -f "$voices/,$file.part"
      echo "PIPER_VOICES has no SHA-256 for $file; it downloaded as $got." >&2
      echo "  Check it, put it in config.local.sh's PIPER_VOICES, and re-run." >&2
      ready=false
      continue
    fi
    if [ "$got" != "$sha" ]; then
      rm -f "$voices/,$file.part"
      die "$file's SHA-256 is $got, not PIPER_VOICES's $sha."
    fi
    mv "$voices/,$file.part" "$voices/$file"
  done
  if $ready; then
    echo "Voice $name ($type) is installed."
  fi
done
