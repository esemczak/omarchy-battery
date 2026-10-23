const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("stock helpers behave like omarchy.power", () => {
  assert.equal(Model.PLUGIN_ID, "esemczak.battery")
  assert.deepEqual(Model.parseKeyValue("percentage\t97%\ncycles\t65"), { percentage: "97%", cycles: "65" })
  assert.deepEqual(
    Model.parseProfiles("power-saver\t0\nbalanced\t1\nperformance\t0", 0),
    { profiles: ["power-saver", "balanced", "performance"], activeProfile: "balanced", profileIndex: 0 }
  )
  assert.equal(Model.selectProfileIndex(2, 1, ["a", "b", "c"]), 2)
  assert.equal(Model.profileIcon("balanced"), "󰊚")
  assert.equal(Model.stateDir("/home/u", ""), "/home/u/.local/state/esemczak-battery")
  assert.equal(Model.stateDir("/home/u", "/x"), "/x/esemczak-battery")
})

test("parseChargeTypes extracts modes and the bracketed active one", () => {
  assert.deepEqual(Model.parseChargeTypes("Trickle [Fast] Standard Adaptive Custom"),
    { modes: ["Trickle", "Fast", "Standard", "Adaptive", "Custom"], active: "Fast" })
  assert.deepEqual(Model.parseChargeTypes(""), { modes: [], active: null })
})

test("parseSnapshot and healthPct", () => {
  const dell = JSON.stringify({ present: true, modes: ["Fast"], mode: "Fast", start: 50, end: 90,
    full: 5400000, design: 5983000, cycles: 65, percent: 97, status: "Discharging", tempC: 28.8, ac: false, made: "2025-12-30" })
  const s = Model.parseSnapshot(dell)
  assert.equal(s.present, true)
  assert.equal(Model.healthPct(s), 90.3)
  const bad = Model.parseSnapshot("garbage")
  assert.equal(bad.present, false)
  assert.deepEqual(bad.modes, [])
  assert.equal(bad.ac, false)
  assert.equal(bad.full, null)
  assert.equal(Model.healthPct(bad), null)
})

test("actionResult maps helper exit codes", () => {
  assert.equal(Model.HELPER_PATH, "/usr/local/bin/esemczak-battery-helper")
  assert.equal(Model.actionResult(0).ok, true)
  assert.equal(Model.actionResult(0).message, "Saved")
  assert.equal(Model.actionResult(126).message, "Not changed")
  assert.equal(Model.actionResult(127).ok, false)
  assert.equal(Model.actionResult(2).message, "Invalid value")
  assert.equal(Model.actionResult(3).message, "Couldn't write setting")
  assert.equal(Model.actionResult(1).ok, false)
})

const DAY = 86400000

test("parseHistory tolerates corrupt lines", () => {
  const out = Model.parseHistory('{"t":1,"health":99}\n{"t":2,"hea\n{"t":3,"health":98}\n', 10)
  assert.equal(out.length, 2)
})

test("parseHistory drops far-future samples, keeps near-future, sorts", () => {
  const now = Date.UTC(2026, 9, 24)
  const text = [
    JSON.stringify({ t: now + 2 * DAY, health: 90 }),
    JSON.stringify({ t: now + 3600000, health: 91 }),
    JSON.stringify({ t: now - DAY, health: 92 }),
    JSON.stringify({ t: now - 2 * DAY, health: "x" })
  ].join("\n")
  const out = Model.parseHistory(text, now)
  assert.deepEqual(out.map(s => s.health), [92, 91])
})

test("wearRate estimate from seed to latest", () => {
  const seed = { t: new Date(2025, 11, 30).getTime(), health: 100, seed: true }
  const real = { t: new Date(2026, 9, 24, 12).getTime(), health: 90.3 }
  const now = new Date(2026, 9, 24, 13).getTime()
  const r = Model.wearRate([seed, real], now)
  assert.equal(r.basis, "estimate")
  assert.ok(Math.abs(r.perMonth - -1.0) < 0.05, String(r.perMonth))
})

