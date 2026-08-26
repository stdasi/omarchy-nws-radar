// Pure parsing/mapping helpers, no QML dependencies. Mirrors the separation
// used by the built-in Weather plugin's Model.js.

// weather.json holds {"name": ..., "latitude": ..., "longitude": ...},
// owned by omarchy-weather-location. Missing/blank/unparseable means no
// location is configured yet.
function parseLocationFile(raw) {
  var unset = { name: "", latitude: null, longitude: null }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset

    var latitude = parseFloat(data.latitude)
    var longitude = parseFloat(data.longitude)
    var hasCoordinates = !isNaN(latitude) && !isNaN(longitude)
    return {
      name: typeof data.name === "string" ? data.name.replace(/^\s+|\s+$/g, "") : "",
      latitude: hasCoordinates ? latitude : null,
      longitude: hasCoordinates ? longitude : null
    }
  } catch (e) {
    return unset
  }
}

// wttr.in j1 response -> the IP-detected nearest area. This is the same
// source the built-in Weather panel uses when weather.json is absent.
function parseAutoLocationResponse(raw) {
  var unset = { name: "", latitude: null, longitude: null }
  try {
    var data = JSON.parse(String(raw || ""))
    var areas = data && data.nearest_area ? data.nearest_area : []
    var area = areas.length ? areas[0] : null
    if (!area) return unset

    var latitude = parseFloat(area.latitude)
    var longitude = parseFloat(area.longitude)
    if (!isFinite(latitude) || !isFinite(longitude)
        || latitude < -90 || latitude > 90
        || longitude < -180 || longitude > 180) return unset

    function firstValue(field) {
      return field && field.length && field[0] && field[0].value
        ? String(field[0].value).replace(/^\s+|\s+$/g, "") : ""
    }

    var parts = [firstValue(area.areaName), firstValue(area.region), firstValue(area.country)]
    var names = []
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] !== "" && names.indexOf(parts[i]) === -1) names.push(parts[i])
    }
    return { name: names.join(", "), latitude: latitude, longitude: longitude }
  } catch (e) {
    return unset
  }
}

// api.weather.gov /points/{lat},{lon} response -> {radarStation, forecastZone, county}.
function parsePointsResponse(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var props = data && data.properties ? data.properties : {}
    return {
      radarStation: typeof props.radarStation === "string" ? props.radarStation : "",
      forecastZone: typeof props.forecastZone === "string" ? props.forecastZone : "",
      county: typeof props.county === "string" ? props.county : ""
    }
  } catch (e) {
    return { radarStation: "", forecastZone: "", county: "" }
  }
}

// api.weather.gov /alerts/active response (GeoJSON FeatureCollection) ->
// [{id, event, severity, urgency, headline, description, effective, expires}].
function parseAlerts(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var features = data && data.features ? data.features : []
    var out = []
    for (var i = 0; i < features.length; i++) {
      var props = features[i] && features[i].properties ? features[i].properties : null
      if (!props || !props.id) continue
      out.push({
        id: String(props.id),
        event: String(props.event || "Alert"),
        severity: String(props.severity || "Unknown"),
        urgency: String(props.urgency || "Unknown"),
        headline: String(props.headline || props.event || "Weather alert"),
        description: String(props.description || ""),
        effective: String(props.effective || ""),
        expires: String(props.expires || "")
      })
    }
    return out
  } catch (e) {
    return []
  }
}

var SEVERITY_RANK = { "Extreme": 4, "Severe": 3, "Moderate": 2, "Minor": 1, "Unknown": 0 }

function severityRank(severity) {
  return SEVERITY_RANK[String(severity || "Unknown")] !== undefined
    ? SEVERITY_RANK[String(severity || "Unknown")]
    : 0
}

function severityMeetsThreshold(severity, threshold) {
  return severityRank(severity) >= severityRank(threshold)
}

function severityToUrgency(severity) {
  var rank = severityRank(severity)
  if (rank >= 3) return "critical" // Extreme, Severe
  if (rank === 2) return "normal"  // Moderate
  return "low"                     // Minor, Unknown
}

// ---------------------------------------------------------------------------
// Radar imagery, from the NWS GeoServer WMS that backs radar.weather.gov:
// https://opengeo.ncep.noaa.gov/geoserver — free, keyless, no User-Agent policy.
//
// The MRMS "quality controlled base reflectivity" mosaic (<region>_bref_qcd) is
// 1 km and lands a new frame roughly every two minutes, versus the ~5 minute
// regeneration of the RIDGE II loop GIFs this replaced.
// ---------------------------------------------------------------------------

