import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Background poller embedded directly inside Panel.qml (Service { }),
// following the pattern used by panels/tailscale/Service.qml. Owns:
// - reading the shared location file (read-only)
// - resolving lat/lon -> NWS radar station via api.weather.gov/points
// - reading the newest radar frame timestamp from the NWS GeoServer WMS
// - polling api.weather.gov/alerts/active on a timer
// - deduping + notifying newly-seen, above-threshold alerts
Item {
  id: root

  property var settings: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  readonly property int alertPollIntervalSec: intSetting("alertPollIntervalSec", 300, 60, 3600)
  readonly property int radarRefreshIntervalSec: intSetting("radarRefreshIntervalSec", 300, 60, 1800)
  readonly property int radarRangeMiles: intSetting("radarRangeMiles", 150, 25, 500)
  readonly property string minNotifySeverity: String(setting("minNotifySeverity", "Moderate"))
  readonly property string userAgentContact: String(setting("userAgentContact", ""))
  readonly property bool configured: userAgentContact.trim() !== ""
  readonly property string appName: "OmarchyNwsRadar"
  readonly property string userAgent: Model.userAgentHeader(appName, userAgentContact)

  // Location, read-only from the file the built-in Weather plugin owns.
  property var locationState: ({ name: "", latitude: null, longitude: null })
  property string locationSource: ""
  property bool autoLocationAttempted: false
  property string locationError: ""
  readonly property string locationName: locationState.name
  readonly property real latitude: locationState.latitude
  readonly property real longitude: locationState.longitude
  readonly property bool hasLocation: locationState.latitude !== null && locationState.longitude !== null
  readonly property bool detectingLocation: autoLocationProc.running

  function applyLocationFile(raw) {
    var parsed = Model.parseLocationFile(raw)
    if (parsed.latitude !== null && parsed.longitude !== null) {
      root.locationSource = "weather"
      root.locationError = ""
      root.locationState = parsed
      return
    }

    // A missing file means Weather is using IP auto-detection. Preserve an
    // already-resolved automatic location across FileView reloads; otherwise
    // resolve the same wttr.in nearest-area data ourselves.
    if (root.locationSource === "weather") {
      root.locationState = ({ name: "", latitude: null, longitude: null })
      root.locationSource = ""
      root.autoLocationAttempted = false
    }
    requestAutoLocation(false)
  }

  function requestAutoLocation(force) {
    if (root.locationSource === "weather" || autoLocationProc.running) return
    if (root.autoLocationAttempted && !force) return
    root.autoLocationAttempted = true
    root.locationError = ""
    autoLocationProc.command = ["curl", "-fsS", "--max-time", "10", "https://wttr.in/?format=j1"]
    autoLocationProc.running = true
  }

  property FileView locationFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyLocationFile(text())
    onLoadFailed: root.applyLocationFile("")
  }

  property string stationId: ""
  property string _stationForLatLon: ""

  // Timestamp of the newest radar frame published by the NWS GeoServer, read
  // from the layer's GetCapabilities. Drives both the TIME= parameter on the
  // image request and the "as of" label under it.
  property string frameTime: ""

  property var alerts: []
  // The severity setting controls notifications only. The panel and bar icon
  // always represent the complete active feed for the configured location.
  readonly property var activeAlerts: alerts
  readonly property int activeAlertCount: activeAlerts.length
  readonly property bool hasActiveAlerts: activeAlertCount > 0
  property string lastError: ""

  PersistentProperties {
    id: persisted
    reloadableId: "stdasi-weather-radar-alerts"
    property string notifiedIdsJson: "[]"
  }

  function notifiedIds() {
    try {
      var parsed = JSON.parse(persisted.notifiedIdsJson)
      return parsed instanceof Array ? parsed : []
    } catch (e) {
      return []
    }
  }

  function saveNotifiedIds(ids) {
    persisted.notifiedIdsJson = JSON.stringify(ids)
  }

  function refreshNow() {
    locationFile.reload()
    if (root.locationSource !== "weather") requestAutoLocation(true)
    refreshRadarFrame()
    if (root.hasLocation) fetchAlerts()
  }

  // The GeoServer radar service needs no API contact, so this is gated on
  // location alone — the radar renders before userAgentContact is configured.
  function refreshRadarFrame() {
    if (!root.hasLocation) return
    if (capsProc.running) return
    capsProc.command = ["curl", "-fsSL", "--max-time", "10",
      Model.radarCapabilitiesUrl(Model.radarRegion(root.latitude, root.longitude))]
    capsProc.running = true
  }

  // api.weather.gov rejects/redirects points requests with more than ~4
  // decimal places of precision (HTTP 301 "AdjustPointPrecision"). Round to
  // avoid depending on curl's redirect handling.
  function roundedCoord(value) {
    return Math.round(value * 10000) / 10000
  }

  function ensureStation() {
    if (!root.hasLocation) return
    var key = root.latitude + "," + root.longitude
    if (key === root._stationForLatLon) return
    if (pointsProc.running) return
    root._stationForLatLon = key
    pointsProc.command = ["curl", "-fsSL", "--max-time", "10", "-H", root.userAgent,
      "https://api.weather.gov/points/" + roundedCoord(root.latitude) + "," + roundedCoord(root.longitude)]
    pointsProc.running = true
  }

  function fetchAlerts() {
    if (!root.configured || !root.hasLocation) return
    ensureStation()
    if (alertsProc.running) return
    alertsProc.command = ["curl", "-fsSL", "--max-time", "10", "-H", root.userAgent,
      "https://api.weather.gov/alerts/active?point=" + roundedCoord(root.latitude) + "," + roundedCoord(root.longitude)]
    alertsProc.running = true
  }

  function handleAlertsResponse(raw) {
    var parsed = Model.parseAlerts(raw)
    root.alerts = parsed
    var notified = Model.trimExpiredIds(notifiedIds(), parsed)

    for (var i = 0; i < parsed.length; i++) {
      var alert = parsed[i]
      if (notified.indexOf(alert.id) !== -1) continue
      notified.push(alert.id)
      if (Model.severityMeetsThreshold(alert.severity, root.minNotifySeverity)) queueNotification(alert)
    }
    saveNotifiedIds(notified)
  }

  property var _notifyQueue: []

  function queueNotification(alert) {
    root._notifyQueue.push(alert)
    drainNotifyQueue()
  }

  function drainNotifyQueue() {
    if (notifyProc.running) return
    if (root._notifyQueue.length === 0) return
    var alert = root._notifyQueue.shift()
    notifyProc.command = Model.notificationCommand(alert)
    notifyProc.running = true
  }

  onLocationStateChanged: {
    root._stationForLatLon = ""
    root.stationId = ""
    root.frameTime = ""
    refreshRadarFrame()
    if (root.hasLocation) fetchAlerts()
  }

  Process {
    id: autoLocationProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // An explicit Weather location may have arrived while this request was
        // running; it always wins over automatic detection.
        if (root.locationSource === "weather") return
        var parsed = Model.parseAutoLocationResponse(text)
        if (parsed.latitude === null || parsed.longitude === null) {
          root.locationError = "Could not auto-detect a location. Set one in the built-in Weather widget, then refresh."
          return
        }
        root.locationError = ""
        root.locationSource = "auto"
        root.locationState = parsed
      }
    }
  }

  Process {
    id: capsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseRadarFrameTime(text)
        if (parsed !== "") root.frameTime = parsed
      }
    }
  }

  Process {
    id: pointsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parsePointsResponse(text)
        if (parsed.radarStation !== "") root.stationId = parsed.radarStation
      }
    }
  }

  Process {
    id: alertsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") {
          root.lastError = "No response from api.weather.gov"
          return
        }
        root.lastError = ""
        root.handleAlertsResponse(raw)
      }
    }
  }

  Process { id: notifyProc; onExited: root.drainNotifyQueue() }

  Timer {
    interval: root.alertPollIntervalSec * 1000
    running: root.configured
    repeat: true
    triggeredOnStart: true
    onTriggered: root.fetchAlerts()
  }
}
