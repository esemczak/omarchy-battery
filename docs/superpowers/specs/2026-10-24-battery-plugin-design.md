# omarchy-battery — design

Date: 2026-10-24
Owner: esemczak
Status: draft for approval

## Why

A Dell laptop, under 1 year old and still under warranty, is at **90.3% of
design capacity after 65 cycles**. That's more wear than normal for its age.

The likely cause is a setting nobody could see. A 50–90% charge limit is
configured in sysfs, but `charge_types` is `Fast`, and the Dell firmware only
applies the limits in `Custom` mode. So the battery charges to 100% at high
current. The stock Omarchy battery widget (`omarchy.power`) shows
"Charge limit 50–90%" without knowing the limit isn't being applied. It also
can't change the charging mode, and it keeps no history, so you can't tell
whether wear is speeding up before the warranty runs out.

The owner wants one bar widget that:

- A) manages the charging mode and limits at a finer grain than the BIOS, and
- B) monitors and audits wear, with stats, a graph and alerts,

and that **replaces `omarchy.power` without losing any of its features**.

## Goals

1. Drop-in replacement for the `omarchy.power` bar widget, keeping every
   current feature (listed in "Parity" below).
2. Change the charging mode and the start/end limits from the panel.
3. Record battery health over time and show it: current health %, wear rate
   per month, and a capacity graph with an 80% warranty line.
4. Two new alerts, shown in the panel and as desktop notifications:
   - **Limit ignored:** a limit is configured but not applied (wrong mode), or
     the battery is charging past the configured end limit.
   - **Fast degradation:** at the measured wear rate, health would drop below
     80% before the warranty ends (a configurable date).

## Non-goals

- Replacing the background `omarchy.battery` service (10% low-battery
  notification, `battery-low` hook, automatic power-profile switch on plug or
  unplug). It stays as is and keeps running.
- Supporting non-Dell charge controls beyond what the generic sysfs
  `charge_control_*` files allow. Other laptops should get a reasonable
  fallback, not tailored features.
- Multiple batteries. Use the first `BAT*`, like the stock script does.
- Upstreaming to Omarchy. This is a personal plugin, published on GitHub like
  `omarchy-monitor-layout`.

## Anti-goals (a failure even if it works)

- Any loss of a current `omarchy.power` behaviour, including the right-click
  percentage toggle and the "Battery Percentage" menu entry, which calls
  `omarchy-shell omarchy.power togglePercentage`.
- Writing battery settings without the owner's explicit action and password.
  No silent privileged writes, and no passwordless sudo/polkit rule. **The
  owner chose to type the password each time.**
- A privileged helper that could be edited without root (for example, running
  a script under `~/.config` as root via pkexec).
- Noisy alerts: the same alert repeating on every check, or a degradation alert
  driven by a single noisy reading.

## Parity: what `omarchy.power` does today (must keep)

Source: `/usr/share/omarchy/shell/plugins/panels/power/{Panel.qml,Model.js}`
plus `omarchy-battery-status --shell`, `omarchy-powerprofiles-list
--active-state`, `omarchy-powerprofiles-set`.

- **Bar button:** battery icon that changes with level and state; optional
  "NN% icon" text when `showPercentage` is true (the owner has it on).
  Right-click toggles the percentage and saves it via
  `shell.updateEntryInline`. Left-click opens the panel. Hidden with zero size
  when there's no battery. Panels on vertical bars show the icon only.
- **IPC target `omarchy.power`:** `open`, `close`, `show`, `hide`, `toggle`,
  `togglePercentage`.
- **Panel header:** icon, "Battery" title, rotating phrase (charging and
  on-battery phrase lists, 2.8 s fade swap), "Fully charged" state, and a big
  percentage.
- **Charge bar:** pulses while charging.
- **Stats:** battery size (Wh), charge cycles, time left / time to full, and
  rate in W. When the limit is holding, it shows "Charge limit" and "Holding"
  instead. The last good data is kept across empty refreshes.
- **Power profile row:** one button per profile from
  `omarchy-powerprofiles-list`, with arrow/Enter keyboard cursor, hover
  selection, and Tab to switch panels.
- Refreshes every 5 s while open.

Port this as directly as possible, reusing the stock `Model.js` logic and the
`omarchy-*` helper commands rather than reimplementing them.

## What gets built

### Layout (chosen: option A, one long panel)

Top to bottom:

1. **Header, charge bar and stats:** as today (parity above).
2. **Alert banner:** shown only while an alert is active. One line of text and
   a single action button. "Limit ignored (mode: Fast)" gets a **Fix** button
   that switches the mode to Custom. Degradation shows the projected date it
   crosses 80%, with no action button.
3. **CHARGING section:**
   - one button per mode in `charge_types`; the active mode is the one in
     `[brackets]` on this machine (`Trickle [Fast] Standard Adaptive Custom`).
   - start and end limit controls, shown only when the hardware exposes
     `charge_control_*`, and editable only in Custom mode. In other modes they
     show greyed out with "applies in Custom mode".
   - Changes take effect on an explicit action. Each mode click or limit
     change triggers one password prompt.
4. **HEALTH section:** health % (`charge_full / charge_full_design`, or the
   energy pair where present), wear rate in %/month, projected 80% date, cycle
   count, and temperature. A small line graph of health over time with a
   dashed 80% line and a warranty-end marker. Clicking the graph cycles its
   range: 3 months → 1 year → all.
5. **POWER PROFILE:** as today.

The bar icon gets a small warning mark while an alert is active (builder picks
the exact glyph or colour from the theme).

### Privileged writes

