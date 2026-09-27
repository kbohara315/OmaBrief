import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Herald fullscreen reader: extracted article text beside the HN comment
// thread, with an opt-in AI summary. Opened from the popup or by
// right-clicking the bar pill. Fetches run through the service; this surface
// only watches the cache files the service publishes.
Item {
  id: root

  property var herald: null
  property var bar: null
  property bool opened: false
  property var current: null
  // "article" | "thread"
  property string mode: "article"

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property string fontFamily: Style.font.menuFamily

  readonly property string articleText: articleFile.loaded ? String(articleFile.text() || "") : ""
  readonly property var threadRows: {
    if (!threadFile.loaded) return []
    try {
      return Model.flattenThread(JSON.parse(threadFile.text() || "{}"))
    } catch (e) {
      return []
    }
  }
  readonly property string summaryText: herald ? String(herald.summary || "") : ""
  readonly property bool aiAvailable: herald ? herald.aiEnabled : false

  function openWith(item) {
    root.current = item
    root.mode = "article"
    root.opened = true
    if (item && root.herald) {
      root.herald.fetchArticle(item.link)
      if (item.hnId) root.herald.fetchThread(item.hnId)
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.current = null
  }

  function openOriginal() {
    if (root.current && root.herald) {
      root.herald.markRead(root.current.id)
      root.herald.openLink(root.current.link)
    }
  }

  function openThreadUrl() {
    if (root.current && root.current.commentsUrl && root.herald)
      root.herald.openLink(root.current.commentsUrl)
  }

  function requestSummary() {
    if (!root.herald || !root.aiAvailable || !root.herald.articlePath) return
    root.herald.summarize(root.herald.articlePath)
  }

  property FileView articleFile: FileView {
    path: root.herald ? String(root.herald.articlePath || "") : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }

  property FileView threadFile: FileView {
    path: root.herald ? String(root.herald.threadPath || "") : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "herald-reader"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(980), panel.width - Style.space(80))
      height: Math.min(Style.space(720), panel.height - Style.space(80))
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.space(20)

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
          else if (event.key === Qt.Key_O || event.key === Qt.Key_Return) { root.openOriginal(); event.accepted = true }
          else if (event.key === Qt.Key_T) { root.mode = "thread"; event.accepted = true }
          else if (event.key === Qt.Key_A) { root.mode = "article"; event.accepted = true }
          else if (event.key === Qt.Key_S) { root.requestSummary(); event.accepted = true }
        }

        Column {
          anchors.fill: parent
          spacing: Style.space(10)

          // ---- Header.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: root.current ? String(root.current.title || "") : "Herald reader"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: root.current
              ? ((root.current.feed || "") + " · "
                + (root.current.score ? "\u25b2" + root.current.score + " · " : "")
                + Model.relativeTime(root.current.published || 0))
              : ""
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---- Mode + action bar.
          Row {
            width: parent.width
            spacing: Style.space(8)

            PanelActionButton {
              iconText: "󰈋"
              tooltipText: "Article text (a)"
              foreground: root.mode === "article" ? Color.accent : root.foreground
              fontFamily: root.fontFamily
              onClicked: root.mode = "article"
            }

            PanelActionButton {
              iconText: "󰌨"
              tooltipText: "HN thread (t)"
              foreground: root.mode === "thread" ? Color.accent : root.foreground
              fontFamily: root.fontFamily
              onClicked: root.mode = "thread"
            }

            PanelActionButton {
              iconText: "󰖟"
              tooltipText: "Open original (o)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.openOriginal()
            }

            PanelActionButton {
              visible: root.aiAvailable
              iconText: "󰚩"
              tooltipText: "Summarize with AI (s)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.requestSummary()
            }

            Item { width: Style.space(8); height: 1 }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: root.mode === "thread"
                ? (root.threadRows.length + " comments")
                : (root.articleText !== "" ? (root.articleText.length + " chars") : "extracting…")
              color: Qt.darker(root.foreground, 1.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- AI summary (opt-in, only after the user presses s).
          Rectangle {
            visible: root.summaryText !== ""
            width: parent.width
            height: summaryText.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)

            Text {
              id: summaryText
              textFormat: Text.PlainText
              anchors.fill: parent
              anchors.margins: Style.space(10)
              wrapMode: Text.Wrap
              text: root.summaryText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // ---- Body.
          Flickable {
            width: parent.width
            height: parent.height - y
            contentWidth: width
            contentHeight: bodyColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: bodyColumn
              width: parent.width
              spacing: Style.space(10)

              // Article view.
              Text {
                visible: root.mode === "article"
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.Wrap
                text: root.articleText !== "" ? root.articleText : "Extracting article text…"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                lineHeight: 1.4
              }

              // Thread view.
              Repeater {
                model: root.mode === "thread" ? root.threadRows : []

                Item {
                  required property var modelData
                  width: bodyColumn.width
                  height: threadRow.implicitHeight
                  property int indent: Math.min(120, (modelData.depth || 0) * Style.space(20))

                  Column {
                    id: threadRow
                    x: parent.indent
                    width: parent.width - parent.indent
                    spacing: 4

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: (modelData.by || "?") + " · " + Model.relativeTime(modelData.time || 0)
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: modelData.text || ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    lineHeight: 1.35
                  }

                  Rectangle {
                    width: parent.width
                    height: 1
                    color: root.foreground
                    opacity: 0.08
                  }
                }
              }
              }

              Text {
                visible: root.mode === "thread" && root.threadRows.length === 0
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.Wrap
                text: root.current && root.current.hnId ? "Loading thread…" : "No HN thread for this story."
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
        }
      }
    }
  }
}