test("wearRate fit is robust to an outlier day", () => {
  const now = new Date(2026, 9, 24, 13).getTime()
  const samples = []
  for (let i = 0; i < 60; i++) {
    const d = 59 - i
    let h = 95 - 0.05 * i
    if (i === 30) h += 5
    samples.push({ t: new Date(2026, 9, 24 - d, 12).getTime(), health: h })
  }
  const r = Model.wearRate(samples, now)
  assert.equal(r.basis, "fit")
  assert.ok(Math.abs(r.perMonth - -1.52) < 0.1, String(r.perMonth))
})

test("wearRate none without data", () => {
  assert.deepEqual(Model.wearRate([], Date.now()), { perMonth: null, basis: "none" })
})

test("projectFloorDate", () => {
  const now = Date.UTC(2026, 9, 24)
  const d = new Date(Model.projectFloorDate(90.3, -1.5, 80, now))
  assert.equal(d.getUTCFullYear(), 2027)
  assert.equal(d.getUTCMonth(), 4)
  assert.equal(Model.projectFloorDate(90, 0.1, 80, now), null)
  assert.equal(Model.projectFloorDate(79, -1, 80, now), null)
  assert.equal(Model.projectFloorDate(90, null, 80, now), null)
})

// --- Alert evaluation ---

const fs = require("node:fs")
const path = require("node:path")

const NOW = new Date(2026, 9, 24, 13).getTime()
const SETTINGS = Model.settingsFrom({})
const dell = (over) => Object.assign({ present: true, modes: ["Fast"], mode: "Fast", start: 50, end: 90,
  full: 5400000, design: 5983000, cycles: 65, percent: 97, status: "Discharging", tempC: 28.8, ac: false,
  made: "2025-12-30" }, over || {})
const customSnap = (over) => dell(Object.assign({ modes: ["Standard", "Custom"], mode: "Custom", ac: true }, over || {}))
const evalAt = (snap, state, settings, now, samples) =>
  Model.evaluateAlerts(snap, samples || [], state, settings || SETTINGS, now === undefined ? NOW : now)

test("settingsFrom applies defaults and parses warrantyEnd as local end of day", () => {
  const d = Model.settingsFrom({})
  assert.equal(d.showPercentage, false)
  assert.equal(d.healthFloor, 80)
  assert.equal(d.alertLimitIgnored, true)
  assert.equal(d.alertDegradation, true)
  assert.equal(d.warrantyEnd, new Date(2027, 3, 30, 23, 59, 59, 999).getTime())
  const c = Model.settingsFrom({ showPercentage: true, warrantyEnd: "2028-01-15", healthFloor: 70,
    alerts: { limitIgnored: false, degradation: false } })
  assert.equal(c.showPercentage, true)
  assert.equal(c.warrantyEnd, new Date(2028, 0, 15, 23, 59, 59, 999).getTime())
  assert.equal(c.healthFloor, 70)
  assert.equal(c.alertLimitIgnored, false)
  assert.equal(c.alertDegradation, false)
  assert.equal(Model.settingsFrom({ warrantyEnd: "nope" }).warrantyEnd, d.warrantyEnd)
  assert.equal(Model.settingsFrom({ warrantyEnd: "2027-02-31" }).warrantyEnd, d.warrantyEnd)
})

test("settingsFromShellConfig reads the owner's shell.json entry", () => {
  const text = fs.readFileSync(path.join(__dirname, "fixtures", "shell.json"), "utf8")
  const s = Model.settingsFromShellConfig(text)
  assert.equal(s.showPercentage, true)
  assert.equal(s.healthFloor, 80)
  assert.deepEqual(Model.settingsFromShellConfig("not json"), Model.settingsFrom({}))
  assert.deepEqual(Model.settingsFromShellConfig("{}"), Model.settingsFrom({}))
})

