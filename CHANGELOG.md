# Changelog

## 0.2.1 - 2026-10-24

- Fix: plugging in a USB-C charger did not record a history sample. The charger
  event arrives a second or two before the sysfs AC flag flips, so the sampler
  read the old state. It now waits (up to 10 s) for the flag to match, and the
  alert check runs after that sample.

## 0.2.0 - 2026-10-24

- Panel restyle: colours now follow the current Omarchy theme, with subtle motion.
- Charging controls: mode tiles and a battery gauge with draggable start/end limits (editable in Custom mode; the mouse wheel never changes them; still one password prompt per change).
- New POWER USE section: measured battery draw, a short sparkline, and the top 3 apps as an estimate (CPU share over ~10 s times the draw; % of CPU on the charger). Sampled only while the panel is open.
- Themes that define only the 16 ANSI colours (color0-color15) now still get green/red/cyan for good/warning/power; 8-digit theme colours keep their alpha correctly.
- Health graph: more headroom for the latest point, and it opens on all time until there are 30 days of recorded samples.

## 0.1.0 - 2026-10-24

- Initial release: replaces `omarchy.power` with the stock widget's behaviour plus:
- Charging controls (mode and custom start/end thresholds) via a root-owned helper and `pkexec`.
- Battery health history (`history.jsonl`) and a health graph with floor and warranty markers.
- Wear projection and alerts for ignored charge limits and fast degradation.
