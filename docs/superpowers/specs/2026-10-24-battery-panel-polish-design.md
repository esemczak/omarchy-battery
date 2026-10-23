# omarchy-battery: panel polish and power-use section (design)

Date: 2026-10-24
Builds on: `2026-10-24-battery-plugin-design.md` (v0.1.0, shipped)
Status: draft for approval

## Why

v0.1.0 works, but the panel looks bare. The CHARGING section is a row of
loosely aligned plain buttons plus two sliders, and nothing uses colour or
motion. The owner wants the panel to feel alive, with colour and subtle
animation. They also want a small section showing which apps cost the most
battery.

## Goals

1. Restyle the whole panel in the direction the owner picked (mockup "B,
   carried through"), using only colours from the active Omarchy theme.
2. Replace the CHARGING mode buttons and limit sliders with **mode tiles** and
   a **battery gauge with draggable limit handles**.
3. Add a **POWER USE** section: the measured battery draw now, a short draw
   graph, and the **top 3 apps** with estimated watts.
4. Add subtle motion throughout, following the motion list below.

## Non-goals

- Exact per-app power. Linux has no per-process power meter. RAPL energy
  counters are root-only on this kernel and only cover the whole CPU package.
  `powertop` is not installed and only estimates anyway. **The owner accepted
  estimates.**
- New admin or root components. Power use is measured as the normal user.
- Changes to the alert logic, the history format, the helper or the service
  behaviour. This is a presentation change, plus one read-only data source.

## Anti-goals

- **Hard-coded colours.** Everything must follow theme changes (`omarchy theme
  set …`) without a restart, as the stock panels do.
- **Distracting motion.** No bouncing, no flashing, and no motion that runs
  while the panel is closed. Looping effects must be slow and low-contrast.
- **Battery cost.** The widget must not drain the battery it measures. All
  sampling for POWER USE runs only while the panel is open.
- **Lost parity or controls.** Everything in v0.1.0 keeps working: the
  password prompt per change, the "applies in Custom mode" rule, keyboard
  navigation for profiles, IPC, and the bar icon.

## What gets built

### Colours

- Every colour comes from the shell's theme colours (`Commons.Color` and its
  palette lookups for accent/red/green/cyan/muted, or the bar foreground and
  background), with alpha for tints.
- **Semantic mapping:**
  - **good / within limits:** green
  - **warning / Fast / limit ignored:** red
  - **neutral highlight:** accent
  - **power / draw:** cyan
  - **secondary text:** foreground at reduced opacity
- If a theme lacks a colour, fall back to the accent or the foreground. The
  panel must never render as invisible or black-on-black.

### Panel, top to bottom (see `docs/superpowers/specs/mockups/full-panel.html`)

1. **Header**
   - The big percentage has a subtle gradient (foreground to green).
   - The charge bar is a gradient from red at low charge to green at high.
   - The stats sit on one compact line: Wh, cycles, time left/to full, W.
   - The rotating phrases stay.
2. **Alert banner**
   - A red left edge with a faint red tint.
   - It slides in when it appears.
   - The Fix button pulses gently every few seconds.
   - The degradation alert uses the same style.
3. **CHARGING**
   - **Mode tiles:** a grid of icon and label tiles, one per supported mode.
     - The active tile has a slow breathing glow in its semantic colour:
       Custom is green, Fast is red, the rest use the accent.
     - Switching cross-fades the glow.
     - Clicking a tile runs the existing helper flow: one password prompt,
       record `chosenMode` only on success.
   - **Battery gauge:** a battery-shaped outline spanning the full width.
     - The fill shows the current charge.
     - A faint band marks the area between the limits.
     - A shimmer runs across the fill only while charging.
     - Two **limit handles** (start and end) can be dragged along the gauge
       and show their numbers.
     - Releasing a handle commits through the helper, with the existing
       ordering and clamping rules.
     - Mouse-wheel over the gauge never commits.
     - Outside Custom mode the handles dim, with the caption "Applies in
       Custom mode".
   - The helper-missing message and the "Saved"/"Not changed" feedback stay,
     restyled.
4. **HEALTH**
   - Three stat cards: Health %, Wear %/mo (with "est." on the estimate
     basis), and the date health reaches 80%.
   - The chart is a filled area under the line.
     - The line draws itself when the panel opens.
     - The latest point pulses softly.
     - The seed point stays hollow.
     - A dashed projection runs from the latest point at the current wear
       rate towards the 80% line.
     - The 80% line is dashed red.
     - The warranty marker stays.
     - Click still cycles 3m/1y/all.
   - Cycles and temperature move to a small caption line.