test("limit ignored: today's case (Fast, 50-90, nothing chosen) alerts once", () => {
  const r = evalAt(dell(), { chosenMode: null }, SETTINGS)
  assert.equal(r.state.alerts.limitIgnored.active, true)
  assert.equal(r.state.alerts.limitIgnored.reason, "mode")
  assert.equal(r.state.alerts.limitIgnored.text, "Charge limit 50–90% is set but mode is Fast, so it's ignored.")
  assert.equal(r.notifications.length, 1)
  assert.equal(r.notifications[0].key, "limitIgnored")
  assert.equal(r.notifications[0].title, "Battery limit ignored")
  assert.equal(r.notifications[0].urgency, "normal")
})

test("limit ignored: repeat with returned state does not notify again", () => {
  const first = evalAt(dell(), { chosenMode: null }, SETTINGS)
  const r = evalAt(dell(), first.state, SETTINGS, NOW + 300000)
  assert.equal(r.state.alerts.limitIgnored.active, true)
  assert.equal(r.notifications.length, 0)
})

test("limit ignored: clears the sent flag when inactive, so it can fire again", () => {
  const first = evalAt(dell(), { chosenMode: null }, SETTINGS)
  const ok = evalAt(dell({ mode: "Adaptive", modes: ["Fast", "Adaptive"] }),
    Object.assign({}, first.state, { chosenMode: "Adaptive" }), SETTINGS, NOW + 1)
  assert.equal(ok.state.alerts.limitIgnored.active, false)
  assert.equal(ok.state.notify.limitIgnoredSent, false)
})

test("limit ignored: owner chose Adaptive and live mode is Adaptive -> inactive", () => {
  const r = evalAt(dell({ mode: "Adaptive", modes: ["Fast", "Adaptive"] }), { chosenMode: "Adaptive" }, SETTINGS)
  assert.equal(r.state.alerts.limitIgnored.active, false)
  assert.equal(r.notifications.length, 0)
})

test("limit ignored: BIOS reset (chose Custom, live Standard) -> active", () => {
  const r = evalAt(customSnap({ mode: "Standard" }), { chosenMode: "Custom" }, SETTINGS)
  assert.equal(r.state.alerts.limitIgnored.active, true)
  assert.equal(r.state.alerts.limitIgnored.reason, "mode")
})

test("limit ignored: Custom holding at 97% Not charging on AC -> inactive", () => {
  const r = evalAt(customSnap({ percent: 97, status: "Not charging" }), { chosenMode: "Custom" }, SETTINGS)
  assert.equal(r.state.alerts.limitIgnored.active, false)
})

test("limit ignored: Custom charging 94 -> 95 -> 96 past end 90 alerts on the third evaluation", () => {
  let st = { chosenMode: "Custom" }
  const run = (pct, i) => {
    const r = evalAt(customSnap({ percent: pct, status: "Charging" }), st, SETTINGS, NOW + i * 300000)
    st = r.state
    return r
  }
  assert.equal(run(94, 0).state.alerts.limitIgnored.active, false)
  assert.equal(run(95, 1).state.alerts.limitIgnored.active, false)
  const third = run(96, 2)
  assert.equal(third.state.alerts.limitIgnored.active, true)
  assert.equal(third.state.alerts.limitIgnored.reason, "overcharge")
  assert.equal(third.state.alerts.limitIgnored.text, "Charging past the 90% limit (96%).")
  assert.equal(third.notifications.length, 1)
  assert.equal(third.notifications[0].key, "limitIgnored")
  // a non-rising reading resets the streak
  const fourth = run(96, 3)
  assert.equal(fourth.state.alerts.limitIgnored.active, false)
  assert.equal(fourth.state.overcharge.streak, 0)
  assert.equal(fourth.state.overcharge.lastPercent, 96)
})

