# omarchy-battery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Omarchy shell plugin `esemczak.battery`. It is a drop-in replacement for the stock `omarchy.power` bar widget, and adds charging-mode and limit controls, a battery-health history and graph, and two alerts: "limit ignored" and "fast degradation".

**Architecture:**
- **One plugin, two entry points:**
  - `Panel.qml` is the bar widget, created once per monitor bar. It only reads state and runs user-initiated actions.
  - `Service.qml` is the shell's single background instance. It samples history and evaluates alerts.
- **Data flows through files** under `~/.local/state/esemczak-battery/`, written by small `bin/` scripts behind `flock`.
- **Logic stays testable:** all decisions (parsing, wear rate, projection, alerts, chart points) live in a pure `Model.js`, tested with `node --test`.
- **Privileged writes** go through a root-owned helper in `/usr/local/bin`, run via `pkexec`, so it asks for a password every time.

**Tech Stack:** Quickshell/QML (Omarchy 4.x shell), plain JS (ES5 style, same file loads in QML and node), bash + jq, node:test, pkexec/polkit.

**Spec:** `docs/superpowers/specs/2026-10-24-battery-plugin-design.md`. Read it before starting any task.

**Reference implementation to copy patterns from:** `~/Work/omarchy-monitor-layout`, which covers `dev-install.sh`, the `Model.js` header and export block, and the `tests/*.test.js` / `tests/*.test.sh` style. Stock widget being replaced: `/usr/share/omarchy/shell/plugins/panels/power/{Panel.qml,Model.js}`. Stock UI components: `/usr/share/omarchy/shell/Ui/` (`PanelSlider`, `Button`, `PanelSectionHeader`, `PanelSeparator`, `KeyboardPanel`, `BarIconButton`).

## Global Constraints