5. **POWER USE** (new)
   - "Draw now" in watts, measured from the battery.
     - Use `power_now` if present, else `current_now` × `voltage_now`.
     - **On the charger** (owner's decision): there is no reliable system
       draw. Show "Plugged in" where the watts would be. Hide the sparkline
       or show it paused. The top 3 rows stay, but show **% of CPU** instead
       of watts, with the caption "Plugged in · watts shown on battery".
   - A sparkline of the draw, sampled every 2 s while open, keeping the last
     ~5 minutes in memory only.
   - The top 3 apps, each with an estimated wattage and a bar.
     - Bars grow in, and rows re-rank with a smooth reorder.
     - The caption reads "Estimated from CPU share of the measured draw".
6. **POWER PROFILE:** as v0.1.0. The active profile gets the accent tint.

### Estimating per-app power

- **Grouping:** each multi-process app (Brave, Code and so on) must count as
  one entry with a readable name.
  - On this machine, apps run in systemd user scopes such as
    `app-Hyprland-brave-<id>.scope` and `app-org.chromium.Chromium-<id>.scope`,
    under `app.slice`.
  - Their `cpu.stat` `usage_usec` is readable without root and is the
    suggested source.
  - Per-PID `/proc/<pid>/stat` is the fallback.
- **The estimate:** sample twice over the window and take each group's share
  of the total CPU time used in the window. Multiply that share by the
  measured draw to get the estimated watts.
- **Scope:** rank the user's app scopes and system services together, and show
  the top 3.
- **When it runs:** only while the panel is open. The first figures appear
  after the first window, so show a short "measuring…" state until then.
- **What's left to the builder:** the exact scope-name-to-label mapping, and
  how terminals are labelled. A terminal scope also contains child commands;
  "Terminal" is acceptable.

### Motion list (all subtle, all only while the panel is open)

- **Opening the panel:**
  - Sections fade in and rise about 4 px, staggered about 40 ms apart.
  - The big percentage counts up.
  - The charge bar grows from 0.
- **Banner:** slides in, and the Fix button pulses gently.
- **Mode tiles:** the active tile breathes slowly; switching cross-fades.
- **Gauge:** the fill shimmers only while charging; handles lift slightly on
  hover.
- **Health chart:** the line draws on open, the latest point pulses softly,
  and the projection is dashed.
- **Power bars:** grow in, then reorder smoothly.
- **Timing:** eases of 150–300 ms (draw-on and count-up may take up to about
  800 ms). Easing is OutCubic or InOutSine; no bounce or elastic curves.

## Constraints

- Same plugin, repo and dev loop as v0.1.0. Use `dev-install.sh` and keep
  `omarchy plugin validate` passing. Never edit `/usr/share/omarchy`.
- Logic that can be pure (CPU-share maths, name mapping, gradient stops,
  projection points) lives in `Model.js` with `node --test` coverage.
- Work on a new branch off `master`. Nothing is pushed to the public repo
  until the owner asks.
- No screenshots are committed. Screenshots taken for verification capture
  the owner's screen and must be deleted afterwards.

## Left to the builder

- QML structure: new components such as `ModeTiles.qml`, `BatteryGauge.qml`
  and `PowerUse.qml` are encouraged so `Panel.qml` doesn't grow further.
- The exact durations within the ranges above, the icon glyphs, the tile grid
  shape for 5 modes, and gradient details.
- How the scope cpu.stat reads are batched: one small script per sample is
  fine.

## Builder-check calls (made by Claude; owner may override)

- **CPU denominator and scope:**
  - Sample **leaf** cgroups only, never a parent together with its children,
    so nothing is double counted. Cover user `app.slice` (including nested
    `app-graphical.slice` scopes), user `session.slice` and `system.slice`.
  - The compositor and shell (Hyprland, quickshell) are eligible: they really
    do use power.
  - Share = a group's `usage_usec` delta / the sum of the deltas of all
    sampled groups. That is share of busy time, normalised to 100%, which is
    what the owner agreed to: "split the measured total by CPU share".
  - Estimated W = share × measured draw.
  - Work outside any cgroup leaf (kernel threads, IRQs) is not shown.
- **Windows:**
  - The draw sparkline samples every 2 s.
  - App shares use a rolling ~10 s window (the last 5 samples), which keeps
    ranking stable so reorders stay rare and smooth.
  - "measuring…" shows until two samples exist (about 2–4 s).
  - POWER USE has its own 2 s timer, which runs only while the panel is open.
- **Where state lives:**
  - The sampler state and the ~5 min ring buffer live in the POWER USE
    component and survive panel close/open for the shell session.
  - A gap longer than 10 s breaks the sparkline line instead of joining it.
  - A new `bin/power-sample.sh` (one call per sample) is allowed, with tests
    in `tests/scripts.test.sh` against a fake cgroup and power_supply tree.
- **Gauge handles:**
  - Rules are the helper's: 1 ≤ start < end ≤ 100.
  - Handles cannot cross; each stops 1 short of the other.
  - Outside Custom mode the handles are dimmed and **not draggable**, as the
    v0.1.0 sliders were disabled.
  - Mouse-wheel never commits.
- **Labels:**
  - Known app scopes map to readable names (brave → Brave, `xdg-terminal-exec`
    → Terminal, chromium → Chromium, code → Code, …), with systemd unescaping.
  - Other units show a humanised unit name: strip `app-`, `@autostart`,
    `.service` and `.scope`, and capitalise.
- **Release:** the version goes to 0.2.0 with a CHANGELOG entry. Any new QML
  components are registered in `qmldir` if the shell needs them; the builder
  verifies this with `omarchy plugin validate` and a live install.
