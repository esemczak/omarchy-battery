#!/usr/bin/env bash
# Install the root-owned charge helper to /usr/local/bin (asks for sudo).
set -euo pipefail
cd "$(dirname "$0")"
dest=/usr/local/bin/esemczak-battery-helper
sudo install -o root -g root -m 0755 bin/esemczak-battery-helper /usr/local/bin/esemczak-battery-helper
echo "Installed $dest"
