#!/bin/bash
# Copy this checkout into the Omarchy user plugin directory for local testing.
# Omarchy rejects symlinked plugins, so a plain copy is the dev loop.
#
# Live plugin reloads have crashed Quickshell even during a directory swap.
# Stage outside the watched tree, then stop the shell before replacing files.
# The shell is restarted only if it was running before installation.

set -euo pipefail

src=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
id=$(jq -r '.id' "$src/manifest.json")
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $id != *..* ]] || { echo "invalid plugin id: $id" >&2; exit 1; }
plugins="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
dest="$plugins/$id"
mkdir -p "$plugins"
stage=$(mktemp -d "${plugins%/plugins}/.$id.staging.XXXXXX")
restart_needed=0
old=""
cleanup() {
  local status=$?
  if [[ -n $old && -d $old && ! -d $dest ]]; then mv "$old" "$dest"; fi
  rm -rf "$stage"
  if (( restart_needed )); then
    omarchy restart shell || echo "Shell restart failed; run: omarchy restart shell" >&2
  fi
  return "$status"
}
trap cleanup EXIT

rsync -a \
  --exclude '.git' --exclude 'docs' --exclude 'tests' --exclude 'tmp' \
  --exclude '.remember' --exclude 'node_modules' --exclude '*.md' \
  "$src/" "$stage/"

omarchy plugin validate "$stage"

# Recover the installed desktop environment when launched from Codex or SSH.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}"
session_omarchy_path=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1) || true
export OMARCHY_PATH="${session_omarchy_path:-${OMARCHY_PATH:-/usr/share/omarchy}}"
if [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hypr_dir=$(find "$XDG_RUNTIME_DIR/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2-) || true
  [[ -z $hypr_dir ]] || export HYPRLAND_INSTANCE_SIGNATURE="${hypr_dir##*/}"
fi

if omarchy-shell shell ping >/dev/null 2>&1; then
  if omarchy-hyprland-session-locked; then
    echo "Refusing to install while the session is locked. Unlock it first." >&2
    exit 1
  else
    lock_status=$?
    if (( lock_status != 1 )); then
      echo "Could not determine whether the session is locked; installation stopped." >&2
      exit 1
    fi
  fi
  while timeout 5 quickshell kill -p "$OMARCHY_PATH/shell" --any-display >/dev/null 2>&1; do :; done
  if omarchy-shell shell ping >/dev/null 2>&1; then
    echo "Could not stop the shell; plugin files were not replaced." >&2
    exit 1
  fi
  restart_needed=1
fi

if [[ -d $dest ]]; then
  old="$plugins/.$id.old.$$"
  mv "$dest" "$old"
  mv "$stage" "$dest"
  rm -rf "$old"
else
  mv "$stage" "$dest"
fi
if (( restart_needed )); then
  omarchy restart shell
  restart_needed=0
fi
rm -rf "$stage"
trap - EXIT

echo "Installed $id to $dest"
