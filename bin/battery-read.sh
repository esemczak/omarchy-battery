#!/usr/bin/env bash
# Print one battery Snapshot JSON object on stdout. Always exits 0.
root=${BATTERY_SYSFS:-/sys/class/power_supply}

rd() { [[ -r $1 ]] && tr -d '\n' <"$1" 2>/dev/null; }
num() { local v; v=$(rd "$1"); [[ $v =~ ^-?[0-9]+$ ]] && printf '%s' "$v" || printf 'null'; }

bat=""
for d in "$root"/BAT*; do
  [[ -d $d ]] && { bat=$d; break; }
done

ac=false
for d in "$root"/*; do
  [[ -d $d ]] || continue
  if [[ $(rd "$d/type") == Mains && $(rd "$d/online") == 1 ]]; then ac=true; break; fi
done

if [[ -z $bat ]]; then
  jq -n --argjson ac "$ac" \
    '{present:false, modes:[], mode:null, start:null, end:null, full:null, design:null, cycles:null, percent:null, status:null, tempC:null, ac:$ac, made:null}'
  exit 0
fi

full=$(num "$bat/energy_full"); design=$(num "$bat/energy_full_design")
if [[ $full == null || $design == null ]]; then
  full=$(num "$bat/charge_full"); design=$(num "$bat/charge_full_design")
fi

made=null
y=$(rd "$bat/manufacture_year"); m=$(rd "$bat/manufacture_month"); dd=$(rd "$bat/manufacture_day")
if [[ $y =~ ^[0-9]+$ && $m =~ ^[0-9]+$ && $dd =~ ^[0-9]+$ ]]; then
  made=$(printf '"%04d-%02d-%02d"' "$((10#$y))" "$((10#$m))" "$((10#$dd))")
fi

jq -n \
  --arg ct "$(rd "$bat/charge_types")" \
  --arg status "$(rd "$bat/status")" \
  --argjson start "$(num "$bat/charge_control_start_threshold")" \
  --argjson end "$(num "$bat/charge_control_end_threshold")" \
  --argjson full "$full" --argjson design "$design" \
  --argjson cycles "$(num "$bat/cycle_count")" \
  --argjson percent "$(num "$bat/capacity")" \
  --argjson temp "$(num "$bat/temp")" \
  --argjson ac "$ac" --argjson made "$made" '
  ($ct | split(" ") | map(select(length > 0))) as $toks
  | {present: true,
     modes: ($toks | map(gsub("[\\[\\]]"; ""))),
     mode: ($toks | map(select(startswith("[") and endswith("]")) | gsub("[\\[\\]]"; "")) | first // null),
     start: $start, end: $end, full: $full, design: $design, cycles: $cycles, percent: $percent,
     status: (if $status == "" then null else $status end),
     tempC: (if $temp == null then null else $temp / 10 end),
     ac: $ac, made: $made}' 2>/dev/null \
  || echo '{"present":false,"modes":[],"mode":null,"start":null,"end":null,"full":null,"design":null,"cycles":null,"percent":null,"status":null,"tempC":null,"ac":false,"made":null}'
exit 0
