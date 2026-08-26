import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "stdasi.nws-radar"
  ipcTarget: "stdasi.nws-radar"

  readonly property color barForegroundColor: bar ? bar.barForeground : Color.foreground
  readonly property color barIconColor: radar.hasActiveAlerts ? Color.urgent : barForegroundColor

  // Built from the image's own on-screen size, at 2x for HiDPI crispness and
  // capped so a wide panel cannot ask GeoServer for an unreasonable render.
  // Taking the size as arguments keeps the binding local to the Image, which
  // avoids depending on when the popup's content gets instantiated.
  function radarUrlFor(itemWidth, itemHeight) {
    if (!radar.hasLocation) return ""
    var w = Math.min(1200, Math.round(itemWidth * 2))
    var h = Math.min(900, Math.round(itemHeight * 2))
    if (w < 2 || h < 2) return ""
    return Model.radarImageUrl({
      latitude: radar.latitude,
      longitude: radar.longitude,
      rangeMiles: radar.radarRangeMiles,
      width: w,
      height: h,
      frameTime: radar.frameTime
    })
  }

  // Re-evaluated on every refresh so the age text keeps counting up.
  property double nowMs: Date.now()
  readonly property string frameLabel: Model.formatFrameAge(radar.frameTime, nowMs)
  readonly property int frameAge: Model.frameAgeMinutes(radar.frameTime, nowMs)

  function refreshRadar() {
    nowMs = Date.now()
    radar.refreshRadarFrame()
  }

  onOpenedChanged: if (opened) {
    radar.refreshNow()
    nowMs = Date.now()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: radar
    settings: root.settings
  }

  Timer {
    interval: radar.radarRefreshIntervalSec * 1000
    running: root.opened && radar.hasLocation
    repeat: true
    onTriggered: root.refreshRadar()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        // OpticalGlyph is what BarIconButton uses for its own glyphs: it keeps
        // the mark optically centred in the 16px canvas and renders natively,
        // which matters at this size.
        OpticalGlyph {
          anchors.fill: parent
          // U+F0437 nf-md-radar, written as a surrogate pair. "\uf0437" does
          // not work here: a JS \u escape takes exactly four hex digits, so the
          // trailing "7" falls out as a literal character.
          text: "\udb81\udc37"
          fontFamily: Style.font.family
          fontSize: Style.bar.iconFont
          color: root.barIconColor
        }

        // Presence-only alert dot; the count itself lives in the panel below.
        // The background-coloured ring is what keeps it legible against the
        // glyph, matching panels/tailscale/TailscaleIcon.qml.
        BorderSurface {
          visible: radar.hasActiveAlerts
          width: Math.max(5, parent.width * 0.34)
          height: width
          radius: width / 2
          color: Color.urgent
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          borderSpec: Border.flat(Color.popups.background, 1)
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) radar.refreshNow()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") { radar.refreshNow(); root.nowMs = Date.now() } }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: radar.locationName !== "" ? radar.locationName : "No location configured"
              color: root.barForegroundColor
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width - (stationLabel.visible ? stationLabel.implicitWidth + Style.space(8) : 0)
            }

            Text {
              id: stationLabel
              visible: radar.stationId !== ""
              text: radar.stationId
              color: Qt.darker(root.barForegroundColor, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            visible: !radar.configured
            width: parent.width
            text: "Set an NWS API contact (email or URL) in this widget's settings before it will poll api.weather.gov."
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: radar.configured && !radar.hasLocation
            width: parent.width
            text: "No location set. Configure one in the built-in Weather widget."
            color: Qt.darker(root.barForegroundColor, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: radar.lastError !== ""
            width: parent.width
            text: radar.lastError
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---- Radar image
          // Fixed dark slate rather than a theme colour: the WMS layers are
          // styled for a dark map, and the light county lines would wash out
          // over a light Omarchy theme.
          Rectangle {
            id: radarFrame
            visible: radar.hasLocation
            width: parent.width
            height: width * 0.75
            radius: Style.cornerRadius
            color: "#0e1116"
            clip: true

            Image {
              id: radarImage
              anchors.fill: parent
              fillMode: Image.PreserveAspectFit
              source: root.radarUrlFor(radarFrame.width, radarFrame.height)
              cache: false
              asynchronous: true
            }

            Text {
              anchors.centerIn: parent
              visible: radarImage.status === Image.Error
              text: "Radar image unavailable"
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              anchors.centerIn: parent
              visible: radarImage.status === Image.Loading
              text: "Loading radar…"
              color: "#8b95a3"
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }
          }

          Row {
            visible: radar.hasLocation && root.frameLabel !== ""
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: root.frameLabel
              // Frames land every ~2 minutes; anything past 10 is worth calling out.
              color: root.frameAge >= 10 ? Color.urgent : Qt.darker(root.barForegroundColor, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              text: radar.radarRangeMiles + " mi"
              color: Qt.darker(root.barForegroundColor, 1.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { foreground: root.barForegroundColor }

          PanelSectionHeader {
            text: "ACTIVE ALERTS"
            foreground: root.barForegroundColor
            fontFamily: Style.font.family
          }

          Text {
            visible: radar.activeAlerts.length === 0
            width: parent.width
            text: "No active alerts."
            color: Qt.darker(root.barForegroundColor, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Column {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: radar.activeAlerts

              Rectangle {
                required property var modelData
                width: column.width
                implicitHeight: alertColumn.implicitHeight + Style.space(16)
                radius: Style.cornerRadius
                color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.08)
                border.width: Style.space(1)
                border.color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.4)

                Column {
                  id: alertColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: Style.space(10)
                  spacing: Style.space(4)

                  Text {
                    width: parent.width
                    text: modelData.event + " · " + modelData.severity
                    color: Color.urgent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    width: parent.width
                    text: modelData.headline
                    color: root.barForegroundColor
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            text: "Press R to refresh · middle-click the icon to refresh"
            color: Qt.darker(root.barForegroundColor, 1.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
