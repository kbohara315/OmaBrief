import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Herald bar pill: rotating headline ticker with an unread dot.
// Click toggles the story popup; middle-click refreshes; right-click opens
// the fullscreen reader. Owns the popup + reader loaders and syncs widget
// settings down to the service's config file.
BarWidget {
  id: root
  moduleName: "kshitij.herald"

  // Own service singleton via the bar's scoped shell facade. Null until the
  // service loads (or under a replacement bar, which gets no services).
  readonly property var herald: (bar && bar.shell && typeof bar.shell.serviceFor === "function")
    ? bar.shell.serviceFor("kshitij.herald") : null

  readonly property var feedItems: herald ? herald.items : []
  readonly property var readMap: herald ? herald.readIds : ({})
  readonly property int unreadCount: herald ? herald.unread : 0
  readonly property bool isRefreshing: herald ? herald.refreshing : false
  readonly property bool useScores: herald ? herald.showScores : (setting("showScores", true) !== false)

  readonly property int tickerSeconds: Model.clampInt(setting("tickerSeconds", 6), 6, 0, 120)
  property int tickerIndex: 0

  readonly property string headline: {
    if (feedItems.length === 0) return herald && herald.refreshing ? "Herald fetching…" : "Herald"
    var item = feedItems[tickerIndex % feedItems.length]
    return item ? String(item.title || "Herald") : "Herald"
  }

  function serviceRefresh() {
    if (herald && typeof herald.refresh === "function") herald.refresh()
  }

  // ---- Shape contract for shell.summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function openReader(item) {
    if (readerLoader.item) readerLoader.item.openWith(item || null)
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("herald" in target) target.herald = root.herald
  }

  function injectReader() {
    var target = readerLoader.item
    if (!target) return
    if ("herald" in target) target.herald = root.herald
    if ("bar" in target) target.bar = root.bar
  }

  // Push shell.json settings down to the service config + feeds file.
  function syncConfig() {
    if (!root.herald) return
    var feeds = Model.parseFeeds(setting("feeds", "hn:top:30\nhttps://hackernewsrss.com/feed.xml"))
    var config = {
      refreshMinutes: Model.clampInt(setting("refreshMinutes", 15), 15, 2, 1440),
      storyCount: Model.clampInt(setting("storyCount", 30), 30, 1, 100),
      maxItemsPerFeed: Model.clampInt(setting("maxItemsPerFeed", 30), 30, 1, 100),
      digestTime: String(setting("digestTime", "09:00") || ""),
      aiEnabled: setting("aiEnabled", false) === true,
      aiCommand: String(setting("aiCommand", "ollama run llama3.1") || ""),
      showScores: setting("showScores", true) !== false,
      feeds: feeds
    }
    configProc.command = ["bash", root.herald.fetchScript, root.herald.stateDir,
      "write-config", JSON.stringify(config)]
    configProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: { injectPanel(); syncConfig() }
  onHeraldChanged: { injectPanel(); injectReader(); syncConfig() }

  Component.onCompleted: Qt.callLater(syncConfig)

  Timer {
    interval: Math.max(1, root.tickerSeconds) * 1000
    running: root.tickerSeconds > 0 && root.feedItems.length > 1
    repeat: true
    onTriggered: root.tickerIndex = (root.tickerIndex + 1) % Math.max(1, root.feedItems.length)
  }

  Process {
    id: configProc
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Loader {
    id: readerLoader
    active: true
    source: Qt.resolvedUrl("Reader.qml")
    visible: false
    onLoaded: {
      root.injectReader()
      Qt.callLater(root.injectReader)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: (root.unreadCount > 0 ? root.unreadCount + " unread · " : "") + root.headline

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.serviceRefresh()
      else if (b === Qt.RightButton) root.openReader(null)
      else root.togglePanel()
    }

    // Icon-only pill: the headline lives in the tooltip so long titles can
    // never push neighboring widgets aside (or overlap them).
    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: "󰈙"
      color: button.foreground
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
    }
  }

  // Unread dot, same mark every icon widget gets.
  Rectangle {
    visible: root.unreadCount > 0 && !root.vertical
    width: 6
    height: 6
    radius: 3
    color: Color.accent
    anchors.right: parent.right
    anchors.rightMargin: 4
    anchors.top: parent.top
    anchors.topMargin: 4
  }
}
