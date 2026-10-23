# Panel Polish and Power Use Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the whole `esemczak.battery` panel with theme colours and subtle motion. Replace the CHARGING controls with mode tiles and a battery gauge, and add a POWER USE section that ranks the top 3 apps by estimated power.

**Architecture:**
- **Pure logic in `Model.js`** with node tests: theme palette parsing, semantic colours, power-sample parsing, cgroup label mapping, app shares and rows, handle clamping, chart projection points.
- **New QML components** keep `Panel.qml` from growing:
  - `ThemePalette.qml`: a non-visual reader of the theme's `colors.toml`
  - `ModeTiles.qml` and `BatteryGauge.qml`: the CHARGING controls
  - `PowerUse.qml`: the new section
- **One new read-only script**, `bin/power-sample.sh`, prints a JSON sample of the battery draw and leaf-cgroup CPU counters. It is called every 2 s, only while the panel is open.

**Tech Stack:** Quickshell/QML (Omarchy 4.x shell), ES5-style JS shared by QML and node, bash + jq, node:test.

**Spec:** `docs/superpowers/specs/2026-10-24-battery-panel-polish-design.md`. Read it, including its "Builder-check calls" section. The visual target is `docs/superpowers/specs/mockups/full-panel.html`; open it in a browser or read the HTML and CSS.

## Global Constraints

- Branch `feat/panel-polish`. Never push. Never edit `/usr/share/omarchy/`.
- No hard-coded colours. Every colour comes from `ThemePalette` (theme `colors.toml`) or `Commons.Color`, with fallbacks to accent, urgent or foreground. Tints are made with alpha.
- **Semantic colours:**
  - good/within-limits/Custom = `green`
  - warning/Fast/limit-ignored = `red`
  - neutral highlight = `accent`
  - power/draw = `cyan`
  - secondary text = foreground at reduced opacity
- **Motion:**
  - durations 150–300 ms; draw-on and count-up up to 800 ms
  - easing `Easing.OutCubic` or `Easing.InOutSine` only
  - nothing bounces or flashes
  - every looping animation has `running: root.opened` (or is gated on it)
- POWER USE samples only while the panel is open. Its 2 s timer is `running: opened`.
- All v0.1.0 behaviour keeps working: pkexec per change, `chosenMode` recorded only on success, mouse-wheel never commits, "Applies in Custom mode", profile keyboard navigation, IPC, the bar icon and the alert mark.
- The helper is called only as `["pkexec", Model.HELPER_PATH, ...]`.
- Tests: `node --test tests/ && bash tests/scripts.test.sh`. Validate: `omarchy plugin validate .`. Install: `./dev-install.sh`, then check `journalctl --user -b --since "-5 min"` for QML errors or warnings from this plugin; there must be none.
- Screenshots used for verification capture the owner's screen. Keep them only in `.superpowers/` and delete them before reporting.
- Commits are staged by explicit path and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A theme without `green`/`red`/`cyan`, or with an unreadable `colors.toml`.** Expected: semantic colours fall back to accent, urgent or foreground. Nothing is invisible, and nothing throws. Test in Task 1.
2. **Battery not discharging** (on AC, full, or holding at the limit). Expected: "Plugged in" replaces the watts, and the rows show % of CPU. A charge-current number never appears as if it were draw. Test in Task 2.
3. **A cgroup that disappears between two samples** (an app closed), or a counter that goes backwards. Expected: that group is dropped or ignored for the window. There are no negative or NaN shares. Test in Task 2.
4. **Dragging a gauge handle into or past the other handle, or dragging outside Custom mode.** Expected: the handles stop 1 apart, there are no commits outside Custom, and the helper is never called with start ≥ end. Test in Task 3.
5. **Opening and closing the panel repeatedly.** Expected: no runaway timers or processes, the sparkline buffer stays capped at ~5 min (150 points), and gaps over 10 s break the line. Covered in Task 4's QML review and the `appendDrawPoint` tests in Task 2.

