# Installed into ~/.profile (see install_managed_block in common.sh), so
# login shells that aren't part of the desktop session (e.g., over ssh)
# get the git safety settings too. The desktop session reads the same
# file through systemd's environment.d. See make-git-safety-env for why.
if [ -r "${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/50-bulkhead-git-safety.conf" ]; then
  set -a
  . "${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/50-bulkhead-git-safety.conf"
  set +a
fi
