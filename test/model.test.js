const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("parses and validates shared Weather locations", () => {
  assert.deepEqual(Model.parseLocationFile('{"name":" Amarillo ","latitude":35.2,"longitude":-101.8}'), {
    name: "Amarillo", latitude: 35.2, longitude: -101.8
  })
  assert.deepEqual(Model.parseLocationFile("not json"), {
    name: "", latitude: null, longitude: null
  })
})

test("parses an IP-detected wttr.in nearest area", () => {
  const location = Model.parseAutoLocationResponse(JSON.stringify({ nearest_area: [{
    areaName: [{ value: "Amarillo" }],
    region: [{ value: "Texas" }],
    country: [{ value: "United States of America" }],
    latitude: "35.207", longitude: "-101.834"
  }] }))
  assert.deepEqual(location, {
    name: "Amarillo, Texas, United States of America",
    latitude: 35.207,
    longitude: -101.834
  })
  assert.deepEqual(Model.parseAutoLocationResponse("invalid"), {
    name: "", latitude: null, longitude: null
  })
})

test("parses NWS alerts and supplies safe defaults", () => {
  const alerts = Model.parseAlerts(JSON.stringify({ features: [{ properties: {
    id: "alert-1", event: "Thunderstorm Warning", severity: "Severe",
    headline: "Storm approaching", description: "Take shelter"
  } }] }))
  assert.equal(alerts.length, 1)
  assert.equal(alerts[0].id, "alert-1")
  assert.equal(alerts[0].urgency, "Unknown")
  assert.deepEqual(Model.parseAlerts("invalid"), [])
})

test("ranks severity thresholds and notification urgency", () => {
  assert.equal(Model.severityMeetsThreshold("Severe", "Moderate"), true)
  assert.equal(Model.severityMeetsThreshold("Minor", "Moderate"), false)
  assert.equal(Model.severityToUrgency("Extreme"), "critical")
  assert.equal(Model.severityToUrgency("Moderate"), "normal")
  assert.equal(Model.severityToUrgency("Unknown"), "low")
})

test("selects radar regions", () => {
  assert.equal(Model.radarRegion(35.2, -101.8), "conus")
  assert.equal(Model.radarRegion(61.2, -149.9), "alaska")
  assert.equal(Model.radarRegion(21.3, -157.8), "hawaii")
  assert.equal(Model.radarRegion(13.4, 144.8), "guam")
  assert.equal(Model.radarRegion(18.5, -66.1), "carib")
})

test("parses WMS time and builds a pinned radar URL", () => {
  const time = Model.parseRadarFrameTime('<Dimension name="time" default="2026-08-25T22:00:00Z"/>')
  assert.equal(time, "2026-08-25T22:00:00Z")
  const url = new URL(Model.radarImageUrl({
    latitude: 35.2, longitude: -101.8, rangeMiles: 150,
    width: 800, height: 600, frameTime: time
  }))
  assert.equal(url.hostname, "opengeo.ncep.noaa.gov")
  assert.equal(url.searchParams.get("width"), "800")
  assert.equal(url.searchParams.get("height"), "600")
  assert.equal(url.searchParams.get("TIME"), time)
  assert.match(url.searchParams.get("layers"), /conus:conus_bref_qcd/)
})

test("formats frame age and trims expired notification ids", () => {
  const now = Date.parse("2026-08-25T22:05:00Z")
  assert.match(Model.formatFrameAge("2026-08-25T22:03:00Z", now), /2 min ago$/)
  assert.equal(Model.frameAgeMinutes("2026-08-25T22:03:00Z", now), 2)
  assert.deepEqual(Model.trimExpiredIds(["old", "current"], [{ id: "current" }]), ["current"])
})

test("builds the notification command with content before a split click command", () => {
  const command = Model.notificationCommand({
    severity: "Severe",
    headline: "--exec is weather text",
    description: "$(touch /tmp/not-a-command)"
  })
  assert.deepEqual(command, [
    "omarchy-notification-send",
    "--app-name", "NWS Radar",
    "-u", "critical",
    "--exec is weather text",
    "$(touch /tmp/not-a-command)",
    "--exec", "omarchy-shell", "shell", "summon", "stdasi.nws-radar"
  ])
})

test("builds the required NWS User-Agent header", () => {
  assert.equal(Model.userAgentHeader("OmarchyNwsRadar", "user@example.com"),
    "User-Agent: OmarchyNwsRadar (user@example.com)")
})