var GEOSERVER = "https://opengeo.ncep.noaa.gov/geoserver"

// The mosaic is published per region; pick the workspace covering the point.
// Bounds come from each layer's GetCapabilities. First match wins, because the
// CONUS extent nominally overlaps the Caribbean and southern Alaska.
function radarRegion(latitude, longitude) {
  var lat = parseFloat(latitude)
  var lon = parseFloat(longitude)
  if (isNaN(lat) || isNaN(lon)) return "conus"
  if (lon >= 140) return "guam"
  if (lon >= -164 && lon <= -151 && lat >= 15 && lat <= 26) return "hawaii"
  if (lat > 50) return "alaska"
  if (lat < 24 && lon > -90) return "carib"
  return "conus"
}

// Per-layer GetCapabilities (~8 KB) carries the exact newest frame timestamp.
function radarCapabilitiesUrl(region) {
  var layer = String(region || "conus") + "_bref_qcd"
  return GEOSERVER + "/" + encodeURIComponent(String(region || "conus")) + "/"
    + encodeURIComponent(layer) + "/ows"
    + "?service=WMS&version=1.3.0&request=GetCapabilities"
}

// Pull default="..." off the layer's <Dimension name="time">. No XML parser is
// available here, and the attribute is unambiguous enough for a regex.
function parseRadarFrameTime(raw) {
  try {
    var xml = String(raw || "")
    var dimension = xml.match(/<Dimension[^>]*name="time"[^>]*>/i)
    if (!dimension) return ""
    var value = dimension[0].match(/default="([^"]*)"/i)
    return value ? value[1] : ""
  } catch (e) {
    return ""
  }
}

var EARTH_RADIUS_M = 6378137
var METERS_PER_MILE = 1609.34

// Web Mercator (EPSG:3857) forward projection. Requesting in 3857 rather than
// 4326 keeps the bbox aspect matched to the pixel aspect, so the map is not
// stretched by latitude.
function mercatorX(longitude) {
  return EARTH_RADIUS_M * (longitude * Math.PI / 180)
}

function mercatorY(latitude) {
  var clamped = Math.max(-85.05112878, Math.min(85.05112878, latitude))
  return EARTH_RADIUS_M * Math.log(Math.tan(Math.PI / 4 + (clamped * Math.PI / 180) / 2))
}

// "minx,miny,maxx,maxy" centred on the point, rangeMeters to the left and
// right, scaled vertically to the requested pixel aspect ratio.
function radarBbox3857(latitude, longitude, rangeMeters, width, height) {
  var centerX = mercatorX(longitude)
  var centerY = mercatorY(latitude)
  var halfWidth = rangeMeters
  var halfHeight = rangeMeters * (height / width)
  return [centerX - halfWidth, centerY - halfHeight,
          centerX + halfWidth, centerY + halfHeight].join(",")
}