test("limit ignored: generic battery without charge_types -> inactive", () => {
  const generic = dell({ modes: [], mode: null, start: null, end: null })
  const r = evalAt(generic, { chosenMode: null }, SETTINGS)
  assert.equal(r.state.alerts.limitIgnored.active, false)
  assert.equal(r.notifications.length, 0)
})

function fitSamples(count, startHealth, perDay) {
  const out = []
  for (let i = 0; i < count; i++)
    out.push({ t: new Date(2026, 9, 24 - (count - 1 - i), 12).getTime(), health: startHealth + perDay * i })
  return out
}

test("degradation, fit basis: active, notifies, throttled to once per 7 days", () => {
  const samples = fitSamples(60, 90.3, -0.05)
  const snap = dell({ mode: "Fast" })
  const first = evalAt(snap, { chosenMode: "Fast" }, SETTINGS, NOW, samples)
  const a = first.state.alerts.degradation
  assert.equal(a.active, true)
  assert.equal(a.basis, "fit")
  assert.match(a.text, /^At 1\.5%\/month, health reaches 80% around [A-Z][a-z]{2} 20\d\d, before the warranty ends\.$/)
  assert.ok(a.date < SETTINGS.warrantyEnd)
  const n1 = first.notifications.filter(n => n.key === "degradation")
  assert.equal(n1.length, 1)
  assert.equal(n1[0].title, "Battery wearing fast")
  assert.equal(n1[0].urgency, "normal")
  assert.equal(first.state.notify.degradationLastSent, NOW)
  const next = evalAt(snap, first.state, SETTINGS, NOW + DAY, samples)
  assert.equal(next.state.alerts.degradation.active, true)
  assert.equal(next.notifications.filter(n => n.key === "degradation").length, 0)
  const later = evalAt(snap, first.state, SETTINGS, NOW + 8 * DAY, samples)
  assert.equal(later.notifications.filter(n => n.key === "degradation").length, 1)
})

test("degradation, estimate basis: active, no notification, text ends with (estimate)", () => {
  const seed = { t: new Date(2026, 5, 24).getTime(), health: 100, seed: true }
  const real = { t: new Date(2026, 9, 24, 12).getTime(), health: 90.3 }
  const r = evalAt(dell(), { chosenMode: "Fast" }, SETTINGS, NOW, [seed, real])
  const a = r.state.alerts.degradation
  assert.equal(a.active, true)
  assert.equal(a.basis, "estimate")
  assert.ok(a.text.endsWith(" (estimate)"), a.text)
  assert.equal(r.notifications.filter(n => n.key === "degradation").length, 0)
})

test("degradation: not active when projection is after the warranty end", () => {
  const samples = fitSamples(60, 90.3, -0.005)
  const r = evalAt(dell(), { chosenMode: "Fast" }, SETTINGS, NOW, samples)
  assert.equal(r.state.alerts.degradation.active, false)
})

test("settings off: disabled alerts are never active and never notify", () => {
  const off = Model.settingsFrom({ alerts: { limitIgnored: false, degradation: false } })
  const r = evalAt(dell(), { chosenMode: null }, off, NOW, fitSamples(60, 90.3, -0.05))
  assert.equal(r.state.alerts.limitIgnored.active, false)
  assert.equal(r.state.alerts.degradation.active, false)
  assert.equal(r.notifications.length, 0)
})

test("absent battery: both alerts inactive, no notifications", () => {
  const absent = Model.parseSnapshot("garbage")
  const r = evalAt(absent, null, SETTINGS, NOW, fitSamples(60, 90.3, -0.05))
  assert.equal(r.state.alerts.limitIgnored.active, false)
  assert.equal(r.state.alerts.degradation.active, false)
  assert.equal(r.notifications.length, 0)
})

test("evaluateAlerts tolerates a missing state and does not mutate its input", () => {
  const st = { chosenMode: null }
  const frozen = JSON.stringify(st)
  const r = evalAt(dell(), st, SETTINGS)
  assert.equal(JSON.stringify(st), frozen)
  assert.deepEqual(r.state.overcharge, { streak: 0, lastPercent: 97 })
  assert.equal(evalAt(dell(), undefined, SETTINGS).state.chosenMode, null)
})

