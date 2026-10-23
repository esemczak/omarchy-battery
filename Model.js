// Pure helpers for the esemczak.battery plugin. No Qt or Quickshell access here so
// the same file runs under `node --test` and inside the shell's QML engine.

var PLUGIN_ID = "esemczak.battery"

function stateDir(home, xdgStateHome) {
  var base = xdgStateHome ? String(xdgStateHome) : String(home || "") + "/.local/state"
  return base + "/esemczak-battery"
}

// --- Ported verbatim from omarchy.power (stock Model.js) ---

function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function selectProfileIndex(index, delta, profiles) {
  var values = Array.isArray(profiles) ? profiles : []
  if (values.length === 0) return 0
  return clampIndex(index + delta, values.length)
}

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
  }
  return next
}

function parseProfiles(raw, previousIndex) {
  var lines = String(raw || "").split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    list.push(parts[0])
    if (parts[1] === "1") active = parts[0]
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  }
}

function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0
}

function chargeThresholdActive(device, onBattery, states) {
  var d = device || {}
  var s = states || {}
  if (!(d && d.isPresent && !onBattery)) return false

  var fraction = batteryFraction(d)
  if (d.state === s.Discharging) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false

  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
}

function batteryIcon(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))
  var threshold = chargeThresholdActive(d, onBattery, states)

  if (threshold) return defaultIcons[index]
  if (d.state === states.FullyCharged) return "󰂅"
  if (!onBattery) return chargingIcons[index]
  return defaultIcons[index]
}

function modeLabel(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var percentage = d.isPresent ? d.percentage : 0
  if (chargeThresholdActive(d, onBattery, states)) return "Threshold"
  if (onBattery) return "On battery"
  if (!onBattery && percentage >= 1) return "Fully charged"
  return "Charging"
}

function parseChargeTypes(text) {
  var modes = []
  var active = null
  String(text || "").split(/\s+/).forEach(function (tok) {
    if (!tok) return
    var m = /^\[(.*)\]$/.exec(tok)
    var name = m ? m[1] : tok
    modes.push(name)
    if (m) active = name
  })
  return { modes: modes, active: active }
}

function parseSnapshot(jsonText) {
  var empty = {
    present: false, modes: [], mode: null, start: null, end: null, full: null, design: null,
    cycles: null, percent: null, status: null, tempC: null, ac: false, made: null
  }
  var raw
  try { raw = JSON.parse(jsonText) } catch (e) { return empty }
  if (!raw || typeof raw !== "object") return empty
  function n(v) { return typeof v === "number" && isFinite(v) ? v : null }
  function s(v) { return typeof v === "string" && v ? v : null }
  return {
    present: raw.present === true,
    modes: Array.isArray(raw.modes) ? raw.modes.filter(function (m) { return typeof m === "string" }) : [],
    mode: s(raw.mode), start: n(raw.start), end: n(raw.end), full: n(raw.full), design: n(raw.design),
    cycles: n(raw.cycles), percent: n(raw.percent), status: s(raw.status), tempC: n(raw.tempC),
    ac: raw.ac === true, made: s(raw.made)
  }
}

function healthPct(snapshot) {
  var sn = snapshot || {}
  if (!(sn.full > 0) || !(sn.design > 0)) return null
  return Math.round(sn.full / sn.design * 1000) / 10
}

var HELPER_PATH = "/usr/local/bin/esemczak-battery-helper"

function actionResult(exitCode) {
  if (exitCode === 0) return { ok: true, message: "Saved" }
  if (exitCode === 126 || exitCode === 127) return { ok: false, message: "Not changed" }
  if (exitCode === 2) return { ok: false, message: "Invalid value" }
  return { ok: false, message: "Couldn't write setting" }
}

// --- History and wear rate ---

var DAY_MS = 86400000
var MONTH_DAYS = 30.44

function parseHistory(text, now) {
  var out = []
  String(text || "").split("\n").forEach(function (line) {
    if (!line.trim()) return
    var o
    try { o = JSON.parse(line) } catch (e) { return }
    if (!o || typeof o !== "object") return
    if (typeof o.t !== "number" || !isFinite(o.t)) return
    if (typeof o.health !== "number" || !isFinite(o.health)) return
    if (o.t > now + DAY_MS) return
    out.push(o)
  })
  out.sort(function (a, b) { return a.t - b.t })
  return out
}

