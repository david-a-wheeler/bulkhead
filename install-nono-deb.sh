#!/bin/sh
# install-nono-deb.sh: install nono, or update it to the latest release, on
# Debian, Ubuntu, or another system that uses dpkg. vm-setup.sh runs it;
# you can also run it yourself (from outside any nono sandbox, since it
# uses sudo). Restart running agent sessions afterward so they use the
# new nono.
#
# Usage: install-nono-deb.sh
#
# nono publishes no apt repository for Debian/Ubuntu, only .deb files
# on GitHub Releases (see https://nono.sh/docs/cli/getting_started/installation),
# so apt can't update it. This does what those docs say: download the
# latest release's .deb for this architecture and install it. It first
# checks the file against the sha256 digest GitHub reports for it, which
# catches a damaged download (not a compromised release). It does
# nothing if the latest version is already installed. Needs curl, jq,
# dpkg, apt-get, and sha256sum (vm-setup.sh installs them).
set -eu

release_api=https://api.github.com/repos/nolabs-ai/nono/releases/latest
if ! command -v dpkg > /dev/null; then
  echo "$0: this only handles .deb (dpkg) systems; for others see" >&2
  echo "  https://nono.sh/docs/cli/getting_started/installation" >&2
  exit 1
fi
arch="$(dpkg --print-architecture)"

release="$(curl -fsSL "$release_api")"
version="$(printf '%s' "$release" | jq -r '.tag_name')"
version="${version#v}"
asset="$(printf '%s' "$release" | jq -c --arg n "nono-cli_${version}_${arch}.deb" \
  '.assets[] | select(.name == $n)')"
if [ -z "$asset" ]; then
  echo "$0: no nono $version .deb for architecture $arch; install it by hand:" >&2
  echo "  https://github.com/nolabs-ai/nono/releases" >&2
  exit 1
fi

# dpkg-query fails when nono-cli isn't installed; that's expected.
installed="$(dpkg-query -W -f='${Version}' nono-cli 2>/dev/null || true)"
if [ "$installed" = "$version" ]; then
  echo "nono is already up to date (version $version)."
  exit 0
fi

url="$(printf '%s' "$asset" | jq -r '.browser_download_url')"
digest="$(printf '%s' "$asset" | jq -r '.digest // ""')"
case "$digest" in
  sha256:*) ;;
  *) echo "$0: GitHub reported no sha256 digest for $url; not installing." >&2; exit 1 ;;
esac

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
deb="$dir/nono-cli.deb"
echo "Downloading and installing nono $version${installed:+ (replacing $installed)}..."
curl -fsSL "$url" -o "$deb"
echo "${digest#sha256:}  $deb" | sha256sum -c --quiet - ||
  { echo "$0: $url doesn't match its sha256 digest; not installing." >&2; exit 1; }
# apt-get, not dpkg -i, so that if another apt or dpkg holds the lock
# (e.g., unattended-upgrades), we wait up to 15 minutes instead of
# failing. The file is ours and already checked, so apt needn't drop
# to its _apt user to read it (which it can't, in our private TMPDIR).
sudo apt-get -o DPkg::Lock::Timeout=900 -o APT::Sandbox::User=root install -y "$deb"

if [ -n "$installed" ]; then
  echo "Updated nono: $installed -> $version"
else
  echo "Installed nono $version."
fi