test("chartPoints maps samples into the range window", () => {
  const now = Date.UTC(2026, 9, 24)
  const seed = { t: Date.UTC(2025, 11, 30), health: 100, seed: true }
  const real = { t: now, health: 90.3 }
  const all = Model.chartPoints([seed, real], "all", now)
  assert.equal(all.points.length, 2)
  assert.equal(all.points[0].seed, true)
  assert.equal(all.points[0].x, 0)
  // No warranty extension here, so 20 % forward headroom puts the latest at 1/1.2.
  assert.ok(Math.abs(all.points[1].x - 1 / 1.2) < 1e-9)
  assert.equal(all.points[1].seed, false)
  assert.equal(all.yMax, 100)
  assert.equal(all.yMin, 75)
  assert.ok(all.floorY > 0 && all.floorY < 1)
  assert.equal(all.warrantyX, null)
  const m3 = Model.chartPoints([seed, real], "3m", now)
  assert.equal(m3.points.length, 1)
  assert.equal(m3.points[0].seed, false)
  assert.equal(Model.chartPoints([seed, real], "1y", now).points.length, 2)
})

test("chartPoints yMin follows low health, warranty marker appears in range", () => {
  const now = Date.UTC(2026, 9, 24)
  const r = Model.chartPoints([{ t: now - 1000, health: 70.5 }, { t: now, health: 70 }], "3m", now,
    { floor: 80, warrantyEnd: now - 10 * 86400000 })
  assert.equal(r.yMin, 68)
  assert.ok(r.warrantyX > 0 && r.warrantyX < 1)
  assert.deepEqual(Model.chartPoints([], "all", now).points, [])
})

test("nextRange cycles 3m, 1y, all", () => {
  assert.equal(Model.nextRange("3m"), "1y")
  assert.equal(Model.nextRange("1y"), "all")
  assert.equal(Model.nextRange("all"), "3m")
  assert.equal(Model.nextRange("bogus"), "3m")
})

test("chartPoints extends 1y/all to a future warranty end, 3m does not", () => {
  const now = Date.UTC(2026, 9, 24)
  const seed = { t: Date.UTC(2025, 11, 30), health: 100, seed: true }
  const real = { t: now, health: 90.3 }
  const opts = { floor: 80, warrantyEnd: Date.UTC(2027, 3, 30) }
  const all = Model.chartPoints([seed, real], "all", now, opts)
  assert.equal(all.warrantyX, 1)
  assert.ok(all.points[1].x < 1)
  assert.equal(Model.chartPoints([seed, real], "1y", now, opts).warrantyX, 1)
  assert.equal(Model.chartPoints([seed, real], "3m", now, opts).warrantyX, null)
})

test("limitModeIgnored agrees with the evaluateAlerts mode reason", () => {
  const cases = [
    [dell(), null, true],
    [dell(), "Fast", false],
    [customSnap(), null, false],
    [dell({ end: 100 }), null, false],
    [dell({ modes: [], mode: null }), null, false]
  ]
  for (const [snap, chosen, expected] of cases) {
    assert.equal(Model.limitModeIgnored(snap, chosen), expected)
    const r = evalAt(snap, { chosenMode: chosen }, SETTINGS)
    assert.equal(r.state.alerts.limitIgnored.reason === "mode" && r.state.alerts.limitIgnored.active, expected)
  }
})

test("overcharge never fires without a threshold (end null)", () => {
  let st = { chosenMode: "Custom" }
  let r
  for (const p of [90, 92, 94, 96]) {
    r = evalAt(customSnap({ end: null, start: null, status: "Charging", percent: p }), st, SETTINGS)
    st = r.state
  }
  assert.equal(r.state.alerts.limitIgnored.active, false)
  assert.ok(!/null/.test(r.state.alerts.limitIgnored.text || ""))
})