function median(values) {
  var v = values.slice().sort(function (a, b) { return a - b })
  var n = v.length
  if (n === 0) return null
  return n % 2 ? v[(n - 1) / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
}

function dailyMedians(samples) {
  var buckets = {}
  var order = []
  ;(samples || []).forEach(function (s) {
    if (s.seed) return
    var d = new Date(s.t)
    var key = d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate()
    if (!buckets[key]) {
      buckets[key] = { midday: new Date(d.getFullYear(), d.getMonth(), d.getDate(), 12).getTime(), values: [] }
      order.push(key)
    }
    buckets[key].values.push(s.health)
  })
  return order.map(function (k) { return { t: buckets[k].midday, health: median(buckets[k].values) } })
    .sort(function (a, b) { return a.t - b.t })
}

function wearRate(samples, now) {
  var all = dailyMedians(samples)
  var recent = all.filter(function (p) { return p.t >= now - 90 * DAY_MS })
  if (recent.length >= 2 && recent[recent.length - 1].t - recent[0].t >= 30 * DAY_MS) {
    var slopes = []
    for (var i = 0; i < recent.length; i++)
      for (var j = i + 1; j < recent.length; j++)
        slopes.push((recent[j].health - recent[i].health) / ((recent[j].t - recent[i].t) / DAY_MS))
    return { perMonth: median(slopes) * MONTH_DAYS, basis: "fit" }
  }
  var seed = null
  ;(samples || []).forEach(function (s) { if (s.seed && (!seed || s.t < seed.t)) seed = s })
  if (seed && all.length > 0) {
    var latest = all[all.length - 1]
    var days = (latest.t - seed.t) / DAY_MS
    if (days > 0) return { perMonth: (latest.health - seed.health) / days * MONTH_DAYS, basis: "estimate" }
  }
  return { perMonth: null, basis: "none" }
}

function projectFloorDate(health, perMonth, floor, now) {
  if (typeof perMonth !== "number" || !isFinite(perMonth) || perMonth >= 0) return null
  if (typeof health !== "number" || health <= floor) return null
  return now + (health - floor) / -perMonth * MONTH_DAYS * DAY_MS
}

// --- Health chart ---

var RANGE_DAYS = { "3m": 92, "1y": 365 }

function nextRange(key) {
  if (key === "3m") return "1y"
  if (key === "1y") return "all"
  return "3m"
}

// opts: { floor: number (default 80), warrantyEnd: epochMs|null }
// x and y are 0..1; y grows upward (1 = yMax).
function chartPoints(samples, rangeKey, now, opts) {
  var o = opts || {}
  var floor = typeof o.floor === "number" ? o.floor : 80
  var list = (samples || []).filter(function (s) { return s && typeof s.t === "number" && typeof s.health === "number" })
    .sort(function (a, b) { return a.t - b.t })
  var start
  if (rangeKey === "all") start = list.length ? list[0].t : now
  else start = now - (RANGE_DAYS[rangeKey] || RANGE_DAYS["3m"]) * DAY_MS
  var visible = list.filter(function (s) { return s.t >= start })
  var end = Math.max(now, visible.length ? visible[visible.length - 1].t : now)
  // Longer ranges reach out to the warranty end so its marker is visible ahead of time.
  if (rangeKey !== "3m" && typeof o.warrantyEnd === "number" && o.warrantyEnd > end) end = o.warrantyEnd
  var span = end - start
  function xOf(t) { return span > 0 ? Math.max(0, Math.min(1, (t - start) / span)) : 1 }
  var minHealth = visible.reduce(function (m, s) { return Math.min(m, s.health) }, Infinity)
  var yMax = 100
  var yMin = isFinite(minHealth) ? Math.min(75, Math.floor(minHealth) - 2) : 75
  function yOf(h) { return Math.max(0, Math.min(1, (h - yMin) / (yMax - yMin))) }
  var warrantyX = null
  if (typeof o.warrantyEnd === "number" && o.warrantyEnd >= start && o.warrantyEnd <= end) warrantyX = xOf(o.warrantyEnd)
  return {
    points: visible.map(function (s) { return { x: xOf(s.t), y: yOf(s.health), seed: s.seed === true } }),
    yMin: yMin, yMax: yMax,
    floorY: floor >= yMin && floor <= yMax ? yOf(floor) : null,
    warrantyX: warrantyX
  }
}

// --- Settings and alert evaluation ---

var DEFAULT_WARRANTY_END = "2027-04-30"
var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function parseEndOfDay(text) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(text || ""))
  if (!m) return null
  var y = Number(m[1]), mo = Number(m[2]) - 1, d = Number(m[3])
  var date = new Date(y, mo, d, 23, 59, 59, 999)
  if (date.getFullYear() !== y || date.getMonth() !== mo || date.getDate() !== d) return null
  return date.getTime()
}

