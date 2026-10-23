#!/usr/bin/env bash
# Print one power sample JSON object: battery draw + leaf cgroup CPU usage. Always exits 0.
# {"t":epochMs,"ac":bool,"status":str|null,"drawW":num|null,"groups":[{"path":rel,"usec":int}]}
# $UID is readonly in bash, so tests set POWER_UID instead.
sysfs=${BATTERY_SYSFS:-/sys/class/power_supply}
croot=${CGROUP_ROOT:-/sys/fs/cgroup}
uid=${POWER_UID:-$UID}

rd() { [[ -r $1 ]] && tr -d '\n' <"$1" 2>/dev/null; }
isnum() { [[ $1 =~ ^-?[0-9]+$ ]]; }

bat=""
for d in "$sysfs"/BAT*; do [[ -d $d ]] && { bat=$d; break; }; done

ac=false
for d in "$sysfs"/*; do
  [[ -d $d ]] || continue
  if [[ $(rd "$d/type") == Mains && $(rd "$d/online") == 1 ]]; then ac=true; break; fi
done

status=""; draw=null
if [[ -n $bat ]]; then
  status=$(rd "$bat/status")
  if [[ $status == Discharging ]]; then
    p=$(rd "$bat/power_now")
    if isnum "$p" && ((p > 0)); then
      draw=$p; scale=1000000
    else
      c=$(rd "$bat/current_now"); v=$(rd "$bat/voltage_now")
      if isnum "$c" && isnum "$v"; then draw=$((c < 0 ? -c : c)); draw=$((draw * v)); scale=1000000000000; fi
    fi
  fi
fi

trees=()
for t in "$croot/user.slice/user-$uid.slice" "$croot/system.slice"; do [[ -d $t ]] && trees+=("$t"); done

# One find per run: list every cgroup.procs; a dir (kept with a trailing slash so
# C-locale sort puts children right after their parent) is a leaf when the next entry is not below it.
# One awk pass picks leaves and reads their usage_usec, emitting "relpath<TAB>usec" lines.
lines=""
if ((${#trees[@]})); then
  lines=$(find "${trees[@]}" -name cgroup.procs 2>/dev/null | sed 's|cgroup\.procs$||' | LC_ALL=C sort | awk -v root="$croot/" '
    { d[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (i < NR && index(d[i+1], d[i]) == 1) continue
        f = d[i] "cpu.stat"
        if ((getline l < f) > 0) {
          split(l, a, " ")
          if (a[1] == "usage_usec" && a[2] ~ /^[0-9]+$/) { p = d[i]; sub(/\/$/, "", p); sub("^" root, "", p); print p "\t" a[2] }
        }
        close(f)
      }
    }')
fi

now=$(date +%s%3N)
printf '%s' "$lines" | jq -Rsc \
  --argjson t "$now" --argjson ac "$ac" --arg status "$status" \
  --argjson draw "$draw" --argjson scale "${scale:-1}" '
  {t: $t, ac: $ac,
   status: (if $status == "" then null else $status end),
   drawW: (if $draw == null then null else ($draw / $scale * 100 | round / 100) end),
   groups: [split("\n")[] | select(length > 0) | split("\t") | {path: .[0], usec: (.[1] | tonumber)}]}' 2>/dev/null \
  || echo '{"t":0,"ac":false,"status":null,"drawW":null,"groups":[]}'
exit 0