test("parseThemeColors reads hex colours from colors.toml", () => {
  const text = require("node:fs").readFileSync(require("node:path").join(__dirname, "fixtures", "colors.toml"), "utf8")
  const p = Model.parseThemeColors(text)
  assert.equal(p.green, "#87a9b0")
  assert.equal(p.red, "#c38b7b")
  assert.equal(p.mode, undefined)
})

test("parseThemeColors ignores comments and junk, handles hex lengths", () => {
  assert.deepEqual(Model.parseThemeColors(""), {})
  const p = Model.parseThemeColors('# green = "#111111"\nJunk line\nRED = "#abc"\nx = #123456\nblue = "#11223344"\nmode = "dark"\nbad = "#12345"\n')
  assert.deepEqual(p, { red: "#abc", blue: "#44112233" })
})

test("parseThemeColors rewrites 8-digit #rrggbbaa to QML #aarrggbb", () => {
  assert.equal(Model.parseThemeColors('bg = "#1e1e2eff"\n').bg, "#ff1e1e2e")
  assert.equal(Model.parseThemeColors('bg = "#11223380"\n').bg, "#80112233")
})

test("semanticColors falls back to ANSI color slots", () => {
  const fb = { accent: "#aaaaaa", urgent: "#bb0000", foreground: "#ffffff", muted: "#777777" }
  const s = Model.semanticColors({ color1: "#c1", color2: "#c2", color6: "#c6", color4: "#c4" }, fb)
  assert.equal(s.warn, "#c1")
  assert.equal(s.good, "#c2")
  assert.equal(s.power, "#c6")
  assert.equal(Model.semanticColors({ red: "#r", green: "#g", cyan: "#c", color1: "#c1", color2: "#c2", color6: "#c6" }, fb).good, "#g")
  assert.equal(Model.semanticColors({ blue: "#05", color6: "#c6" }, fb).power, "#c6")
})

test("semanticColors maps palette with fallbacks", () => {
  const fb = { accent: "#aaaaaa", urgent: "#bb0000", foreground: "#ffffff", muted: "#777777" }
  const s = Model.semanticColors({}, fb)
  assert.equal(s.good, "#aaaaaa")
  assert.equal(s.warn, "#bb0000")
  assert.equal(s.neutral, "#aaaaaa")
  assert.equal(s.power, "#aaaaaa")
  assert.equal(s.text, "#ffffff")
  assert.equal(s.muted, "#777777")
  const full = Model.semanticColors({ green: "#01", red: "#02", accent: "#03", cyan: "#04", blue: "#05", foreground: "#06", muted: "#07" }, fb)
  assert.deepEqual(full, { good: "#01", warn: "#02", neutral: "#03", power: "#04", text: "#06", muted: "#07" })
  assert.equal(Model.semanticColors({ blue: "#05" }, fb).power, "#05")
})

test("unitLabel names cgroup units", () => {
  const L = Model.unitLabel
  assert.equal(L("user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-brave-1a2b.scope"), "Brave")
  assert.equal(L("a/app-Hyprland-xdg\\x2dterminal\\x2dexec-509c.scope"), "Terminal")
  assert.equal(L("a/app-org.chromium.Chromium-42.scope"), "Chromium")
  assert.equal(L("a/wayland-wm@hyprland.desktop.service"), "Desktop")
  assert.equal(L("a/session-3.scope"), "Login session")
  assert.equal(L("system.slice/bt-agent.service"), "Bt-agent")
  assert.equal(L("a/dropbox@autostart.service"), "Dropbox")
  assert.equal(L("a/app-Hyprland-nautilus-ab12.scope"), "Files")
})

const S = (t, groups, drawW) => ({ t: t, drawW: drawW === undefined ? null : drawW, groups: groups })
const G = (path, usec) => ({ path: path, usec: usec })