function settingsFrom(entry) {
  var e = entry && typeof entry === "object" ? entry : {}
  var alerts = e.alerts && typeof e.alerts === "object" ? e.alerts : {}
  var warranty = parseEndOfDay(e.warrantyEnd)
  if (warranty === null) warranty = parseEndOfDay(DEFAULT_WARRANTY_END)
  return {
    showPercentage: e.showPercentage === true,
    warrantyEnd: warranty,
    healthFloor: typeof e.healthFloor === "number" && isFinite(e.healthFloor) ? e.healthFloor : 80,
    alertLimitIgnored: alerts.limitIgnored !== false,
    alertDegradation: alerts.degradation !== false
  }
}

function settingsFromShellConfig(jsonText) {
  var found = null
  try {
    var cfg = JSON.parse(jsonText)
    var layout = cfg && cfg.bar && cfg.bar.layout
    var sections = Array.isArray(layout) ? [layout] : (layout && typeof layout === "object" ? Object.keys(layout).map(function (k) { return layout[k] }) : [])
    sections.forEach(function (list) {
      if (found || !Array.isArray(list)) return
      list.forEach(function (item) {
        if (!found && item && typeof item === "object" && item.id === PLUGIN_ID) found = item
      })
    })
  } catch (e) { found = null }
  return settingsFrom(found || {})
}

function formatMonthYear(ms) {
  var d = new Date(ms)
  return MONTH_NAMES[d.getMonth()] + " " + d.getFullYear()
}

function inactiveAlert() { return { active: false, reason: "", text: "" } }
function inactiveDegradation() { return { active: false, reason: "", text: "", date: null, basis: "none" } }

function normaliseState(state) {
  var st = state && typeof state === "object" ? state : {}
  var alerts = st.alerts && typeof st.alerts === "object" ? st.alerts : {}
  var notify = st.notify && typeof st.notify === "object" ? st.notify : {}
  var oc = st.overcharge && typeof st.overcharge === "object" ? st.overcharge : {}
  return {
    chosenMode: typeof st.chosenMode === "string" ? st.chosenMode : null,
    alerts: {
      limitIgnored: alerts.limitIgnored || inactiveAlert(),
      degradation: alerts.degradation || inactiveDegradation()
    },
    notify: {
      limitIgnoredSent: notify.limitIgnoredSent === true,
      degradationLastSent: typeof notify.degradationLastSent === "number" ? notify.degradationLastSent : null
    },
    overcharge: {
      streak: typeof oc.streak === "number" ? oc.streak : 0,
      lastPercent: typeof oc.lastPercent === "number" ? oc.lastPercent : null
    }
  }
}

// True when a limit is set but the live charge mode is neither Custom nor the mode the user chose.
function limitModeIgnored(snapshot, chosenMode) {
  var sn = snapshot || {}
  return !!(sn.end !== null && sn.end !== undefined && sn.end < 100 && sn.modes && sn.modes.length > 0 &&
    sn.mode !== "Custom" && sn.mode !== chosenMode)
}

