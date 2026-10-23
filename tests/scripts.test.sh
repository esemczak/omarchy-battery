#!/usr/bin/env bash
# Plain-bash tests for bin/* against fake sysfs trees. Run from the repo root.
set -u
cd "$(dirname "$0")/.."

check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    exit 1
  fi
}

read_dell() { BATTERY_SYSFS=tests/fixtures/sysfs/dell bin/battery-read.sh | jq -e '.present and .mode=="Fast" and .end==90 and .tempC==28.8 and .made=="2025-12-30" and (.ac|not)'; }
read_generic() { BATTERY_SYSFS=tests/fixtures/sysfs/generic bin/battery-read.sh | jq -e '.modes==[] and .mode==null and .full!=null'; }
read_none() { BATTERY_SYSFS=tests/fixtures/sysfs/none bin/battery-read.sh | jq -e '.present==false'; }

check "battery-read dell" read_dell
check "battery-read generic" read_generic
check "battery-read none" read_none

# --- root helper (runs as normal user; BATTERY_SYSFS honoured only when EUID != 0) ---
H="$PWD/bin/esemczak-battery-helper"
fresh() { local d; d=$(mktemp -d); cp -r "tests/fixtures/sysfs/$1/." "$d/"; printf '%s' "$d"; }
helper() { local fx=$1; shift; local d; d=$(fresh "$fx"); BATTERY_SYSFS=$d "$H" "$@"; local rc=$?; HDIR=$d; return $rc; }
expect_rc() { local want=$1; shift; "$@"; [[ $? -eq $want ]]; }

h_mode_ok() { local d; d=$(fresh dell); BATTERY_SYSFS=$d "$H" mode Custom && [[ $(cat "$d/BAT0/charge_types") == Custom ]]; }
h_limits_ok() { local d; d=$(fresh dell); BATTERY_SYSFS=$d "$H" limits 60 80 && [[ $(cat "$d/BAT0/charge_control_start_threshold") == 60 && $(cat "$d/BAT0/charge_control_end_threshold") == 80 ]]; }
h_limits_up() { local d; d=$(fresh dell); BATTERY_SYSFS=$d "$H" limits 95 98 && [[ $(cat "$d/BAT0/charge_control_start_threshold") == 95 && $(cat "$d/BAT0/charge_control_end_threshold") == 98 ]]; }
h_rc() { local want=$1 fx=$2; shift 2; local d; d=$(fresh "$fx"); BATTERY_SYSFS=$d "$H" "$@"; [[ $? -eq $want ]]; }

check "helper mode Custom" h_mode_ok
check "helper mode Turbo -> 2" h_rc 2 dell mode Turbo
check "helper mode with bracket -> 2" h_rc 2 dell mode '[Fast]'
check "helper mode empty -> 2" h_rc 2 dell mode ''
check "helper mode Custom extra arg -> 2" h_rc 2 dell mode Custom x
check "helper limits 60 80" h_limits_ok
check "helper limits 95 98 (end first)" h_limits_up
check "helper limits 80 80 -> 2" h_rc 2 dell limits 80 80
check "helper limits 0 50 -> 2" h_rc 2 dell limits 0 50
check "helper limits 50 101 -> 2" h_rc 2 dell limits 50 101
check "helper limits a b -> 2" h_rc 2 dell limits a b
check "helper limits 060 80 -> 2" h_rc 2 dell limits 060 80
check "helper limits -5 50 -> 2" h_rc 2 dell limits -5 50
check "helper generic mode Custom -> 2" h_rc 2 generic mode Custom
check "helper none limits -> 2" h_rc 2 none limits 50 80
check "helper no args -> 2" h_rc 2 dell
check "helper unknown cmd -> 2" h_rc 2 dell bogus

# glob safety: cwd containing a file named "a" must not affect the allowlist
h_glob_fast() { local d w; d=$(fresh dell); w=$(mktemp -d); touch "$w/a"; (cd "$w" && BATTERY_SYSFS=$d "$H" mode Fast) && [[ $(cat "$d/BAT0/charge_types") == Fast ]]; }
h_glob_a() { local d w; d=$(fresh dell); w=$(mktemp -d); touch "$w/a"; (cd "$w" && BATTERY_SYSFS=$d "$H" mode a); [[ $? -eq 2 ]]; }
check "helper glob: mode Fast ok with file 'a' in cwd" h_glob_fast
check "helper glob: mode a -> 2 with file 'a' in cwd" h_glob_a