- Plugin id `esemczak.battery`; repo `~/Work/omarchy-battery`; MIT licence; author `esemczak`.
- Never edit anything under `/usr/share/omarchy/`; reading it is fine.
- No new packages. Use only bash, jq, upower, pkexec and node, which are all present.
- `omarchy plugin validate <dir>` must pass. Symlinked plugins are rejected, so install by copying with `dev-install.sh`.
- No passwordless privilege: no sudoers or polkit rule granting `yes`. Every battery setting change runs `pkexec`, which prompts each time.
- The privileged helper is root-owned, at `/usr/local/bin/esemczak-battery-helper`, mode 0755. It is never run from a user-writable path.
- State dir: `${XDG_STATE_HOME:-$HOME/.local/state}/esemczak-battery/`, holding `history.jsonl` (append-only, never pruned) and `state.json`.
- History sampling: on service start, every 6 h, and on AC plug/unplug. It skips the sample if the last real sample is younger than 6 h, unless `--force` is given (plug/unplug forces).
- Alert checks: every 5 min and on AC plug/unplug.
- Widget settings (in the widget's `shell.json` entry), with defaults:
  - `showPercentage`: false
  - `warrantyEnd`: `"2027-04-30"`
  - `healthFloor`: 80
  - `alerts.limitIgnored`: true
  - `alerts.degradation`: true
- Notifications use `omarchy-notification-send` with the stock argument style:
  `omarchy-notification-send -g <glyph> -u <urgency> "<title>" "<body>"`.
- Keep every `omarchy.power` behaviour listed in the spec's "Parity" section.
- Don't touch the stock `omarchy.battery` service (10% low-battery warning, `battery-low` hook, power-profile auto-switch).

## Review Focus

1. **No battery, or a non-Dell battery missing `charge_types`/`charge_control_*`** (desktop, other laptops). Expected: the widget is hidden when there's no battery, the service does nothing, the Charging section shows only the controls the hardware has, and nothing errors. Tests in Tasks 2 and 5.
2. **A truncated or corrupt `history.jsonl` line**, for example after power loss mid-append. Expected: bad lines are skipped, and the graph and wear rate use the rest. Test in Task 4.
3. **Clock jumps.** This laptop's RTC was a day behind at boot on 2026-10-24 until NTP fixed it. Expected: samples are sorted by time, samples more than 1 day in the future are ignored, and one off-time sample doesn't move the wear rate much (Theil–Sen on daily medians). Test in Task 4.
4. **Password prompt cancelled or wrong** (pkexec exit 126/127). Expected: nothing changes, the chosen mode isn't recorded, and the panel shows "Not changed" briefly. Test in Task 3 (`Model.actionResult`).
5. **Mode changed outside the panel after a recorded choice** (BIOS reset to Standard). Expected: the "limit ignored" alert fires because the live mode differs from `chosenMode`. Test in Task 5.

---

## File Structure

```
manifest.json            kinds ["bar-widget","service"]; clonedFrom omarchy.power
qmldir                   registers Service, HealthChart
LICENSE, README.md, CHANGELOG.md, .gitignore, dev-install.sh
Model.js                 pure logic: stock-ported helpers + new parsing/health/alerts/chart
Panel.qml                bar widget + panel (parity + banner + Charging + Health)
HealthChart.qml          Canvas line chart fed by Model.chartPoints
Service.qml              background sampler + alert evaluator + notifier
bin/battery-read.sh      prints one JSON snapshot of the battery (sysfs)
bin/history-append.sh    appends a sample (and seed on first run), flock'd
bin/state-update.sh      merges a JSON object into state.json, flock'd, atomic
bin/esemczak-battery-helper   root helper: `mode <name>` | `limits <start> <end>`
install-helper.sh        sudo-installs the helper to /usr/local/bin
tests/model.test.js      node --test for Model.js
tests/scripts.test.sh    bash tests for bin/* against a fake sysfs tree
tests/fixtures/sysfs/    fake power_supply trees: dell/, generic/, none/
```

Shared shapes (defined once; every task uses these names):

- **Snapshot** (stdout of `battery-read.sh`, normalised by `Model.parseSnapshot`):
  `{present:bool, modes:[string], mode:string|null, start:int|null, end:int|null, full:number|null, design:number|null, cycles:int|null, percent:int|null, status:string|null, tempC:number|null, ac:bool, made:"YYYY-MM-DD"|null}`
- **Sample** (one `history.jsonl` line):
  `{t:epochMs, health:number, full, design, cycles, mode, start, end, percent, status, tempC, ac}`, plus `seed:true` on the synthetic point.
- **State** (`state.json`):
  `{chosenMode:string|null, alerts:{limitIgnored:Alert, degradation:Alert}, notify:{limitIgnoredSent:bool, degradationLastSent:epochMs|null}, overcharge:{streak:int, lastPercent:int|null}}`
- **Alert:** `{active:bool, reason:string, text:string}`. Degradation also has `date:epochMs|null` and `basis:"fit"|"estimate"|"none"`.

---

### Task 1: Scaffold, stock parity helpers, validate

**Files:**
- Create: `manifest.json`, `qmldir`, `LICENSE`, `.gitignore` (extend the existing one), `dev-install.sh` (copy verbatim from `~/Work/omarchy-monitor-layout/dev-install.sh`; it reads the id from the manifest)
- Create: `Model.js`, `tests/model.test.js`

**Interfaces:**
- Produces:
  - `Model.PLUGIN_ID = "esemczak.battery"`
  - from the stock `Model.js`, unchanged in behaviour: `clampIndex`, `selectProfileIndex`, `parseKeyValue`, `parseProfiles`, `profileIcon`, `batteryFraction`, `chargeThresholdActive`, `batteryIcon`, `modeLabel`
  - `Model.stateDir(home, xdgStateHome) -> string`
  - the export block in the `if (typeof module !== "undefined") module.exports = {...}` style used by monitor-layout

- [ ] **Step 1: Write the manifest**
  It needs `schemaVersion: 1`, `id`, `name: "Battery"`, `version: "0.1.0"`, `author`, `license`, `description`, `kinds: ["bar-widget","service"]`, `entryPoints: {barWidget:"Panel.qml", service:"Service.qml"}`, `barWidget: {displayName:"Battery", description:"Battery, charging controls, health history and alerts", category:"System", allowMultiple:false, defaultSection:"right"}`, and `omarchy: {clonedFrom:"omarchy.power"}`. Add placeholder `Panel.qml` and `Service.qml` files, each a bare `Item {}`.
- [ ] **Step 2: Write failing tests for the ported helpers**
  In `tests/model.test.js`, the test `"stock helpers behave like omarchy.power"` asserts:
  - `parseKeyValue("percentage\t97%\ncycles\t65")` equals `{percentage:"97%", cycles:"65"}`
  - `parseProfiles("power-saver\t0\nbalanced\t1\nperformance\t0", 0)` equals `{profiles:["power-saver","balanced","performance"], activeProfile:"balanced", profileIndex:0}`
  - `selectProfileIndex(2, 1, ["a","b","c"]) === 2`
  - `profileIcon("balanced") === "󰊚"`
  - `stateDir("/home/u", "") === "/home/u/.local/state/esemczak-battery"`
  - `stateDir("/home/u", "/x") === "/x/esemczak-battery"`
- [ ] **Step 3: Run `node --test tests/`.** Expected: FAIL, because `Model.js` is missing.
- [ ] **Step 4: Create `Model.js`**
  Copy the stock functions verbatim (keep the `states` argument style), add `PLUGIN_ID` and `stateDir`, and use the monitor-layout header comment and export block.
- [ ] **Step 5: Run `node --test tests/`.** Expected: PASS. Then run `omarchy plugin validate .`. Expected: valid. If the validator rejects `["bar-widget","service"]` together, stop and report it, because the architecture depends on it.
- [ ] **Step 6: Commit** `feat: scaffold esemczak.battery with stock power helpers`.

### Task 2: Battery snapshot reader

**Files:**
- Create: `bin/battery-read.sh`, `tests/scripts.test.sh`, and the `tests/fixtures/sysfs/{dell,generic,none}/` trees
- Modify: `Model.js`, `tests/model.test.js`

**Interfaces:**
- Produces:
  - `bin/battery-read.sh` prints one Snapshot JSON object on stdout and always exits 0. It reads `${BATTERY_SYSFS:-/sys/class/power_supply}`, using the first `BAT*` directory. AC is online when any supply with `type` `Mains` has `online` `1`.
  - `Model.parseChargeTypes(text) -> {modes:[string], active:string|null}`
  - `Model.parseSnapshot(jsonText) -> Snapshot`. It returns `{present:false, modes:[], ac:false}` and nulls on bad JSON.
  - `Model.healthPct(snapshot) -> number|null`, rounded to 0.1.
- **Fixture `dell/BAT0`** (copied from this laptop):
  - `charge_types`: `Trickle [Fast] Standard Adaptive Custom`
  - `charge_control_start_threshold` 50; `charge_control_end_threshold` 90
  - `charge_full` 5400000; `charge_full_design` 5983000
  - `cycle_count` 65; `capacity` 97; `status` Discharging; `temp` 288
  - `manufacture_year/month/day` 2025/12/30
  - `AC/type` Mains; `AC/online` 0
- **Fixture `generic/BAT0`:** `energy_full`/`energy_full_design` and thresholds, but no `charge_types`.
- **Fixture `none/`:** only `AC`.

- [ ] **Step 1: Write failing tests**
  - In `model.test.js`:
    - `parseChargeTypes("Trickle [Fast] Standard Adaptive Custom")` deep-equals `{modes:["Trickle","Fast","Standard","Adaptive","Custom"], active:"Fast"}`
    - `parseChargeTypes("")` gives `{modes:[], active:null}`
    - `healthPct(parseSnapshot(dellJson)) === 90.3`
    - `parseSnapshot("garbage").present === false`
  - In `scripts.test.sh` (plain bash; exit non-zero on the first failure; one `check name cmd` function):
    - `BATTERY_SYSFS=tests/fixtures/sysfs/dell bin/battery-read.sh | jq -e '.present and .mode=="Fast" and .end==90 and .tempC==28.8 and .made=="2025-12-30" and (.ac|not)'`
    - the generic fixture gives `.modes==[] and .mode==null and .full!=null`
    - the none fixture gives `.present==false`
- [ ] **Step 2: Run** `node --test tests/ && bash tests/scripts.test.sh`. Expected: FAIL.
- [ ] **Step 3: Implement `bin/battery-read.sh` and the Model functions**
  - `full`/`design` prefer the `energy_*` pair and fall back to the `charge_*` pair.
  - `tempC` is `temp/10`.
  - A missing file becomes `null`; never fail.
  - Build the output with `jq -n --arg/--argjson`.
- [ ] **Step 4: Run both test commands.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: battery snapshot reader`.

### Task 3: Root helper and install script

**Files:**
- Create: `bin/esemczak-battery-helper`, `install-helper.sh`
- Modify: `tests/scripts.test.sh`, `Model.js`, `tests/model.test.js`

**Interfaces:**
- Produces:
  - `esemczak-battery-helper mode <Name>`: exits 0 on success, 2 on an invalid argument, 3 on a failed write. Valid names are the words of the battery's `charge_types` with brackets removed.
  - `esemczak-battery-helper limits <start> <end>`: integers with `1 <= start < end <= 100`, and only if both `charge_control_*` files exist.
    - **Write order:** if `start >= current end`, write `end` first, otherwise `start` first, so `start < end` holds after each write.
  - `BATTERY_SYSFS` override is honoured **only when `EUID != 0`** (tests). As root it always uses `/sys/class/power_supply`.
  - `install-helper.sh` runs `sudo install -o root -g root -m 0755 bin/esemczak-battery-helper /usr/local/bin/esemczak-battery-helper` and prints the installed path.
  - `Model.HELPER_PATH = "/usr/local/bin/esemczak-battery-helper"`
  - `Model.actionResult(exitCode) -> {ok:bool, message:string}`:
    - 0 → `{ok:true, message:"Saved"}`
    - 126 or 127 → `{ok:false, message:"Not changed"}` (pkexec cancelled or not authorised)
    - 2 → `"Invalid value"`
    - other → `"Couldn't write setting"`

- [ ] **Step 1: Write failing tests**
  Each case runs on a `cp -r` copy of the dell fixture in `mktemp -d`.
  - `scripts.test.sh`:
    - `mode Custom` exits 0, and the file then reads `Trickle Fast Standard Adaptive [Custom]`. Real sysfs rewrites the brackets itself, so the helper writes just `Custom`. For the fixture, assert that the file content equals `Custom`.
    - `mode Turbo` exits 2.
    - `limits 60 80` exits 0, and the files read 60 and 80.
    - `limits 95 98`, starting from end=90, writes end first. Assert the final values are 95 and 98.
    - `limits 80 80`, `limits 0 50` and `limits a b` each exit 2.
    - With the generic fixture (no `charge_types`), `mode Custom` exits 2.
  - `model.test.js`:
    - `actionResult(126).message === "Not changed"`
    - `actionResult(0).ok === true`
- [ ] **Step 2: Run tests.** Expected: FAIL.
- [ ] **Step 3: Implement the helper** with `set -euo pipefail`, no sourcing of other files, and `PATH` set explicitly to `/usr/bin:/bin`. **Implement `install-helper.sh`.**
- [ ] **Step 4: Run tests.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: privileged charge helper with strict validation`.

### Task 4: History and wear rate

**Files:**
- Create: `bin/history-append.sh`, `bin/state-update.sh`
- Modify: `Model.js`, `tests/model.test.js`, `tests/scripts.test.sh`

**Interfaces:**
- Consumes: Snapshot (Task 2).
- Produces:
  - `bin/history-append.sh <stateDir> [--force]`
    - Takes a snapshot via `battery-read.sh`. If `present` is false, it exits 0 and writes nothing.
    - Holds `flock <stateDir>/.lock` throughout.
    - If `history.jsonl` is empty or missing and `made` is known, it first appends a seed Sample: `t` is midnight local on `made`, `health` 100, `seed:true`.
    - It appends a real Sample unless the last non-seed sample is younger than 6 h and `--force` is absent.
    - It prints `appended`, `skipped` or `absent`.
  - `bin/state-update.sh <stateDir> '<json-object>'` deep-merges the object into `state.json` (created if missing) using `jq -s '.[0] * .[1]'`, under the same lock, via a temp file and `mv`.
  - `Model.parseHistory(text, now) -> [Sample]`: skips unparsable lines and lines without a numeric `health`, drops `t > now + 86400000`, and sorts ascending by `t`.
  - `Model.dailyMedians(samples) -> [{t, health}]`: excludes seed samples; buckets by local calendar day; `t` is the bucket's midday.
  - `Model.wearRate(samples, now) -> {perMonth:number|null, basis:"fit"|"estimate"|"none"}`
    - Uses the daily medians from the last 90 days.
    - If they span 30 days or more, the rate is the Theil–Sen slope (median of pairwise slopes) × 30.44 days. That's **basis `fit`**.
    - Otherwise, if a seed and at least one real sample exist, it's the slope from the seed to the latest daily median, × 30.44. That's **basis `estimate`**.
    - Otherwise `{perMonth:null, basis:"none"}`.
    - `perMonth` is the health change per month: negative means wear.
  - `Model.projectFloorDate(health, perMonth, floor, now) -> epochMs|null`: null if `perMonth` is null or ≥ 0, or `health <= floor`. Otherwise `now + (health - floor) / -perMonth × 30.44 days`.

- [ ] **Step 1: Write failing tests** (`model.test.js`)
  - Corrupt-line tolerance: `parseHistory('{"t":1,"health":99}\n{"t":2,"hea\n{"t":3,"health":98}\n', 10)` has length 2.
  - Future drop: a sample at `now + 2 days` is excluded, and one at `now + 1 hour` is kept.
  - Sorting: unsorted input comes back sorted.
  - Estimate:
    - seed at 2025-12-30 at 100, and a real sample at 2026-10-24 at 90.3
    - → `basis "estimate"` and `perMonth` ≈ −1.0 (within 0.05)
  - Fit:
    - 60 daily samples falling 0.05/day, plus one outlier day at +5
    - → `basis "fit"` and `perMonth` ≈ −1.52 (within 0.1)
  - Projection: `projectFloorDate(90.3, -1.5, 80, Date.UTC(2026,9,24))` falls in May 2027.
  - Projection nulls: `projectFloorDate(90, 0.1, 80, now) === null` and `projectFloorDate(79, -1, 80, now) === null`.
- [ ] **Step 2: Write failing script tests** (`scripts.test.sh`, dell fixture, temp state dir)
  - First run writes 2 lines, the first with `seed==true`.
  - An immediate second run prints `skipped`.
  - `--force` prints `appended`.
  - The none fixture prints `absent` and doesn't create the file.
  - `state-update.sh` with `{"chosenMode":"Custom"}` and then `{"overcharge":{"streak":1}}` leaves both keys present.
- [ ] **Step 3: Run tests.** Expected: FAIL.
- [ ] **Step 4: Implement** the scripts and Model functions.
- [ ] **Step 5: Run tests.** Expected: PASS.
- [ ] **Step 6: Commit** `feat: battery history log and wear-rate model`.

### Task 5: Alert evaluation

**Files:**
- Modify: `Model.js`, `tests/model.test.js`

**Interfaces:**
- Consumes: Snapshot, Sample, State, `wearRate`, `projectFloorDate`, `healthPct`.
- Produces:
  - `Model.settingsFrom(entry) -> {showPercentage, warrantyEnd:epochMs, healthFloor, alertLimitIgnored, alertDegradation}`
    - Applies the Global Constraints defaults.
    - Parses `warrantyEnd` as local end-of-day. An invalid date falls back to the default.
  - `Model.settingsFromShellConfig(jsonText) -> settings`
    - Finds the first bar `layout` entry (any section) whose `id` is `"esemczak.battery"`.
    - Passes it to `settingsFrom`, or `settingsFrom({})` if it isn't found or the JSON is invalid.
  - `Model.evaluateAlerts(snapshot, samples, state, settings, now) -> {state:State, notifications:[{key, title, body, urgency}]}`. Rules, exactly:
    - **limitIgnored, reason `mode`:**
      - Condition: `snapshot.end !== null && snapshot.end < 100 && snapshot.modes.length > 0 && snapshot.mode !== "Custom" && snapshot.mode !== state.chosenMode`
      - Text: `"Charge limit {start}–{end}% is set but mode is {mode}, so it's ignored."`
    - **limitIgnored, reason `overcharge`:**
      - Condition: `snapshot.ac && snapshot.mode === "Custom" && snapshot.status === "Charging" && snapshot.percent > snapshot.end + 3 && state.overcharge.lastPercent !== null && snapshot.percent > state.overcharge.lastPercent`, holding for 2 consecutive evaluations (`overcharge.streak >= 2`).
      - The streak resets to 0 whenever the condition is false. `lastPercent` is always updated.
      - Text: `"Charging past the {end}% limit ({percent}%)."`
    - **Notifying for limitIgnored:**
      - When it becomes active and `notify.limitIgnoredSent` is false, push one notification and set the flag.
      - Clear the flag when the alert becomes inactive.
      - Notification: key `limitIgnored`, title `"Battery limit ignored"`, urgency `normal`.
    - **degradation:**
      - Uses the current health from the latest sample, falling back to the snapshot.
      - Active when `projectFloorDate(health, rate.perMonth, healthFloor, now)` is not null and earlier than `warrantyEnd`.
      - Text: `"At {abs(perMonth).toFixed(1)}%/month, health reaches {floor}% around {Mon YYYY}, before the warranty ends."`, with `" (estimate)"` appended when the basis is `estimate`.
      - Notifies only if `basis === "fit"` and (`degradationLastSent` is null or `now - degradationLastSent >= 7 days`). Then it sets `degradationLastSent = now`.
      - Notification: key `degradation`, title `"Battery wearing fast"`, urgency `normal`.
    - An alert whose setting is false is always `{active:false}` and never notifies.
    - If `snapshot.present` is false, the result has both alerts inactive and no notifications.

- [ ] **Step 1: Write failing tests**, one `test()` per line:
  - **Today's case:** dell snapshot (Fast, 50–90), `chosenMode` null → limitIgnored active with reason `mode`, and 1 notification.
  - **Repeat:** the same inputs with the returned state → still active, 0 notifications.
  - **Owner chose Adaptive:** `chosenMode` "Adaptive", live mode "Adaptive" → inactive.
  - **BIOS reset** (Review Focus 5): `chosenMode` "Custom", live mode "Standard" → active.
  - **Custom, holding at 97% "Not charging" on AC** → inactive.
  - **Custom, charging 94 → 95 → 96** over three evaluations, end 90 → inactive, inactive, then active (reason `overcharge`). The first evaluation has no `lastPercent`; each later one needs a rising percent, and two in a row are required.
  - **Generic battery without `charge_types`** (Review Focus 1) → limitIgnored inactive.
  - **Degradation, fit basis:** 60 days falling 0.05/day from 90.3, `warrantyEnd` 2027-04-30 → active and notifies. Evaluating again 1 day later → no notification. 8 days later → notifies again.
  - **Degradation, estimate basis**, projecting before the warranty end → active, 0 notifications, and the text ends with `(estimate)`.
  - **Settings off:** `alerts.limitIgnored:false` → never active.
  - **Absent battery** → nothing.
  - `settingsFromShellConfig`: a sample `shell.json`, with `omarchy.power` swapped for `esemczak.battery` (`showPercentage:true`), gives `showPercentage:true` and `healthFloor:80`.
- [ ] **Step 2: Run** `node --test tests/`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat: limit-ignored and degradation alert rules`.

### Task 6: Background service

**Files:**
- Modify: `Service.qml`, `qmldir`

**Interfaces:**
- Consumes:
  - `bin/battery-read.sh`, `bin/history-append.sh`, `bin/state-update.sh`
  - `Model.settingsFromShellConfig`, `parseSnapshot`, `parseHistory`, `evaluateAlerts`, `stateDir`
  - the shell injects `shell` and `omarchyPath` (see `/usr/share/omarchy/shell/shell.qml` `ensureService`)
- Produces: a single background instance that keeps `state.json` and `history.jsonl` current. The panels read those files and never call the service directly.

Behaviour:
- **Plugin dir:** resolve it the way monitor-layout's `Service.qml` `pluginDir` does (from `Qt.resolvedUrl("bin/...")`).
- **Settings:** watch `~/.config/omarchy/shell.json` with a `FileView` (`watchChanges: true`) and recompute settings on change.
- **Sampling:** on start, run `history-append.sh <dir>`. Then a `Timer` every 6 h runs the same. On `UPower.onOnBatteryChanged`, run it with `--force`.
- **Alert checks:** a `Timer` every 300000 ms (5 min), with `triggeredOnStart`, plus `UPower.onOnBatteryChanged`. Each check:
  1. runs `battery-read.sh`;
  2. reads `history.jsonl` and `state.json` with `cat` processes (missing files mean empty);
  3. calls `evaluateAlerts`;
  4. writes the returned state via `state-update.sh` (whole-object merge);
  5. for each notification, runs `omarchy-notification-send -g 󰂃 -u <urgency> "<title>" "<body>"`.
- Never run two checks at once: skip the tick if the previous check's processes are still running.

- [ ] **Step 1: Implement `Service.qml`.**
- [ ] **Step 2: Install and enable**
  - Run `./dev-install.sh`, then `omarchy plugin enable esemczak.battery`.
  - Expected:
    - `jq '.plugins, .bar.layout.right' ~/.config/omarchy/shell.json` shows `esemczak.battery` where `omarchy.power` was, still with `showPercentage:true`, and `omarchy.power` is disabled.
    - If the entry was **not** swapped in place, fix `shell.json` by hand: replace the `omarchy.power` entry's `id` with `esemczak.battery` and keep its other keys. Record that in the README install section.
- [ ] **Step 3: Verify the service runs**
  - `ls ~/.local/state/esemczak-battery/` shows `history.jsonl` (2 lines: seed + real) and `state.json`.
  - `jq .alerts.limitIgnored.active state.json` is `true` (the mode is still Fast).
  - **Exactly one** "Battery limit ignored" desktop notification appears, even with an external monitor connected (two bars).
  - Run `omarchy restart shell` → no second notification.
- [ ] **Step 4: Commit** `feat: background sampler and alert service`.

### Task 7: Panel — stock parity

**Files:**
- Modify: `Panel.qml`

**Interfaces:**
- Consumes:
  - the stock helpers in `Model.js` (Task 1)
  - `omarchy-battery-status --shell`, `omarchy-powerprofiles-list --active-state`, `omarchy-powerprofiles-set` — keep using these stock commands exactly as the stock Panel does
- Produces:
  - `Panel.qml` with `moduleName: "esemczak.battery"`, `manageIpc: false`, and its own `IpcHandler { target: "omarchy.power" }` exposing `open close show hide toggle togglePercentage`
  - root properties used by Task 8: `snapshot`, `appState`, `samples`, `settingsObj`, plus `function runHelper(args)`

- [ ] **Step 1: Port the stock `Panel.qml`**
  Start from `/usr/share/omarchy/shell/plugins/panels/power/Panel.qml`. Change only the `moduleName`, add the import of the local `Model.js`, and add the root properties above, empty for now.
- [ ] **Step 2: Manual parity check after `./dev-install.sh`.** Tick each item:
  - [ ] the bar shows "NN% 󰁹"-style text
  - [ ] right-click toggles the percentage, and the choice survives `omarchy restart shell`
  - [ ] the menu's "Battery Percentage" entry, which runs `omarchy-shell omarchy.power togglePercentage`, toggles it
  - [ ] `omarchy-shell omarchy.power toggle` opens and closes the panel
  - [ ] the header phrases rotate on battery
  - [ ] the stats show size, cycles, time and rate
  - [ ] the profile buttons switch profile, with arrows and Enter working
  - [ ] Tab moves to the neighbouring panel
- [ ] **Step 3: Commit** `feat: panel with omarchy.power parity`.

### Task 8: Panel — banner, Charging, Health

**Files:**
- Modify: `Panel.qml`, `Model.js`, `tests/model.test.js`
- Create: `HealthChart.qml` (registered in `qmldir`)

**Interfaces:**
- Consumes:
  - `Model.parseSnapshot`, `parseHistory`, `healthPct`, `wearRate`, `projectFloorDate`, `actionResult`, `HELPER_PATH`, `settingsFromShellConfig`
  - the `state.json` State shape
  - `bin/state-update.sh`
- Produces:
  - `Model.chartPoints(samples, rangeKey, now) -> {points:[{x:0..1, y:0..1, seed:bool}], yMin, yMax, floorY:0..1|null, warrantyX:0..1|null}`
    - `rangeKey` is one of `"3m"` (92 days), `"1y"` (365 days) or `"all"`. `"all"` starts at the first sample, including the seed.
    - `yMax` = 100; `yMin` = `min(75, floor(minHealth) - 2)`.
  - `Model.nextRange(key)` cycles `"3m"` → `"1y"` → `"all"` → `"3m"`.

Panel behaviour:
- **Refreshing data:** when the panel opens and every 5 s while it's open (the existing timer), also run `battery-read.sh` and `cat` the state files.
- **Bar icon:** when `appState.alerts` has any active alert, append ` 󰀦` to the button text.
- **Alert banner:** shown under the stats only when an alert is active. It shows that alert's `text`.
  - For `limitIgnored` with reason `mode`, add a **Fix** button that runs `pkexec <HELPER_PATH> mode Custom`.
- **CHARGING section** (`PanelSectionHeader "CHARGING"`):
  - one `Button` per `snapshot.modes`, marked active for `snapshot.mode`;
  - two `PanelSlider`s (integer, step 1), Start (range 1–99) and End (range 2–100), shown only if `start`/`end` aren't null;
  - the sliders are enabled only when the mode is Custom or the modes list is empty; otherwise they're dimmed with the caption "Applies in Custom mode";
  - on slider `released`, run `pkexec <HELPER_PATH> limits <start> <end>`, with start clamped below end.
  - If the helper isn't present (check `test -x` on panel open), replace the section body with "Install the battery helper: run install-helper.sh in the plugin repo".
- **runHelper(args) flow:**
  1. run `pkexec` with the helper;
  2. on exit, map the code through `actionResult` and show the message for 3 s under the section;
  3. if it's a successful `mode X`, run `state-update.sh <dir> '{"chosenMode":"X"}'`;
  4. then refresh.
  - Keep only one helper call at a time.
- **HEALTH section:**
  - Rows: Health `{healthPct}%` · Wear `{perMonth}%/mo` (with "(est.)" for estimate basis, "—" for none) · Reaches {floor}% `{Mon YYYY}` or "—" · Cycles · Temp `{tempC}°C`.
  - Then a `HealthChart`, full width, `Style.space(70)` high, showing:
    - the polyline of points (the seed point drawn hollow);
    - a dashed floor line;
    - a vertical warranty marker if it's in range;
    - the range label in the corner.
  - Clicking the chart sets `range = Model.nextRange(range)`.
- **POWER PROFILE section:** unchanged, kept last.

- [ ] **Step 1: Write failing tests for `chartPoints`/`nextRange`**
  - Seed (2025-12-30, 100) + real (2026-10-24, 90.3), `"all"` → 2 points, `points[0].seed === true`, `points[0].x === 0`, `points[1].x === 1`.
  - `"3m"` with the same data → 1 point (the seed is out of range).
  - `floorY` for floor 80 lies strictly between 0 and 1.
  - `nextRange("all") === "3m"`.
- [ ] **Step 2: Run.** Expected: FAIL. **Step 3: Implement.** **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Implement the panel sections and `HealthChart.qml`** (Canvas; colours from `root.bar.foreground` with opacity, matching the stock style).
- [ ] **Step 6: Manual check after `./dev-install.sh`** (the helper must be installed: the owner runs `./install-helper.sh` in a terminal):
  - [ ] the banner shows today's text with Fix
  - [ ] cancelling the password prompt → "Not changed", the mode is unchanged, `chosenMode` is unset
  - [ ] Fix with the password → the mode becomes Custom, "Saved" shows, the banner disappears within one refresh, and the bar's 󰀦 mark goes away
  - [ ] moving the End slider to 85 → password → the sysfs end reads 85
  - [ ] choosing Adaptive → no banner (`chosenMode` is Adaptive)
  - [ ] the chart shows the hollow seed and the current point, and clicking cycles 3m/1y/all
- [ ] **Step 7: Commit** `feat: charging controls, health chart and alert banner`.

### Task 9: Docs, release, reboot persistence

**Files:**
- Create: `README.md` (structure as in monitor-layout: what it is, features, requirements, install including `./install-helper.sh`, settings with defaults, IPC, data files, uninstall), `CHANGELOG.md` (0.1.0)
- Possibly create, only if Step 2 fails: `bin/esemczak-battery-reapply` + `esemczak-battery-reapply.service`

- [ ] **Step 1: Write the README and CHANGELOG. Commit** `docs: README and changelog`.
- [ ] **Step 2: Reboot persistence test (with the owner)**
  - Set Custom with 50–90 via the panel, note the `cat` of the three sysfs files, and ask the owner to reboot.
  - After the reboot, compare.
  - **If they match:** note "settings persist in firmware" in the README and finish.
  - **If they don't:** add a root oneshot service, installed by `install-helper.sh`, that runs the reapply script at boot. It reads `/etc/esemczak-battery.conf`, which is root-owned; the helper writes the last applied values there on success. Add tests to `scripts.test.sh` for the write-through, and commit `feat: reapply charge settings at boot`.
- [ ] **Step 3: Final run** of `node --test tests/ && bash tests/scripts.test.sh && omarchy plugin validate .`. Expected: all pass.