test("appShares merges labels, skips missing and negative", () => {
  const a = "x/app-Hyprland-brave-1a.scope", b = "x/app-Hyprland-brave-2b.scope"
  const c = "x/app-org.chromium.Chromium-42.scope", d = "x/gone.service", e = "x/neg.service"
  const first = S(0, [G(a, 100), G(b, 100), G(c, 100), G(d, 0), G(e, 500)])
  const last = S(1, [G(a, 400), G(b, 300), G(c, 300), G(e, 100)])
  assert.deepEqual(Model.appShares([first, last]), [{ label: "Brave", share: 5 / 7 }, { label: "Chromium", share: 2 / 7 }])
  assert.deepEqual(Model.appShares([first, S(1, [G(a, 100)])]), [])
  assert.deepEqual(Model.appShares([first]), [])
  assert.deepEqual(Model.appShares([]), [])
})

test("powerRows modes", () => {
  const sh = [{ label: "A", share: 0.5 }, { label: "B", share: 0.3 }, { label: "C", share: 0.2 }]
  const w = Model.powerRows(sh, S(1, [], 6.5), 3)
  assert.equal(w.mode, "watts")
  assert.deepEqual(w.rows.map(r => r.value), [3.3, 2.0, 1.3])
  assert.deepEqual(w.rows.map(r => r.unit), ["W", "W", "W"])
  assert.deepEqual(w.rows.map(r => r.fraction), [1, 0.6, 0.4])
  const c = Model.powerRows(sh, S(1, [], null), 2)
  assert.equal(c.mode, "cpu")
  assert.deepEqual(c.rows.map(r => r.value), [50, 30].slice(0, 2))
  assert.equal(c.rows[0].unit, "%")
  assert.equal(Model.powerRows(Model.appShares([S(1, [G("a", 5)], 6.5)]), S(1, [], 6.5), 3).mode, "measuring")
  assert.equal(Model.powerRows([], S(1, [], 6.5), 3).mode, "measuring")
})

test("appendDrawPoint gaps, expiry and cap", () => {
  let b = Model.appendDrawPoint([], S(0, [], 5), 100000)
  assert.deepEqual(b, [{ t: 100000, w: 5, gapBefore: false }])
  b = Model.appendDrawPoint(b, S(0, [], 6), 112000)
  assert.equal(b[1].gapBefore, true)
  b = Model.appendDrawPoint(b, S(0, [], 7), 114000)
  assert.equal(b[2].gapBefore, false)
  assert.equal(Model.appendDrawPoint(b, S(0, [], null), 116000).length, 3)
  assert.equal(Model.appendDrawPoint(b, S(0, [], 8), 100000 + 300001).length, 3 - 1 + 1)
  let big = []
  for (let i = 0; i < 200; i++) big = Model.appendDrawPoint(big, S(0, [], 1), 1000000 + i * 1000)
  assert.equal(big.length, 150)
  assert.equal(big[149].t, 1000000 + 199 * 1000)
})

test("modeTone maps modes to semantic tones", () => {
  assert.equal(Model.modeTone("Custom"), "good")
  assert.equal(Model.modeTone("Fast"), "warn")
  assert.equal(Model.modeTone("Standard"), "neutral")
  assert.equal(Model.modeTone("Trickle"), "neutral")
  assert.equal(Model.modeTone(undefined), "neutral")
})

test("modeIcon maps modes to glyphs", () => {
  assert.equal(Model.modeIcon("Trickle"), "󰂃")
  assert.equal(Model.modeIcon("Fast"), "󱐋")
  assert.equal(Model.modeIcon("Standard"), "󰁹")
  assert.equal(Model.modeIcon("Adaptive"), "󰂏")
  assert.equal(Model.modeIcon("Custom"), "󰢝")
  assert.equal(Model.modeIcon("Other"), "󰂄")
})

