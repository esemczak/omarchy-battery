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
  assert.equal(all.points[1].x, 1)
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