# --- history-append / state-update ---
HA="$PWD/bin/history-append.sh"
SU="$PWD/bin/state-update.sh"
ha_first() { local s; s=$(mktemp -d); BATTERY_SYSFS=tests/fixtures/sysfs/dell "$HA" "$s" >/dev/null; local ok=1; [[ $(wc -l <"$s/history.jsonl") -eq 2 ]] && [[ $(head -1 "$s/history.jsonl" | jq -r .seed) == true ]] && ok=0; rm -rf "$s"; return $ok; }
ha_skip() { local s o; s=$(mktemp -d); export BATTERY_SYSFS=tests/fixtures/sysfs/dell; "$HA" "$s" >/dev/null; o=$("$HA" "$s"); unset BATTERY_SYSFS; rm -rf "$s"; [[ $o == skipped ]]; }
ha_force() { local s o; s=$(mktemp -d); export BATTERY_SYSFS=tests/fixtures/sysfs/dell; "$HA" "$s" >/dev/null; jq -c 'if .seed then . else .t -= 10000 end' "$s/history.jsonl" >"$s/h.tmp" && mv "$s/h.tmp" "$s/history.jsonl"; o=$("$HA" "$s" --force); unset BATTERY_SYSFS; local n; n=$(wc -l <"$s/history.jsonl"); rm -rf "$s"; [[ $o == appended && $n -eq 3 ]]; }
ha_force_dedupe() { local s o; s=$(mktemp -d); export BATTERY_SYSFS=tests/fixtures/sysfs/dell; "$HA" "$s" >/dev/null; o=$("$HA" "$s" --force); unset BATTERY_SYSFS; local n; n=$(wc -l <"$s/history.jsonl"); rm -rf "$s"; [[ $o == skipped && $n -eq 2 ]]; }
ha_acchange() { local s o1 o2 ac; s=$(mktemp -d); export BATTERY_SYSFS=tests/fixtures/sysfs/dell; "$HA" "$s" >/dev/null
  ac=$(jq -s '[.[]|select(.seed|not)]|last|.ac' "$s/history.jsonl")
  # same AC state, recent: skipped
  jq -c 'if .seed then . else .t -= 10000 end' "$s/history.jsonl" >"$s/h.tmp" && mv "$s/h.tmp" "$s/history.jsonl"
  o1=$("$HA" "$s" --on-ac-change)
  # flip recorded AC state: appended
  jq -c 'if .seed then . else .ac = (.ac|not) end' "$s/history.jsonl" >"$s/h.tmp" && mv "$s/h.tmp" "$s/history.jsonl"
  o2=$("$HA" "$s" --on-ac-change); unset BATTERY_SYSFS; rm -rf "$s"; [[ $o1 == skipped && $o2 == appended ]]; }
ha_none() { local s o; s=$(mktemp -d); o=$(BATTERY_SYSFS=tests/fixtures/sysfs/none "$HA" "$s"); local ex=1; [[ ! -e $s/history.jsonl ]] && ex=0; rm -rf "$s"; [[ $o == absent && $ex -eq 0 ]]; }
su_merge() { local s; s=$(mktemp -d); "$SU" "$s" '{"chosenMode":"Custom"}' && "$SU" "$s" '{"overcharge":{"streak":1}}'; local rc=1; jq -e '.chosenMode=="Custom" and .overcharge.streak==1' "$s/state.json" && rc=0; rm -rf "$s"; return $rc; }
check "history first run seeds + sample" ha_first
check "history second run skipped" ha_skip
check "history --force appends" ha_force
check "history --force dedupes within 2s" ha_force_dedupe
check "history --on-ac-change only on AC flip" ha_acchange
check "history none -> absent" ha_none
check "state-update merges" su_merge
ha_corrupt() { local s o now; s=$(mktemp -d); now=$(date +%s%3N); printf '{"t":%s,"health":95}\n{"t":12,"hea\n' "$now" >"$s/history.jsonl"; o=$(BATTERY_SYSFS=tests/fixtures/sysfs/dell "$HA" "$s"); rm -rf "$s"; [[ $o == skipped ]]; }
check "history corrupt line still throttles" ha_corrupt
ha_future() { local s o now; s=$(mktemp -d); now=$(date +%s%3N); printf '{"t":%s,"health":95}\n' "$((now + 172800000))" >"$s/history.jsonl"; o=$(BATTERY_SYSFS=tests/fixtures/sysfs/dell "$HA" "$s"); rm -rf "$s"; [[ $o == appended ]]; }
check "history far-future last sample does not block sampling" ha_future

# --- power-sample ---
PS="$PWD/bin/power-sample.sh"
ps_run() { POWER_UID=1000 CGROUP_ROOT="$PWD/tests/fixtures/cgroup" BATTERY_SYSFS="${1:-$PWD/tests/fixtures/sysfs/dell}" "$PS"; }
ps_groups() { ps_run | jq -e '(.groups|length)==4 and (.groups|map(.path)|any(test("app-graphical.slice$"))|not) and (.groups|all(.usec==1000)) and (.groups|map(.path)|all(startswith("/")|not))'; }
ps_nodraw() { ps_run | jq -e '.drawW==null and .status=="Discharging" and (.t|type=="number") and (.ac|type=="boolean")'; }
ps_copy() { local s; s=$(mktemp -d); cp -r tests/fixtures/sysfs/dell/. "$s"; printf '%s' "$s"; }
ps_draw() { local s rc; s=$(ps_copy); printf 531000 >"$s/BAT0/current_now"; printf 12183000 >"$s/BAT0/voltage_now"; ps_run "$s" | jq -e '.drawW>6.46 and .drawW<6.48'; rc=$?; rm -rf "$s"; return $rc; }
ps_power_now() { local s rc; s=$(ps_copy); printf 7500000 >"$s/BAT0/power_now"; ps_run "$s" | jq -e '.drawW==7.5'; rc=$?; rm -rf "$s"; return $rc; }
ps_charging() { local s rc; s=$(ps_copy); printf 531000 >"$s/BAT0/current_now"; printf 12183000 >"$s/BAT0/voltage_now"; printf 'Charging\n' >"$s/BAT0/status"; ps_run "$s" | jq -e '.drawW==null and .status=="Charging"'; rc=$?; rm -rf "$s"; return $rc; }
ps_nobat() { POWER_UID=1000 CGROUP_ROOT=/nonexistent BATTERY_SYSFS="$PWD/tests/fixtures/sysfs/none" "$PS" | jq -e '.drawW==null and .groups==[]'; }
check "power-sample leaf groups only" ps_groups
check "power-sample no current/voltage -> drawW null" ps_nodraw
check "power-sample current*voltage -> watts" ps_draw
check "power-sample power_now preferred" ps_power_now
check "power-sample Charging -> drawW null" ps_charging
check "power-sample no battery/cgroups -> valid JSON" ps_nobat
