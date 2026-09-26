#!/usr/bin/env bash
# Builds the omarchy-light-control-hue helper from this repository and installs
# it to ~/.local/bin for the current user only. Nothing is downloaded except
# the Rust crates pinned in Cargo.lock, and no Omarchy configuration is changed.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required. Install Rust (e.g. 'omarchy pkg add rust' or rustup) and re-run." >&2
  exit 1
fi

cargo build --release --locked
install -Dm755 target/release/omarchy-light-control-hue "$HOME/.local/bin/omarchy-light-control-hue"
echo "Installed $HOME/.local/bin/omarchy-light-control-hue"
echo "Enable the bar widget with: omarchy plugin enable io.github.mahype.omarchy-light-control-hue --section right"
