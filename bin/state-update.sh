#!/usr/bin/env bash
# Usage: state-update.sh <stateDir> '<json-object>'
# Deep-merge the object into <stateDir>/state.json (created if missing), atomically.
dir=${1:-}; patch=${2:-}
[[ -n $dir && -n $patch ]] || { echo "usage: $0 <stateDir> '<json>'" >&2; exit 2; }
jq -e 'type=="object"' <<<"$patch" >/dev/null 2>&1 || { echo "not a JSON object" >&2; exit 2; }
mkdir -p "$dir" || exit 1
exec 9>"$dir/.lock" || exit 1
flock 9 || exit 1
f=$dir/state.json
[[ -s $f ]] && jq -e 'type=="object"' "$f" >/dev/null 2>&1 || echo '{}' >"$f"
tmp=$(mktemp "$dir/.state.XXXXXX") || exit 1
if jq -s '.[0] * .[1]' "$f" <(printf '%s' "$patch") >"$tmp"; then mv "$tmp" "$f"; else rm -f "$tmp"; exit 1; fi