---

## File Structure

```
ThemePalette.qml     non-visual: FileView on ${XDG_STATE_HOME:-~/.local/state}/omarchy/current/theme/colors.toml → semantic colours
ModeTiles.qml        tile grid for charge modes (props in, signal out)
BatteryGauge.qml     battery-shaped gauge with fill, safe band, 2 draggable handles (props in, signal out)
PowerUse.qml         POWER USE section: sampler timer + ring buffer + sparkline + top-3 rows
HealthChart.qml      (modify) area fill, draw-on, pulsing latest point, projection line
Panel.qml            (modify) uses the components; header/banner/health/profile restyle; open stagger
bin/power-sample.sh  prints one JSON sample (draw + leaf cgroup usage)
Model.js             (modify) new pure functions below
tests/model.test.js, tests/scripts.test.sh, tests/fixtures/cgroup/  (fake cgroup tree)
manifest.json (version 0.2.0), qmldir (register new components), CHANGELOG.md, README.md
```

---

### Task 1: Theme palette

**Files:** Create `ThemePalette.qml`. Modify `Model.js`, `tests/model.test.js`, `qmldir`.

**Interfaces:**
- Produces:
  - `Model.parseThemeColors(text) -> {[key]: "#rrggbb"}`
    - Parses `key = "#hex"` lines from TOML: 3/6/8-digit hex, quotes required, comments and other lines ignored.
    - Lower-cases keys.
  - `Model.semanticColors(palette, fallback) -> {good, warn, neutral, power, text, muted}`
    - `fallback` is `{accent, urgent, foreground, muted}`, usually from `Commons.Color`.
    - **good:** `palette.green`, else `fallback.accent`
    - **warn:** `palette.red`, else `fallback.urgent`
    - **neutral:** `palette.accent`, else `fallback.accent`
    - **power:** `palette.cyan`, else `palette.blue`, else `fallback.accent`
    - **text:** `palette.foreground`, else `fallback.foreground`
    - **muted:** `palette.muted`, else `fallback.muted`
  - `ThemePalette.qml`: an `Item` with readonly `color` properties `good warn neutral power text muted`.
    - It reads the file with `FileView { watchChanges: true }`.
    - It exposes `function reload()`, which the Panel calls on open because a theme swap may replace the directory.

- [ ] **Step 1: Write failing tests**
  - `parseThemeColors` on the owner's real file (copy it to `tests/fixtures/colors.toml`; it holds no personal data) gives `green === "#87a9b0"` and `red === "#c38b7b"`.
  - Comments and junk lines are ignored, and `parseThemeColors("")` gives `{}`.
  - `semanticColors({}, {accent:"#aaaaaa", urgent:"#bb0000", foreground:"#ffffff", muted:"#777777"})` gives good `#aaaaaa`, warn `#bb0000`, power `#aaaaaa`.
  - A palette with `blue` but no `cyan` gives `power === blue`.
- [ ] **Step 2: Run** `node --test tests/`. Expected: FAIL.
- [ ] **Step 3: Implement** the Model functions and `ThemePalette.qml`, and register `ThemePalette` in `qmldir`.
- [ ] **Step 4: Run.** Expected: PASS. Run `omarchy plugin validate .`.
- [ ] **Step 5: Commit** `feat: theme palette with semantic colours`.

### Task 2: Power sampling and app ranking logic

**Files:** Create `bin/power-sample.sh` and `tests/fixtures/cgroup/` (a fake tree). Modify `Model.js`, `tests/model.test.js`, `tests/scripts.test.sh`.

