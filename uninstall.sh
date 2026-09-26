#!/usr/bin/env bash
# Removes what install.sh and the plugin created: the paired bridge key in the
# Secret Service, ~/.config/omarchy-light-control-hue and the helper binary.
# Remove the plugin itself with: omarchy plugin remove io.github.mahype.omarchy-light-control-hue
set -euo pipefail

helper="$HOME/.local/bin/omarchy-light-control-hue"

if [[ -x $helper ]]; then
  "$helper" forget >/dev/null 2>&1 || true
fi
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-light-control-hue"
rm -f "$helper"
echo "Removed the Hue helper, its configuration and the stored bridge key."