- A root-owned helper (installed to `/usr/local/bin/`, owned by root, mode
  0755) that accepts only: set mode to one of the values listed in
  `charge_types`, and set start/end to integers within kernel-accepted bounds
  (start < end). It writes to `/sys/class/power_supply/BAT*/…` only, and
  validates every argument against the hardware's own allowed list.
- The panel calls it via `pkexec`, so Omarchy's polkit agent shows the
  password prompt. A polkit action file with `auth_admin` (never `yes`) is
  optional, for a nicer prompt message.
- Installing the helper takes one `sudo` step, done by the owner from a
  terminal (`install.sh` or a README command). The plugin detects when the
  helper is missing and shows "Install battery helper" instead of the
  controls.
- **Persistence: unverified.** On Dell, `charge_types` and the thresholds are
  believed to map to BIOS settings that survive reboot. The builder must
  verify this with a reboot test. If they don't survive, add a root systemd
  oneshot that reapplies the saved settings at boot, with the setting stored
  in a root-owned file. Only add it if needed.

### History (sampler)

- **Where it runs:** a `service` entry point in the same plugin, so no
  separate systemd unit is needed. It runs whenever the shell is running,
  which is always on this laptop.
- **When it samples:** on startup, every 6 hours, and when power is plugged or
  unplugged. It always takes a sample if more than 6 hours have passed since
  the last one.
- **What it records, one JSON line per sample:** timestamp, `charge_full`,
  `charge_full_design` (or the energy equivalents), cycle count, mode, start
  and end limits, percentage, status, temperature, and AC online.
- **Where it's stored:** `~/.local/state/esemczak-battery/history.jsonl`,
  append-only, kept forever (a few hundred KB per year).
- **Seed:** on first run, if the history is empty, write one synthetic point
  marked `"seed": true` at the battery's manufacture date at 100% health. The
  graph and the wear rate can then use it until real data piles up. Mark it
  visibly as an estimate in the graph.

### Alerts

- **Limit ignored**
  - **Fires when** any of these hold:
    - a limit below 100% is configured, the mode isn't Custom, **and** the
      owner didn't pick that mode in the panel. The panel records the last
      mode it set in `~/.local/state/esemczak-battery/state.json`. If the
      live mode equals that recorded mode, it was intentional: no alert. If
      the mode differs from the recorded one, or nothing is recorded yet
      (today's case: Fast with no recorded choice), the alert fires. This
      catches BIOS resets and changes made elsewhere. *(Owner's decision.)*
    - while on AC with mode Custom, the battery is actually **charging** (status
      Charging and the percentage rising) above the end limit + 3 points, on two
      consecutive alert checks. Holding above the limit after switching to
      Custom (status "Not charging") is correct behaviour and doesn't count.
      *(Builder-check call by Claude.)*
  - **Check cadence:** the service runs alert checks every 5 minutes and on
    every plug or unplug, separately from the 6-hour history samples.
    *(Builder-check call by Claude.)*
  - **How it notifies:** the panel banner, plus a desktop notification via
    `omarchy-notification-send` once per occurrence. It re-arms after the
    condition clears.
- **Fast degradation**
  - **How the wear rate is calculated:** a robust linear fit (median-filtered
    daily values) over the last 90 days of real samples. With less than 30
    days of real data, fall back to the seed→now slope, labelled "estimate".
  - **Fires when:** the projected date of reaching 80% falls before the
    warranty end date.
  - **How it notifies:** at most one notification per 7 days; the banner
    stays while the condition holds. While the rate is still the seed-based
    "estimate" (under 30 days of real data), it shows the banner only and
    sends no desktop notification. *(Builder-check call by Claude.)*
- **Alert settings** live in the widget's `shell.json` entry: `warrantyEnd`
  (default `"2027-04-30"`), `healthFloor` (default 80), `alerts.limitIgnored`
  and `alerts.degradation` (both default true).

### Replacing the stock widget

- Plugin id `esemczak.battery`. Repo at `~/Work/omarchy-battery`, structured
  like `~/Work/omarchy-monitor-layout`: `manifest.json`, `Panel.qml`,
  `Model.js`, `Service.qml`, `bin/`, `tests/`, `dev-install.sh`, README,
  CHANGELOG, MIT licence.
- Set `"omarchy": { "clonedFrom": "omarchy.power" }` in the manifest so the
  shell routes the `omarchy.power` IPC target (and with it the menu's "Battery
  Percentage" entry) to this plugin, the same way `omarchy plugin clone` does.
  The builder must verify that the shell honours `clonedFrom` for a plugin
  that wasn't created by `clone`. If it doesn't, find another way to keep that
  menu entry working.
- In `~/.config/omarchy/shell.json`, replace `{"id": "omarchy.power",
  "showPercentage": true}` with `{"id": "esemczak.battery",
  "showPercentage": true}` in the same position (the last item on the right).

## Constraints

- Omarchy 4.x shell (Quickshell). Never edit `/usr/share/omarchy/`; reading it
  is fine.
- Dev loop: `dev-install.sh` copies into `~/.config/omarchy/plugins/<id>/`.
  Symlinks are rejected. Copy monitor-layout's script, which stops the shell
  before swapping files because live reloads have crashed Quickshell.
- `omarchy plugin validate` must pass.
- No new packages. bash, jq, upower and pkexec are already present.
- Model logic stays in plain JS with node tests (`tests/model.test.js`), as in
  monitor-layout. That covers: parsing `charge_types`, alert decisions, the
  wear-rate fit, and the projection.

## Left to the builder

- Exact visuals (slider vs stepper for limits, glyphs, colours), as long as
  they match the stock panel's style components (`Button`,
  `PanelSectionHeader`, `PanelSeparator`, `Style.*`).
- Graph drawing technique (Canvas or Shape).
- Exact helper and polkit file names.
- Whether the history file also keeps a compact daily rollup.