**Interfaces:**
- Produces:
  - **`bin/power-sample.sh`** prints one JSON object and always exits 0:
    `{"t":epochMs, "ac":bool, "status":string|null, "drawW":number|null, "groups":[{"path":string, "usec":int}]}`
    - **Draw:** `drawW` is `power_now`/1e6, else `current_now`×`voltage_now`/1e12. It is `null` unless the status is `Discharging`.
    - **Overrides:** `BATTERY_SYSFS` (default `/sys/class/power_supply`) and `CGROUP_ROOT` (default `/sys/fs/cgroup`).
    - **Groups:** every **leaf** cgroup directory that has a `cpu.stat` under these trees:
      - `$CGROUP_ROOT/user.slice/user-$UID.slice` (includes `session-*.scope` and everything under `user@$UID.service`)
      - `$CGROUP_ROOT/system.slice`
    - A **leaf** is a directory with no subdirectory containing `cgroup.procs`.
    - `usec` is the `usage_usec` line. `path` is relative to `CGROUP_ROOT`.
  - `Model.parsePowerSample(text) -> sample|null` returns null on bad JSON.
  - `Model.unitLabel(path) -> string`, taking the last path segment:
    - **Unescaping:** systemd `\xNN` escapes are decoded first.
    - **`app-<…>-<name>-<hex>.scope`:** `<name>`, using the fixed map below.
    - **`app-<reverse.dns.Name>-<n>.scope`:** the last DNS label (`org.chromium.Chromium` → `Chromium`).
    - **`wayland-wm@hyprland.desktop.service`:** `Desktop`.
    - **`session-<n>.scope`:** `Login session`.
    - **Otherwise:** strip a leading `app-`, any `@…` suffix, `.service`/`.scope`/`.slice`, then capitalise the first letter.
    - **Fixed map:** `brave`→`Brave`, `xdg-terminal-exec`→`Terminal`, `code`→`Code`, `zen`→`Zen`, `firefox`→`Firefox`, `chromium`→`Chromium`, `obsidian`→`Obsidian`, `spotify`→`Spotify`, `nautilus`→`Files`.
    - Groups whose labels are equal are merged when shares are computed (Brave runs in two scopes).
  - `Model.appShares(samples) -> [{label, share}]`, sorted descending.
    - `samples` is the last ≤ 6 samples. The window is first → last.
    - Each path's delta is `last.usec - first.usec`. A path missing from either end, or with a negative delta, is skipped.
    - Deltas are summed per label. `share = delta / total`. If `total <= 0` the result is `[]`.
  - `Model.powerRows(shares, sample, n) -> {mode:"watts"|"cpu"|"measuring", rows:[{label, value:number, unit:"W"|"%", fraction:0..1}]}`
    - **measuring:** fewer than 2 samples, or `shares` empty.
    - **watts:** `sample.drawW` is a number. `value = share × drawW`, rounded to 0.1.
    - **cpu:** otherwise. `value = share × 100`, rounded to 1.
    - `fraction` is the share relative to the top row (top = 1). At most `n` rows.
  - `Model.appendDrawPoint(buffer, sample, nowMs) -> buffer`
    - Returns a new array of `{t, w, gapBefore:bool}`.
    - A point is appended only when `drawW` is a number.
    - `gapBefore` is true when the previous point is more than 10000 ms older.
    - Points older than `nowMs - 300000` are dropped, and the buffer is capped at 150.