function evaluateAlerts(snapshot, samples, state, settings, now) {
  var sn = snapshot || {}
  var cfg = settings || settingsFrom({})
  var st = normaliseState(state)
  var notifications = []
  var limit = inactiveAlert()
  var degr = inactiveDegradation()

  if (!sn.present) {
    st.overcharge = { streak: 0, lastPercent: null }
    st.notify.limitIgnoredSent = false
    st.alerts = { limitIgnored: limit, degradation: degr }
    return { state: st, notifications: notifications }
  }

  // Charge-limit-ignored: wrong mode, or charging past the limit in Custom mode.
  var modeIgnored = limitModeIgnored(sn, st.chosenMode)
  var over = !!(sn.end !== null && sn.end !== undefined && sn.end < 100 && sn.ac && sn.mode === "Custom" && sn.status === "Charging" && sn.percent > sn.end + 3 &&
    st.overcharge.lastPercent !== null && sn.percent > st.overcharge.lastPercent)
  st.overcharge.streak = over ? st.overcharge.streak + 1 : 0
  st.overcharge.lastPercent = typeof sn.percent === "number" ? sn.percent : null

  if (cfg.alertLimitIgnored) {
    if (modeIgnored) {
      limit = { active: true, reason: "mode",
        text: "Charge limit " + sn.start + "\u2013" + sn.end + "% is set but mode is " + sn.mode + ", so it's ignored." }
    } else if (st.overcharge.streak >= 2) {
      limit = { active: true, reason: "overcharge", text: "Charging past the " + sn.end + "% limit (" + sn.percent + "%)." }
    }
  }
  if (limit.active) {
    if (!st.notify.limitIgnoredSent) {
      st.notify.limitIgnoredSent = true
      notifications.push({ key: "limitIgnored", title: "Battery limit ignored", body: limit.text, urgency: "normal" })
    }
  } else {
    st.notify.limitIgnoredSent = false
  }

  // Degradation: projected to hit the health floor before the warranty ends.
  if (cfg.alertDegradation) {
    var latest = null
    ;(samples || []).forEach(function (s) {
      if (!s.seed && typeof s.health === "number" && (!latest || s.t > latest.t)) latest = s
    })
    var health = latest ? latest.health : healthPct(sn)
    var rate = wearRate(samples, now)
    var date = health === null ? null : projectFloorDate(health, rate.perMonth, cfg.healthFloor, now)
    if (date !== null && date < cfg.warrantyEnd) {
      var text = "At " + Math.abs(rate.perMonth).toFixed(1) + "%/month, health reaches " + cfg.healthFloor +
        "% around " + formatMonthYear(date) + ", before the warranty ends." + (rate.basis === "estimate" ? " (estimate)" : "")
      degr = { active: true, reason: "wear", text: text, date: date, basis: rate.basis }
      var last = st.notify.degradationLastSent
      if (rate.basis === "fit" && (last === null || now - last >= 7 * DAY_MS)) {
        st.notify.degradationLastSent = now
        notifications.push({ key: "degradation", title: "Battery wearing fast", body: text, urgency: "normal" })
      }
    }
  }

  st.alerts = { limitIgnored: limit, degradation: degr }
  return { state: st, notifications: notifications }
}

// ---- theme palette -----------------------------------------------------------

function parseThemeColors(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = /^\s*([A-Za-z0-9_]+)\s*=\s*"(#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3}))"\s*(?:#.*)?$/.exec(lines[i])
    if (m) out[m[1].toLowerCase()] = m[2]
  }
  return out
}

function semanticColors(palette, fallback) {
  var p = palette || {}
  var f = fallback || {}
  return {
    good: p.green || f.accent,
    warn: p.red || f.urgent,
    neutral: p.accent || f.accent,
    power: p.cyan || p.blue || f.accent,
    text: p.foreground || f.foreground,
    muted: p.muted || f.muted
  }
}

// ---- Power use (per-app share of measured draw) ----
var UNIT_NAMES = { "brave": "Brave", "xdg-terminal-exec": "Terminal", "code": "Code", "zen": "Zen", "firefox": "Firefox",
  "chromium": "Chromium", "obsidian": "Obsidian", "spotify": "Spotify", "nautilus": "Files" }

function parsePowerSample(text) {
  try {
    var o = JSON.parse(text)
    return (o && typeof o === "object" && Array.isArray(o.groups)) ? o : null
  } catch (e) { return null }
}