// One composite GetMap against the root /ows endpoint renders every layer
// server-side, bottom to top:
//
//   nws:us_counties / boundary_gray      light county outlines
//   wwa:hazards     / wwa:wwa_hazards    watch + advisory fills
//   <region>_bref_qcd / radar_reflectivity   the radar mosaic
//   wwa:warnings    / wwa:wwa_warnings   warning outlines
//
// Ordering is deliberate. Hazard polygons are translucent fills, so drawing them
// *under* the radar keeps reflectivity vivid while the fill still reads across
// clear ground. Warnings sit on top, in the outline-only wwa:wwa_warnings style
// rather than wwa:wwa_warnings_fill, so a warning box never mutes the storm core
// it is drawn around.
//
// A single TIME= applies to every time-enabled layer in the request. All three
// declare nearestValue="1", so each snaps to its own nearest snapshot instead of
// coming back empty, and the hazards and warnings match the radar frame.
//
// nws:state_boundary is deliberately absent — both of its published styles draw
// black, which is invisible over a dark map, and county polygons already tile up
// to the state lines.
function radarImageUrl(options) {
  var opts = options || {}
  var latitude = parseFloat(opts.latitude)
  var longitude = parseFloat(opts.longitude)
  if (isNaN(latitude) || isNaN(longitude)) return ""

  var width = Math.max(1, Math.round(opts.width || 0))
  var height = Math.max(1, Math.round(opts.height || 0))
  if (width <= 1 || height <= 1) return ""

  var rangeMiles = parseFloat(opts.rangeMiles)
  if (!isFinite(rangeMiles) || rangeMiles <= 0) rangeMiles = 150
  var rangeMeters = rangeMiles * METERS_PER_MILE

  var region = radarRegion(latitude, longitude)
  var params = [
    "service=WMS",
    "version=1.1.1",
    "request=GetMap",
    "layers=" + encodeURIComponent("nws:us_counties,wwa:hazards,"
      + region + ":" + region + "_bref_qcd,wwa:warnings"),
    "styles=" + encodeURIComponent("boundary_gray,wwa:wwa_hazards,radar_reflectivity,wwa:wwa_warnings"),
    "format=" + encodeURIComponent("image/png"),
    "transparent=true",
    "srs=EPSG:3857",
    "bbox=" + encodeURIComponent(radarBbox3857(latitude, longitude, rangeMeters, width, height)),
    "width=" + width,
    "height=" + height
  ]

  // Pinning TIME to the frame we read from GetCapabilities makes the "as of"
  // label match the pixels exactly, and changes the URL whenever a new frame
  // lands — which is also what busts Qt's image cache.
  var frameTime = String(opts.frameTime || "")
  if (frameTime !== "") params.push("TIME=" + encodeURIComponent(frameTime))

  return GEOSERVER + "/ows?" + params.join("&")
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

// "11:58 PM \u00b7 2 min ago" for the frame timestamp under the image, so a
// stale radar picture is visible rather than assumed fresh.
function formatFrameAge(iso, nowMs) {
  var raw = String(iso || "")
  if (raw === "") return ""
  var frame = new Date(raw)
  var frameMs = frame.getTime()
  if (isNaN(frameMs)) return ""

  var hours = frame.getHours()
  var suffix = hours >= 12 ? "PM" : "AM"
  var hour12 = hours % 12
  if (hour12 === 0) hour12 = 12
  var clock = hour12 + ":" + pad2(frame.getMinutes()) + " " + suffix

  var minutes = Math.floor((nowMs - frameMs) / 60000)
  if (minutes < 0) minutes = 0
  var age = minutes < 1 ? "just now"
    : minutes === 1 ? "1 min ago"
    : minutes < 90 ? minutes + " min ago"
    : Math.round(minutes / 60) + " hr ago"

  return clock + " \u00b7 " + age
}

// Minutes between the frame timestamp and now; -1 when unknown. Used to flag a
// frame that has gone stale.
function frameAgeMinutes(iso, nowMs) {
  var raw = String(iso || "")
  if (raw === "") return -1
  var frameMs = new Date(raw).getTime()
  if (isNaN(frameMs)) return -1
  return Math.max(0, Math.floor((nowMs - frameMs) / 60000))
}

// Drop ids for alerts that are no longer in the current feed (expired or
// otherwise dropped), keeping the dedup set from growing unbounded.
function trimExpiredIds(notifiedIds, currentAlerts) {
  var currentIds = {}
  for (var i = 0; i < currentAlerts.length; i++) currentIds[currentAlerts[i].id] = true
  var kept = []
  for (var j = 0; j < notifiedIds.length; j++) {
    if (currentIds[notifiedIds[j]]) kept.push(notifiedIds[j])
  }
  return kept
}

function userAgentHeader(appName, contact) {
  return "User-Agent: " + appName + " (" + contact + ")"
}

// omarchy-notification-send parses notification content before --exec, and
// requires the click command as separate argv entries. Keeping this assembly
// here makes the ordering testable and ensures alert text remains plain data.
function notificationCommand(alert) {
  var item = alert || {}
  return [
    "omarchy-notification-send",
    "--app-name", "NWS Radar",
    "-u", severityToUrgency(item.severity),
    String(item.headline || "Weather alert"),
    String(item.description || ""),
    "--exec", "omarchy-shell", "shell", "summon", "stdasi.nws-radar"
  ]
}

if (typeof module !== "undefined") {
  module.exports = {
    parseLocationFile: parseLocationFile,
    parseAutoLocationResponse: parseAutoLocationResponse,
    parsePointsResponse: parsePointsResponse,
    parseAlerts: parseAlerts,
    severityRank: severityRank,
    severityMeetsThreshold: severityMeetsThreshold,
    severityToUrgency: severityToUrgency,
    radarRegion: radarRegion,
    radarCapabilitiesUrl: radarCapabilitiesUrl,
    parseRadarFrameTime: parseRadarFrameTime,
    radarBbox3857: radarBbox3857,
    radarImageUrl: radarImageUrl,
    formatFrameAge: formatFrameAge,
    frameAgeMinutes: frameAgeMinutes,
    trimExpiredIds: trimExpiredIds,
    userAgentHeader: userAgentHeader,
    notificationCommand: notificationCommand
  }
}
