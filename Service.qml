import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Model.js" as Model

// OmaBrief background service. Owns every byte of feed state: it polls
// fetch.sh on an interval, exposes the parsed item list and read-state to
// the bar widget, and fires the daily digest. The widget never fetches.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "kshitij.omabrief"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy/omabrief"
  readonly property string pluginDir: home + "/.config/omarchy/plugins/kshitij.omabrief"
  readonly property string fetchScript: pluginDir + "/fetch.sh"

  // ---- Cached state, fed by FileViews below. The shell holds only parsed
  //      items; raw payloads never leave fetch.sh.
  property var items: []
  property var readIds: ({})
  property int updatedAt: 0
  property bool lastOk: true
  property int lastErrors: 0
  property var feedHealth: []
  property string feedsText: ""
  property string panelFeedsText: ""
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

  // Custom feeds from the popup UI. Appends/removes a feeds.txt line, then
  // polls so the new source appears immediately. BarWidget's syncConfig
  // union-merges these back on the next settings sync (write-config).
  function addFeed(line) {
    if (!line) return
    addProc.command = ["bash", root.fetchScript, root.stateDir, "add-feed", String(line)]
    addProc.running = true
  }

  function removeFeed(line) {
    if (!line) return
    removeProc.command = ["bash", root.fetchScript, root.stateDir, "remove-feed", String(line)]
    removeProc.running = true
  }

  // One-slot queue so a click that lands while an opener is still
  // starting up is deferred instead of dropped.
  property string pendingUrl: ""

  // Last add-feed outcome for the popup form. Empty means success/idle.
  // feedOpSeq bumps on every add/remove completion so the popup can tell
  // "done" apart from "no change" (setting "" over "" fires no signal).
  property string feedNotice: ""
  property int feedOpSeq: 0

  function openLink(url) {
    if (!url) return
    var u = String(url)
    if (u.indexOf("https://") !== 0 && u.indexOf("http://") !== 0) return
    if (openProc.running) { root.pendingUrl = u; return }
    // Detached (&): the wrapper exits at once, so a slow browser handoff
    // never keeps this Process busy and every click opens its own tab.
    // The URL travels as argv ($0), never interpolated into shell code.
    openProc.command = ["bash", "-c", "xdg-open \"$0\" >/dev/null 2>&1 &", u]
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
        root.feedHealth = Array.isArray(s.perFeed) ? s.perFeed : []
      } catch (e) {}
    }
  }

  // Raw feeds.txt lines (one source per line). Watched so the popup can
  // add/remove feeds and the bar widget can union-merge them on sync.
  property FileView feedsFile: FileView {
    path: root.stateDir + "/feeds.txt"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.feedsText = String(text() || "")
  }

  // Feeds added from the popup UI (subset of feeds.txt). Only these show
  // a remove affordance in the popup; Bar-settings feeds are managed in
  // widget settings so a settings sync can never strand them.
  property FileView panelFeedsFile: FileView {
    path: root.stateDir + "/panel-feeds.txt"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.panelFeedsText = String(text() || "")
    onLoadFailed: root.panelFeedsText = ""
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
      // Cache hygiene after each poll: age out regenerable files so the
      // state dir never grows without bound.
      pruneProc.command = ["bash", root.fetchScript, root.stateDir, "prune"]
      pruneProc.running = true
    }
  }

  Process {
    id: pruneProc
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
    id: addProc
    onExited: function(code) {
      feedsFile.reload()
      panelFeedsFile.reload()
      if (code === 0) {
        root.feedNotice = ""
        root.refresh()
      } else if (code === 2) {
        root.feedNotice = "Already tracking that feed."
      } else {
        root.feedNotice = "Couldn't add that feed — check the URL."
      }
      root.feedOpSeq = root.feedOpSeq + 1
    }
  }

  Process {
    id: removeProc
    onExited: function(code) {
      feedsFile.reload()
      panelFeedsFile.reload()
      if (code === 0) {
        root.feedNotice = ""
        root.refresh()
      }
      root.feedOpSeq = root.feedOpSeq + 1
    }
  }

  Process {
    id: openProc
    onExited: function(code) {
      if (root.pendingUrl !== "") {
        var u = root.pendingUrl
        root.pendingUrl = ""
        root.openLink(u)
      }
    }
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
      onStreamFinished: omabriefAi.summaryReady(String(text || ""))
    }
  }

  // Fan-out target for the AI summary: set by the reader when it opens.
  QtObject {
    id: omabriefAi
    signal summaryReady(string text)
  }
  property alias ai: omabriefAi

  function onSummaryReady(text) {
    root.summary = text
  }

  Component.onCompleted: omabriefAi.summaryReady.connect(onSummaryReady)

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
      feedsFile.reload()
      panelFeedsFile.reload()
      digestDayFile.reload()
    }
  }

  // Global shortcut (singleton here, not in the per-monitor widget, so the
  // appid:name pair registers exactly once). Bind it in hyprland.conf:
  //   bind = SUPER ALT, H, global, omabrief:omabrief-toggle
  GlobalShortcut {
    appid: "omabrief"
    name: "omabrief-toggle"
    description: "Toggle OmaBrief stories panel"
    onPressed: {
      if (root.shell && typeof root.shell.toggle === "function")
        root.shell.toggle("kshitij.omabrief", "{}")
    }
  }

  IpcHandler {
    target: "kshitij.omabrief"
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

    function add(line: string): string {
      root.addFeed(line)
      return "ok"
    }

    function remove(line: string): string {
      root.removeFeed(line)
      return "ok"
    }

    function feeds(): string {
      return root.feedsText
    }

    function ping(): string {
      return "ok"
    }
  }
}