- [ ] **Step 1: Write failing tests.**
  - **`tests/fixtures/cgroup`** has `user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-brave-1a2b.scope/{cgroup.procs,cpu.stat}`, `.../app.slice/app-org.chromium.Chromium-42.scope/…`, `.../session.slice/wayland-wm@hyprland.desktop.service/…`, and `system.slice/NetworkManager.service/…`. Give `app-graphical.slice` itself a `cpu.stat` and `cgroup.procs`; it must be excluded as a non-leaf.
  - **Script tests** (with `UID=1000` forced via env or path):
    - `CGROUP_ROOT=fixture BATTERY_SYSFS=tests/fixtures/sysfs/dell bin/power-sample.sh | jq -e '(.groups|length)==4 and (.groups|map(.path)|any(test("app-graphical.slice$"))|not)'`
    - the dell fixture (Discharging, `current_now`/`voltage_now` absent) gives `drawW == null`
    - a temp copy with `current_now` 531000 and `voltage_now` 12183000 gives `drawW` ≈ 6.47
    - a copy with status `Charging` gives `drawW == null`
  - **Model tests:**
    - `unitLabel` cases:
      - `…/app-Hyprland-brave-1a2b.scope` → `Brave`
      - `app-Hyprland-xdg\x2dterminal\x2dexec-509c.scope` → `Terminal`
      - `app-org.chromium.Chromium-42.scope` → `Chromium`
      - `wayland-wm@hyprland.desktop.service` → `Desktop`
      - `bt-agent.service` → `Bt-agent`
      - `dropbox@autostart.service` → `Dropbox`
    - `appShares`:
      - Two Brave scopes merge.
      - A path missing in the last sample is skipped.
      - A negative delta is skipped.
      - An all-zero window gives `[]`.
    - `powerRows`:
      - watts mode with drawW 6.5 and shares .5/.3/.2 → values 3.3/2.0/1.3 (rounded), fractions 1/.6/.4
      - drawW null → cpu mode with % values
      - one sample → measuring
    - `appendDrawPoint`:
      - a 12 s gap sets `gapBefore`
      - a point older than 5 min is dropped
      - the cap is 150
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** the script (bash + `find` + jq; no root needed) and the Model functions.
- [ ] **Step 4: Run.** Expected: PASS. Run once against the real machine: `bin/power-sample.sh | jq '.drawW, (.groups|length)'` should give a number on battery and more than 5 groups.
- [ ] **Step 5: Commit** `feat: power sampling and per-app share model`.

### Task 3: Mode tiles and battery gauge

**Files:** Create `ModeTiles.qml` and `BatteryGauge.qml`. Modify `Model.js`, `tests/model.test.js`, `Panel.qml` (the CHARGING section body only), `qmldir`.

**Interfaces:**
- Consumes: `ThemePalette` (Task 1); the existing Panel properties `snapshot`, `helperPresent`, `runHelper`, `commitLimits`, `actionMessage`, `helperBusy`, or their real names in `Panel.qml`.
- Produces:
  - `Model.modeTone(mode) -> "good"|"warn"|"neutral"`: `Custom`→good, `Fast`→warn, everything else→neutral.
  - `Model.modeIcon(mode) -> string`: Trickle `󰂃`, Fast `󱐋`, Standard `󰁹`, Adaptive `󰂏`, Custom `󰢝`, anything else `󰂄`.
  - `Model.clampHandle(which, value, start, end) -> int`, where `which` is `"start"` or `"end"`.
    - It rounds `value`.
    - Start is clamped to `[1, end-1]`. End is clamped to `[start+1, 100]`.
  - `ModeTiles.qml`
    - props: `modes`, `activeMode`, `palette`, `enabled`, `opened`
    - signal: `picked(string mode)`
    - Layout: one row for 5 or fewer modes, otherwise wrap.
    - The active tile has a breathing glow in `palette[Model.modeTone(mode)]`. It runs only while opened, has a 2.4–3 s period and a low alpha.
    - Switching tiles is a 250 ms colour/opacity cross-fade.
  - `BatteryGauge.qml`
    - props: `percent`, `start`, `end`, `charging:bool`, `editable:bool`, `palette`, `opened`
    - signal: `committed(int start, int end)`
    - Draws a battery outline (body plus nub), the fill at `percent`, and a faint safe band between the handles.
    - A shimmer sweeps across the fill when `charging && opened`.
    - The handles show their numbers and lift 1–2 px on hover.
    - Dragging uses `clampHandle` live. `committed` is emitted once on release, only if `editable` and the value changed.
    - A `MouseArea`/`WheelHandler` swallows wheel events, so they never commit.
    - When `!editable`, the handles dim to ~0.4 opacity, can't be dragged, and show the caption "Applies in Custom mode".