test("clampHandle keeps 1 <= start < end <= 100", () => {
  assert.equal(Model.clampHandle("start", 95, 50, 90), 89)
  assert.equal(Model.clampHandle("end", 40, 50, 90), 51)
  assert.equal(Model.clampHandle("end", 120, 50, 90), 100)
  assert.equal(Model.clampHandle("start", 0, 50, 90), 1)
  assert.equal(Model.clampHandle("start", 60.6, 50, 90), 61)
  assert.equal(Model.clampHandle("end", 70.2, 50, 90), 70)
})

// --- Projection line ---

const projChart = () => {
  const now = Date.UTC(2026, 9, 24)
  const start = now - 300 * DAY
  const end = now + 200 * DAY
  const yMin = 75, yMax = 100
  return { now, chart: { points: [{ x: 0.6, y: (90.3 - yMin) / (yMax - yMin), seed: false }], yMin, yMax, start, end, floorY: 0.2 } }
}

test("projectionPoint heads right and down toward the floor", () => {
  const { now, chart } = projChart()
  const p = Model.projectionPoint(chart, -1.0, 80, now, "all")
  assert.ok(p !== null)
  assert.ok(p.x > 0.6)
  assert.ok(p.y < chart.points[0].y)
  assert.ok(p.y >= chart.floorY - 1e-9)
})

test("projectionPoint is null without a falling rate or points", () => {
  const { now, chart } = projChart()
  assert.equal(Model.projectionPoint(chart, null, 80, now, "all"), null)
  assert.equal(Model.projectionPoint(chart, 0.1, 80, now, "all"), null)
  assert.equal(Model.projectionPoint(chart, 0, 80, now, "all"), null)
  assert.equal(Model.projectionPoint(Object.assign({}, chart, { points: [] }), -1, 80, now, "all"), null)
})

test("projectionPoint clamps x to the domain end", () => {
  const { now, chart } = projChart()
  const p = Model.projectionPoint(chart, -0.01, 80, now, "all")
  assert.equal(p.x, 1)
  assert.ok(p.y < chart.points[0].y)
})

test("chartPoints exposes its time domain for the projection", () => {
  const now = Date.UTC(2026, 9, 24)
  const c = Model.chartPoints([{ t: now, health: 90 }], "3m", now)
  assert.equal(c.start, now - 92 * DAY)
  assert.equal(c.end, now + 0.2 * 92 * DAY)
})

test("3m with the latest sample at now leaves room for the projection", () => {
  const now = Date.UTC(2026, 9, 24)
  const samples = [{ t: now - 40 * DAY, health: 91 }, { t: now, health: 90.3 }]
  const c = Model.chartPoints(samples, "3m", now, { floor: 80, warrantyEnd: Date.UTC(2027, 3, 30) })
  const latest = c.points[c.points.length - 1]
  assert.ok(latest.x < 1)
  assert.ok(Math.abs(latest.x - 1 / 1.2) < 1e-9)
  const p = Model.projectionPoint(c, -1.0, 80, now, "3m")
  assert.ok(p !== null)
  assert.ok(p.x > latest.x && p.x <= 1)
  assert.ok(p.y < latest.y)
})

test("headroom is not added when the warranty end already extends the domain", () => {
  const now = Date.UTC(2026, 9, 24)
  const w = Date.UTC(2027, 3, 30)
  const c = Model.chartPoints([{ t: now, health: 90 }], "all", now, { warrantyEnd: w })
  assert.equal(c.end, w)
})

test("defaultRange: all for short real history, 3m once it spans 30+ days", () => {
  const now = Date.UTC(2026, 9, 24)
  const seed = { t: Date.UTC(2025, 11, 30), health: 100, seed: true }
  assert.equal(Model.defaultRange([seed, { t: now - 2 * DAY, health: 90.4 }, { t: now, health: 90.3 }], now), "all")
  assert.equal(Model.defaultRange([], now), "all")
  const sixty = []
  for (let d = 60; d >= 0; d--) sixty.push({ t: now - d * DAY, health: 91 - d / 60 })
  assert.equal(Model.defaultRange([seed].concat(sixty), now), "3m")
})
