import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Model.js" as Model

// Herald background service. Owns every byte of feed state: it polls
// fetch.sh on an interval, exposes the parsed item list and read-state to
// the bar widget, and fires the daily digest. The widget never fetches.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "kshitij.herald"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy/herald"
  readonly property string pluginDir: home + "/.config/omarchy/plugins/kshitij.herald"
  readonly property string fetchScript: pluginDir + "/fetch.sh"

  // ---- Cached state, fed by FileViews below. The shell holds only parsed
  //      items; raw payloads never leave fetch.sh.
  property var items: []
  property var readIds: ({})
  property int updatedAt: 0
  property bool lastOk: true
  property int lastErrors: 0
  property bool refreshing: false
  property int refreshMinutes: 15
  property string digestTime: "09:00"
  property string lastDigestDay: ""
  property bool aiEnabled: false
  property string aiCommand: "ollama run llama3.1"
  property bool showScores: true

  readonly property int unread: Model.unreadCount(items, readIds)
  readonly property var topStory: items.length > 0 ? items[0] : null

  // Cache paths published by the last article/thread fetch, watched by Reader.
  property string articlePath: ""
  property string threadPath: ""
  property string summary: ""

  function parseItemsFile(text) {
    try {
      var data = JSON.parse(text || "[]")
      root.items = Array.isArray(data) ? data : []
    } catch (e) {
      root.items = []
    }
  }

  function refresh() {
    if (root.refreshing || fetchProc.running) return
    root.refreshing = true
    fetchProc.command = ["bash", root.fetchScript, root.stateDir, "poll"]
    fetchProc.running = true
  }

  function runDigest() {
    digestProc.command = ["bash", root.fetchScript, root.stateDir, "digest"]
    digestProc.running = true
  }

  function markRead(id) {
    if (!id || root.readIds[id]) return
    var next = {}
    for (var k in root.readIds) next[k] = true
    next[id] = true
    root.readIds = next
    markProc.command = ["bash", root.fetchScript, root.stateDir, "mark-read", String(id)]
    markProc.running = true
  }

  function markAllRead() {
    var next = {}
    for (var i = 0; i < root.items.length; i++) next[root.items[i].id] = true
    root.readIds = next
    markAllProc.command = ["bash", root.fetchScript, root.stateDir, "mark-all-read"]
    markAllProc.running = true
  }

  function openLink(url) {
    if (!url) return
    if (String(url).indexOf("https://") !== 0 && String(url).indexOf("http://") !== 0) return
    openProc.command = ["xdg-open", String(url)]
    openProc.running = true
  }

  function fetchArticle(url, outPath) {
    root.articlePath = ""
    root.summary = ""
    articleProc.command = ["bash", root.fetchScript, root.stateDir, "article", String(url)]
    articleProc.running = true
  }

  function fetchThread(hnId) {
    root.threadPath = ""
    threadProc.command = ["bash", root.fetchScript, root.stateDir, "comments", String(hnId)]
    threadProc.running = true
  }

  function summarize(articleCachePath) {
    if (!root.aiEnabled || !root.aiCommand) return
    var parts = String(root.aiCommand).split(" ").filter(function(p) { return p !== "" })
    if (parts.length === 0) return
    // Article text flows file -> fetch.sh -> AI stdin; it never passes
    // through QML properties or the shell's command line.
    aiProc.command = ["bash", root.fetchScript, root.stateDir, "summarize", String(articleCachePath)].concat(parts)
    aiProc.running = true
  }

  function checkDigest() {
    if (Model.digestDue(root.digestTime, root.lastDigestDay, new Date())) root.runDigest()
  }

  // Config written by the bar widget whenever shell.json settings change.
  property FileView configFile: FileView {
    path: root.stateDir + "/config.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var c = JSON.parse(text() || "{}")
        root.refreshMinutes = Model.clampInt(c.refreshMinutes, 15, 2, 1440)
        root.digestTime = String(c.digestTime || "09:00")
        root.aiEnabled = c.aiEnabled === true
        root.aiCommand = String(c.aiCommand || "ollama run llama3.1")
        root.showScores = c.showScores !== false
      } catch (e) {}
      pollTimer.restart()
    }
  }

  property FileView itemsFile: FileView {
    path: root.stateDir + "/items.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseItemsFile(text())
    onLoadFailed: root.items = []
  }

  property FileView readFile: FileView {
    path: root.stateDir + "/read.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readIds = Model.parseReadJson(text())
    onLoadFailed: root.readIds = ({})
  }

  property FileView statusFile: FileView {
    path: root.stateDir + "/status.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var s = JSON.parse(text() || "{}")
        root.updatedAt = s.updatedAt || 0
        root.lastOk = s.ok !== false
        root.lastErrors = s.errors || 0
      } catch (e) {}
    }
  }

  property FileView digestDayFile: FileView {
    path: root.stateDir + "/digest-day.txt"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.lastDigestDay = String(text() || "").trim()
  }

  Process {
    id: fetchProc
    onExited: function(code) {
      root.refreshing = false
      itemsFile.reload()
      statusFile.reload()
      prefetchProc.command = ["bash", root.fetchScript, root.stateDir, "prefetch"]
      prefetchProc.running = true
    }
  }

  Process {
    id: prefetchProc
  }

  Process {
    id: digestProc
    onExited: function(code) { digestDayFile.reload() }
  }

  Process {
    id: markProc
    onExited: function(code) { readFile.reload() }
  }

  Process {
    id: markAllProc
    onExited: function(code) { readFile.reload() }
  }

  Process {
    id: openProc
  }

  Process {
    id: articleProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.articlePath = String(text || "").trim()
    }
  }

  Process {
    id: threadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.threadPath = String(text || "").trim()
    }
  }

  Process {
    id: aiProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: heraldAi.summaryReady(String(text || ""))
    }
  }

  // Fan-out target for the AI summary: set by the reader when it opens.
  QtObject {
    id: heraldAi
    signal summaryReady(string text)
  }
  property alias ai: heraldAi

  function onSummaryReady(text) {
    root.summary = text
  }

  Component.onCompleted: heraldAi.summaryReady.connect(onSummaryReady)

  Timer {
    id: pollTimer
    interval: Math.max(2, root.refreshMinutes) * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: digestTimer
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkDigest()
  }

  // The first FileView read can race shell startup, same as the weather
  // plugin: one delayed reload self-corrects a missed initial load.
  Timer {
    interval: 2000
    running: true
    onTriggered: {
      configFile.reload()
      itemsFile.reload()
      readFile.reload()
      statusFile.reload()
      digestDayFile.reload()
    }
  }

  // Global shortcut (singleton here, not in the per-monitor widget, so the
  // appid:name pair registers exactly once). Bind it in hyprland.conf:
  //   bind = SUPER ALT, H, global, herald:herald-toggle
  GlobalShortcut {
    appid: "herald"
    name: "herald-toggle"
    description: "Toggle Herald stories panel"
    onPressed: {
      if (root.shell && typeof root.shell.toggle === "function")
        root.shell.toggle("kshitij.herald", "{}")
    }
  }

  IpcHandler {
    target: "kshitij.herald"
    function refresh(): string {
      root.refresh()
      return "ok"
    }

    function digest(): string {
      root.runDigest()
      return "ok"
    }

    function status(): string {
      return JSON.stringify({
        items: root.items.length,
        unread: root.unread,
        updatedAt: root.updatedAt,
        ok: root.lastOk,
        refreshing: root.refreshing
      })
    }

    function open(index: string): string {
      var i = parseInt(index, 10)
      if (isNaN(i) || i < 0 || i >= root.items.length) return "out of range"
      root.openLink(root.items[i].link)
      return "ok"
    }

    function ping(): string {
      return "ok"
    }
  }
}