- [ ] **Step 1: Write failing tests** for `modeTone`, `modeIcon` and `clampHandle`:
  - `clampHandle("start", 95, 50, 90) === 89`
  - `clampHandle("end", 40, 50, 90) === 51`
  - `clampHandle("end", 120, 50, 90) === 100`
  - `clampHandle("start", 0, 50, 90) === 1`
  - `clampHandle("start", 60.6, 50, 90) === 61`
- [ ] **Step 2: Run.** Expected: FAIL. **Step 3: Implement** the Model functions. **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Implement the components and wire them into CHARGING**
  - Replace the mode buttons and limit sliders. Tile `picked(m)` → `runHelper(["mode", m])`.
  - Gauge `committed(s, e)` → the existing commit path (`commitLimits` or equivalent), which keeps the one-call-at-a-time and `chosenMode` rules.
  - Keep the helper-missing message and the Saved/Not changed feedback, restyled with `palette.muted` text and a fade in and out.
- [ ] **Step 6: Install and check**
  - Run `./dev-install.sh` and check the log (no errors).
  - Open the panel via `omarchy-shell omarchy.power toggle` and take a screenshot to `.superpowers/`. Confirm the tiles and gauge render in theme colours, then delete the screenshot.
- [ ] **Step 7: Commit** `feat: mode tiles and battery gauge for charging controls`.

### Task 4: POWER USE section

**Files:** Create `PowerUse.qml`. Modify `Panel.qml` (insert between HEALTH and POWER PROFILE) and `qmldir`.

**Interfaces:**
- Consumes: `bin/power-sample.sh`, `Model.parsePowerSample`, `appShares`, `powerRows`, `appendDrawPoint` (Task 2), and `ThemePalette` (Task 1).
- Produces: `PowerUse.qml` with props `opened`, `palette`, `pluginDir`.
  - It owns `property var samples: []` (last 6), `property var drawBuffer: []`, and a `Timer { interval: 2000; running: opened; repeat: true; triggeredOnStart: true }` that runs the script, guarded so only one run is in flight.
  - These properties persist while the shell runs, because the component lives as long as the panel and is never re-created on open.
  - It shows the header "POWER USE".
  - **Draw line:** on battery, "Draw now" with the latest `drawW` ("6.5 W", in `palette.power`). Otherwise "Plugged in", in muted text.
  - **Sparkline:** a Canvas of `drawBuffer`. It breaks the line where `gapBefore` is set, is drawn in `palette.power` at ~0.8 alpha, and is hidden (height animates to 0) in cpu mode.
  - **Rows:** up to 3 from `powerRows(appShares(samples), latestSample, 3)`. Each row shows the label, the value with its unit ("~2.1 W" or "34%"), and a bar.
    - Bar width = `fraction`.
    - Row colours by rank: `warn`, `neutral`, `power`.
    - Widths animate (300 ms OutCubic). Rows reorder with a 250 ms y animation; use a `ListView` with `move`/`displaced` transitions, or a Repeater with `Behavior on y`.
  - **Measuring state:** "measuring…" in muted text.
  - **Caption:** watts mode: "Estimated from CPU share of the measured draw". cpu mode: "Plugged in · watts shown on battery".

- [ ] **Step 1: Implement `PowerUse.qml`** and insert it into `Panel.qml`.
- [ ] **Step 2: Install and check**
  - Run `./dev-install.sh` and check the log.
  - Open the panel, wait 6 s, and screenshot to `.superpowers/`. Confirm "Draw now" shows a number on battery, 3 rows with W, and a sparkline.
  - Close the panel, then check `pgrep -fc power-sample.sh` is 0 a few seconds later (no sampling while closed).
  - Delete the screenshot.
- [ ] **Step 3: Commit** `feat: power use section with top apps`.

### Task 5: Whole-panel restyle and motion

**Files:** Modify `Panel.qml`, `HealthChart.qml`, `Model.js`, `tests/model.test.js`.

