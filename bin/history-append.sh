#!/usr/bin/env bash
# Usage: history-append.sh <stateDir> [--force | --on-ac-change[=true|false]]
# Append a battery Sample (and a seed on first run) to <stateDir>/history.jsonl.
# Prints: appended | skipped | absent
dir=${1:-}; force=${2:-}
[[ -n $dir ]] || { echo "usage: $0 <stateDir> [--force | --on-ac-change[=true|false]]" >&2; exit 2; }
here=$(dirname "$0")

snap=$("$here/battery-read.sh")
# --on-ac-change=<expected>: on USB-C the charger event arrives a second or two
# before the AC flag in sysfs flips, so re-read until it agrees (or give up).
if [[ $force == --on-ac-change=true || $force == --on-ac-change=false ]]; then
  expect=${force#--on-ac-change=}; force=--on-ac-change
  deadline=$(( $(date +%s%3N) + ${AC_SETTLE_MS:-10000} ))
  while [[ $(jq -r '.ac' <<<"$snap") != "$expect" ]] && (( $(date +%s%3N) < deadline )); do
    sleep 0.5
    snap=$("$here/battery-read.sh")
  done
fi
if [[ $(jq -r '.present' <<<"$snap") != true ]]; then echo absent; exit 0; fi

mkdir -p "$dir" || exit 1
exec 9>"$dir/.lock" || exit 1
flock 9 || exit 1

hist=$dir/history.jsonl
now=$(date +%s%3N)

# Compact sample from the snapshot; health matches Model.healthPct (0.1 rounding).
mk() { # $1 = t
  jq -c --argjson t "$1" '{t:$t,
    health: (if (.full // 0) > 0 and (.design // 0) > 0 then ((.full / .design * 1000 | round) / 10) else null end),
    full, design, cycles, mode, start, end, percent, status, tempC, ac}' <<<"$snap"
}

if [[ ! -s $hist ]]; then
  made=$(jq -r '.made // empty' <<<"$snap")
  if [[ -n $made ]] && st=$(date -d "$made 00:00:00" +%s 2>/dev/null); then
    jq -nc --argjson t "$((st * 1000))" '{t:$t, health:100, seed:true}' >>"$hist"
  fi
fi

last=$(tail -n 50 "$hist" 2>/dev/null | jq -R --argjson lim "$((now + 86400000))" 'fromjson? | select(type=="object" and (.seed|not) and (.t|type=="number") and .t <= $lim) | .t' 2>/dev/null | jq -s 'max // 0' 2>/dev/null || echo 0)
[[ $last =~ ^[0-9]+(\.[0-9]+)?$ ]] || last=0
last=${last%.*}
# --on-ac-change: a forced sample only if AC state differs from the last real sample.
if [[ $force == --on-ac-change ]]; then
  snap_ac=$(jq -r '.ac' <<<"$snap")
  last_ac=$(tail -n 50 "$hist" 2>/dev/null | jq -R 'fromjson? | select(type=="object" and (.seed|not) and (.t|type=="number")) | .ac' 2>/dev/null | jq -s 'last' 2>/dev/null)
  [[ $last_ac != null && -n $last_ac && $last_ac != "$snap_ac" ]] && force=--force
fi
if [[ $force != --force ]] && (( now - last < 21600000 && last > 0 )); then echo skipped; exit 0; fi
# Even a forced sample is dropped if a real one was taken moments ago (double trigger).
if (( now - last < 2000 && last > 0 )); then echo skipped; exit 0; fi

line=$(mk "$now")
if [[ $(jq -r '.health' <<<"$line") == null ]]; then echo absent; exit 0; fi
printf '%s\n' "$line" >>"$hist"
echo appended