function unitLabel(path) {
  var seg = String(path).split("/").pop()
  seg = seg.replace(/\\x([0-9a-fA-F]{2})/g, function (_, h) { return String.fromCharCode(parseInt(h, 16)) })
  if (seg === "wayland-wm@hyprland.desktop.service") return "Desktop"
  if (/^session-\d+\.scope$/.test(seg)) return "Login session"
  var m = /^app-(.+)\.scope$/.exec(seg)
  if (m) {
    var inner = m[1]
    var parts = inner.split("-")
    // app-<launcher>-<name>-<hex>: name sits between the launcher and the trailing hex id
    var hm = /^[^-.]+-(.+)-[0-9a-fA-F]+$/.exec(inner)
    if (hm && UNIT_NAMES[hm[1]]) return UNIT_NAMES[hm[1]]
    if (hm && !/\./.test(inner)) return cap(hm[1])
    // app-<reverse.dns.Name>-<n>
    var dm = /^(.+\..+?)-\d+$/.exec(inner)
    if (dm) { var labels = dm[1].split("."); return labels[labels.length - 1] }
    if (UNIT_NAMES[parts[0]]) return UNIT_NAMES[parts[0]]
  }
  seg = seg.replace(/^app-/, "").replace(/@.*$/, "").replace(/\.(service|scope|slice)$/, "")
  return cap(seg)
}

function cap(s) { return s.length ? s.charAt(0).toUpperCase() + s.slice(1) : s }

function appShares(samples) {
  if (!samples || samples.length < 2) return []
  var first = samples[0], last = samples[samples.length - 1]
  var start = {}
  for (var i = 0; i < first.groups.length; i++) start[first.groups[i].path] = first.groups[i].usec
  var sums = {}, total = 0
  for (var j = 0; j < last.groups.length; j++) {
    var g = last.groups[j]
    if (!(g.path in start)) continue
    var d = g.usec - start[g.path]
    if (!(d >= 0)) continue
    var label = unitLabel(g.path)
    sums[label] = (sums[label] || 0) + d
    total += d
  }
  if (total <= 0) return []
  return Object.keys(sums).map(function (l) { return { label: l, share: sums[l] / total } })
    .sort(function (a, b) { return b.share - a.share })
}

function powerRows(shares, sample, n) {
  if (!shares || !shares.length) return { mode: "measuring", rows: [] }
  var watts = sample && typeof sample.drawW === "number"
  var top = shares.slice(0, n)
  var max = top[0].share
  return {
    mode: watts ? "watts" : "cpu",
    rows: top.map(function (s) {
      return {
        label: s.label,
        value: watts ? Math.round(s.share * sample.drawW * 10) / 10 : Math.round(s.share * 100),
        unit: watts ? "W" : "%",
        fraction: max > 0 ? s.share / max : 0
      }
    })
  }
}

function appendDrawPoint(buffer, sample, nowMs) {
  var out = (buffer || []).filter(function (p) { return p.t >= nowMs - 300000 })
  if (sample && typeof sample.drawW === "number") {
    var prev = out.length ? out[out.length - 1] : null
    out.push({ t: nowMs, w: sample.drawW, gapBefore: prev !== null && nowMs - prev.t > 10000 })
  }
  return out.length > 150 ? out.slice(out.length - 150) : out
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    PLUGIN_ID: PLUGIN_ID, stateDir: stateDir,
    clampIndex: clampIndex, selectProfileIndex: selectProfileIndex,
    parseKeyValue: parseKeyValue, parseProfiles: parseProfiles, profileIcon: profileIcon,
    batteryFraction: batteryFraction, chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon, modeLabel: modeLabel,
    parseChargeTypes: parseChargeTypes, parseSnapshot: parseSnapshot, healthPct: healthPct,
    HELPER_PATH: HELPER_PATH, actionResult: actionResult,
    parseHistory: parseHistory, dailyMedians: dailyMedians, wearRate: wearRate,
    projectFloorDate: projectFloorDate, chartPoints: chartPoints, nextRange: nextRange,
    formatMonthYear: formatMonthYear,
    parseThemeColors: parseThemeColors, semanticColors: semanticColors,
    settingsFrom: settingsFrom, settingsFromShellConfig: settingsFromShellConfig, evaluateAlerts: evaluateAlerts, limitModeIgnored: limitModeIgnored,
    parsePowerSample: parsePowerSample, unitLabel: unitLabel, appShares: appShares,
    powerRows: powerRows, appendDrawPoint: appendDrawPoint
  }
}