**Interfaces:**
- Consumes: `ThemePalette`; the existing `chartPoints`, `wearRate`, `projectFloorDate`.
- Produces: `Model.projectionPoint(chart, rate, floor, now, rangeKey) -> {x, y}|null`.
  - It is the end of a straight line from the latest point at `rate` (health %/month) to `min(the floor-crossing date, the domain end)`, in the same 0..1 coordinates as `chartPoints`.
  - It returns null when the rate is null or ≥ 0, or when there are no points.

Changes, matching `docs/superpowers/specs/mockups/full-panel.html`:
- **Header:**
  - The big percentage counts up from 0 on open (600–800 ms OutCubic) and has a subtle text gradient from `text` to `good` (Text with a `LinearGradient`/`ShaderEffect`, or a layered approach; if gradients aren't available without extra modules, a solid `text` colour with the count-up is acceptable).
  - The charge bar has a horizontal gradient `warn` → `neutral` → `good` and grows from 0 on open.
  - The stats become one compact line.
  - The phrases and the charging pulse stay.
- **Alert banner:**
  - A 3 px left edge in `warn`, background `warn` at ~0.08 alpha, slide-in (fade plus 6 px y, 250 ms).
  - The Fix button border and text are `warn`, with a gentle background pulse (2.5–3 s, only while opened).
  - The degradation alert has the same style, with no Fix button.
- **HEALTH:**
  - The rows are replaced by 3 stat cards:
    - Health % in `neutral`
    - Wear %/mo with "est." on the estimate basis
    - Reaches 80% as "Mon YY", in `good` (or `warn` when the degradation alert is active)
  - Cards use a background of `text` at ~0.04 alpha.
  - The caption line reads "65 cycles · 33.6 °C · <range> ▸".
- **HealthChart:**
  - an area fill under the line (`neutral`, vertical alpha gradient .35 → 0)
  - the line draws itself on open (animate a 0..1 progress, 700 ms)
  - the latest point is filled and pulses (radius ±1.5, 2.4 s, only while opened); the seed stays hollow
  - a dashed projection to `projectionPoint` at 0.5 alpha
  - the 80% floor line is dashed `warn`; the warranty marker stays (muted, dashed)
  - clicking still cycles the range
- **POWER PROFILE:** the active button gets a `neutral` border and a ~0.1 tint.
- **Open stagger:** each section's container fades from 0 and rises 4 px, with a 40 ms stagger, on every open.

- [ ] **Step 1: Write failing tests** for `projectionPoint`:
  - Latest point (x 0.6, y for 90.3) at −1.0%/mo → a point with x > 0.6 and y further down (toward the floor) than the latest point.
  - Rate null → null.
  - Rate +0.1 → null.
  - The x is clamped to ≤ 1.
- [ ] **Step 2: Run.** Expected: FAIL. **Step 3: Implement.** **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Implement the restyle and motion**
  - Keep the existing parity behaviours, IPC and keyboard navigation untouched.
  - Run `./dev-install.sh` and check the log.
  - Open the panel and take 2 screenshots, at about 100 ms and about 1.5 s after opening, to see the animation start and the settled state.
  - Do NOT switch the owner's theme. Instead, `grep -nE '#[0-9a-fA-F]{6}' *.qml` must find no colour literals. All colours must go through `palette.*` / `Commons.Color`.
  - Delete the screenshots.
- [ ] **Step 6: Commit** `feat: theme-coloured restyle and subtle motion across the panel`.

### Task 6: Release docs

**Files:** Modify `manifest.json` (`version` "0.2.0"), `CHANGELOG.md` (0.2.0 entry dated 2026-10-24), and `README.md`.

README changes: describe the POWER USE section and that it is an estimate, the mode tiles and gauge, and that colours follow the theme. Every claim must match the code.

- [ ] **Step 1: Update the docs.** Run `node --test tests/ && bash tests/scripts.test.sh && omarchy plugin validate .`. Expected: all pass.
- [ ] **Step 2: Commit** `docs: 0.2.0 changelog and README`.
