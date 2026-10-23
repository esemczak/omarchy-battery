# omarchy-battery

A drop-in replacement for the stock Omarchy battery widget (`omarchy.power`)
that adds **charging controls**, a **battery health history and graph**, and
**alerts**, all from the same bar icon and panel.

Everything the stock widget does is kept: the bar glyph, the hero status, the
battery details, the power-profile picker and its keyboard navigation. The new
parts sit in the same panel below it.

## Features

- **Charging controls** — pick a charge mode from a row of tiles. A battery
  gauge shows the charge level and the start and end limits; in Custom mode
  drag the two handles to set them (for example 50 to 90%). The gauge is
  read-only in other modes, and the mouse wheel never changes the limits. Shown
  only when the hardware exposes `charge_types` and/or the
  `charge_control_*_threshold` files.
- **Power use** — what is drawing power right now: the battery's draw in
  watts, a short sparkline of it, and the top 3 apps. See
  [Power use](#power-use-is-an-estimate).
- **Health history** — a sample is stored on service start, every 6 hours, and
  when AC is plugged or unplugged (a sample is skipped if the last one is under
  6 hours old, except on plug/unplug). History is append-only and never pruned.
  The first run also writes a synthetic 100% point at the battery's
  manufacture date, when the firmware reports one.
- **Health graph** — line chart of health over 3 months, 1 year, or all time
  (click to cycle; it opens on all time until there are 30 days of history),
  with a dashed health-floor line and a marker for the end of
  your warranty.
- **Wear projection** — health, wear in % per month, and the month in which
  health is projected to reach the floor. Uses a fit over the last 90 days once
  there are 30 days of data, otherwise an estimate from the seed point.
- **Alerts** — an alert banner in the panel, a mark on the bar icon, and a
  desktop notification:
  - *Charge limit ignored*: a limit below 100% is set, but the battery is in
    a mode other than Custom that you did not pick in the panel; or, on AC in
    Custom mode, the battery is still charging and rising more than 3 points
    past the end limit on two consecutive checks. The banner offers a **Fix**
    button for the mode case.
  - *Battery wearing fast*: health is projected to reach the floor before the
    warranty ends. Notified at most once a week, and only from a fitted rate,
    not an estimate.
- **Theme colours** — the panel takes its colours from the current Omarchy
  theme and follows it when you switch themes.
- Bar glyph, optional percentage, power profiles, and IPC as in the stock widget.

## Power use is an estimate

The POWER USE section lists the 3 apps using the most CPU. On battery, each
app's figure is its share of CPU time over the last ~10 seconds multiplied by
the battery's measured draw, shown as `~1.2 W`. The draw is measured; the
split between apps is an estimate, because CPU time is not the same as power
(screen, GPU and radios are not attributed).

On the charger the draw cannot be measured, so the section shows each app's
percentage of CPU instead, with no watts or sparkline.

"Desktop" is Hyprland and the shell, which includes the panel's own sampling.
The section reads cgroup CPU counters every 2 seconds, and only while the
panel is open; nothing is sampled when it is closed.

## Requirements

- [Omarchy](https://omarchy.org) with the plugin system (`omarchy plugin`)
- `bash`, `jq`, `upower`, `pkexec` (polkit) and `node` (tests only); all
  present on a stock Omarchy install
- A battery. Charging controls need a laptop that exposes charge control in
  sysfs (tested layout: Dell, `charge_types` plus thresholds). Without it the
  widget still works as the stock one plus health history and alerts.

## Install

When published:

```bash
omarchy plugin add https://github.com/esemczak/omarchy-battery.git --enable --yes
omarchy restart shell
```

From a checkout (development route):

```bash
./dev-install.sh                       # validates, stops the shell, copies, restarts
omarchy plugin enable esemczak.battery
```

Then install the privileged helper, once:

```bash
./install-helper.sh
```

This uses `sudo` to install `/usr/local/bin/esemczak-battery-helper`, owned by
root, mode 0755. Until it is installed, the panel shows a hint instead of the
charging controls.

### Passwords and privileges

Writing charge settings needs root. **Every setting change asks for your
password through `pkexec`.** No sudoers or polkit rule is installed, so nothing
can change your charge settings without a prompt. The helper only accepts
`mode <name>` for a mode the battery lists, and `limits <start> <end>` with
1 <= start < end <= 100. It always runs from the root-owned copy, never from
the plugin directory.

### Replaces omarchy.power

The manifest declares `clonedFrom: omarchy.power`, so enabling this plugin
replaces the stock widget in place in your bar. The
`omarchy-shell omarchy.power ...` IPC and the menu entry keep working. The stock
low-battery service `omarchy.battery` (10% warning, `battery-low` hook,
power-profile auto-switch) is not touched.

## Settings

Set in the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `showPercentage` | `false` | Show the percentage next to the bar glyph |
| `warrantyEnd` | `"2027-04-30"` | Warranty end date (`YYYY-MM-DD`), drawn on the graph and used by the degradation alert |
| `healthFloor` | `80` | Health % you care about; drawn on the graph and used for the projection |
| `alerts.limitIgnored` | `true` | Alert when the charge limit is being ignored |
| `alerts.degradation` | `true` | Alert when health is projected to hit the floor before the warranty ends |

Example:

```json
{ "id": "esemczak.battery", "showPercentage": true, "warrantyEnd": "2028-01-15", "healthFloor": 75, "alerts": { "degradation": false } }
```

## IPC

The same targets as the stock widget:

```bash
omarchy-shell omarchy.power open|close|show|hide|toggle
omarchy-shell omarchy.power togglePercentage
```

## Data files

In `${XDG_STATE_HOME:-~/.local/state}/esemczak-battery/`:

- `history.jsonl` — one health sample per line, append-only
- `state.json` — chosen mode, current alerts, and notification bookkeeping

## Charge settings and reboots

Whether the firmware keeps the charge mode and thresholds across a reboot has
not yet been verified on reboot. If they reset, re-apply them from the panel.

## Remove

```bash
omarchy plugin disable esemczak.battery
omarchy plugin remove esemczak.battery --yes
omarchy restart shell
sudo rm /usr/local/bin/esemczak-battery-helper
```

Optionally delete the history with `rm -rf ~/.local/state/esemczak-battery`.

## Development

```bash
node --test tests/              # Model.js logic
bash tests/scripts.test.sh      # bin/* scripts against a fake sysfs tree
omarchy plugin validate .
```

## License

MIT
