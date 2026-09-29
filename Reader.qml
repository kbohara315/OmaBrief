import QtQuick
import QtQuick.Controls
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
  // Soft neutral hairline instead of the theme's bright menu border — the
  // frame was pulling attention off the article.
  readonly property var borderSpec: Border.flat(
    Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16), 1)
  readonly property color scrim: Color.menu.scrim
  readonly property string fontFamily: Style.font.menuFamily

  // Reading-text zoom: +/= bigger, - smaller, 0 resets (session-only).
  // Applies to article paragraphs, thread replies and the AI summary —
  // headings and chrome keep their fixed sizes.
  property real textZoom: 1.0
  function zoomed(px) { return Math.max(8, Math.round(px * root.textZoom)) }

  readonly property string articleText: articleFile.loaded ? String(articleFile.text() || "") : ""
  // Article body split on blank lines so each paragraph renders as its own
  // block (the extractor joins paragraphs with \n\n) — gives even spacing
  // instead of one giant Text with uneven blank-line gaps.
  readonly property var articleParagraphs: {
    var parts = String(root.articleText || "").replace(/\r/g, "").split(/\n{2,}/)
    var out = []
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i].replace(/^\s+|\s+$/g, "")
      if (p !== "") out.push(p)
    }
    return out
  }
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
      // Generous breathing room; BorderSurface only REPORTS these via
      // content*Inset, so keyCatcher consumes them explicitly below.
      padding: Style.space(28)

      MouseArea { anchors.fill: parent; onClicked: keyCatcher.forceActiveFocus() }

      Item {
        id: keyCatcher
        anchors.fill: parent
        // padding is inert on its own — apply border + padding insets here.
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
          else if (event.key === Qt.Key_O || event.key === Qt.Key_Return) { root.openOriginal(); event.accepted = true }
          else if (event.key === Qt.Key_T) { root.mode = "thread"; event.accepted = true }
          else if (event.key === Qt.Key_A) { root.mode = "article"; event.accepted = true }
          else if (event.key === Qt.Key_S) { root.requestSummary(); event.accepted = true }
          // Match the produced character too: on some layouts the +/= key
          // arrives with a different key code but the same text.
          else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal || event.text === "+" || event.text === "=") { root.textZoom = Math.min(2.0, root.textZoom + 0.1); event.accepted = true }
          else if (event.key === Qt.Key_Minus || event.key === Qt.Key_Underscore || event.text === "-" || event.text === "_") { root.textZoom = Math.max(0.7, root.textZoom - 0.1); event.accepted = true }
          else if (event.key === Qt.Key_0 || event.text === "0") { root.textZoom = 1.0; event.accepted = true }
        }

        // ONE scrollable reading column: header, toolbar and body share
        // the same capped width, centered — nothing hugs the card edge,
        // and a long header can never squeeze the body out of view.
        Flickable {
          id: flick
          width: keyCatcher.width
          height: keyCatcher.height
          contentWidth: width
          contentHeight: scrollCol.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; focusPolicy: Qt.NoFocus }

          Column {
            id: scrollCol
            width: Math.min(Style.space(860), flick.width)
            x: Math.max(0, (flick.width - width) / 2)
            spacing: Style.space(12)

          // ---- Header: kicker (feed chip · score · age), then title.
          Column {
            width: parent.width
            spacing: Style.space(8)

            Row {
              spacing: Style.space(8)

              Rectangle {
                visible: root.current && root.current.feed
                radius: Style.cornerRadius
                width: kickerText.implicitWidth + Style.space(16)
                height: kickerText.implicitHeight + Style.space(8)
                color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14)

                Text {
                  id: kickerText
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.current ? String(root.current.feed || "") : ""
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                visible: text !== ""
                text: root.current
                  ? ((root.current.score ? "\u25b2" + root.current.score + " · " : "")
                    + Model.relativeTime(root.current.published || 0))
                  : ""
                color: Qt.darker(root.foreground, 1.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.Wrap
              text: root.current ? String(root.current.title || "") : "Herald reader"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              lineHeight: 1.25
            }
          }

          // ---- Header / body divider.
          Rectangle {
            width: parent.width
            height: 1
            color: root.foreground
            opacity: 0.1
          }

          // ---- Toolbar: view toggles │ actions │ status, one quiet pill.
          Rectangle {
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            width: toolbarRow.implicitWidth + Style.space(16)
            height: toolbarRow.implicitHeight + Style.space(8)

            Row {
              id: toolbarRow
              anchors.centerIn: parent
              spacing: Style.space(6)

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

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: Style.space(16)
                color: root.foreground
                opacity: 0.15
              }

              PanelActionButton {
                iconText: "A−"
                tooltipText: "Smaller text (−)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.textZoom > 0.71
                onClicked: { root.textZoom = Math.max(0.7, root.textZoom - 0.1); keyCatcher.forceActiveFocus() }
              }

              PanelActionButton {
                iconText: "A+"
                tooltipText: "Bigger text (+)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.textZoom < 1.99
                onClicked: { root.textZoom = Math.min(2.0, root.textZoom + 0.1); keyCatcher.forceActiveFocus() }
              }

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: Style.space(16)
                color: root.foreground
                opacity: 0.15
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

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: Style.space(16)
                color: root.foreground
                opacity: 0.15
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: (root.mode === "thread"
                  ? (root.threadRows.length + " comments")
                  : (root.articleText !== "" ? (root.articleText.length + " chars") : "extracting…"))
                  + " · " + Math.round(root.textZoom * 100) + "%"
                color: Qt.darker(root.foreground, 1.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- AI summary (opt-in, only after the user presses s).
          Rectangle {
            visible: root.summaryText !== ""
            width: parent.width
            height: summaryCol.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)

            Column {
              id: summaryCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              spacing: Style.space(6)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "✦ AI summary"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                id: summaryText
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.Wrap
                text: root.summaryText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.zoomed(Style.font.body)
                lineHeight: 1.5
              }
            }
          }

          // ---- Body blocks (same scroll column as the header).
          Column {
            id: bodyColumn
            width: parent.width
            spacing: Style.space(14)

              // Article view: one block per paragraph, even spacing.
              Column {
                visible: root.mode === "article" && root.articleParagraphs.length > 0
                width: parent.width
                spacing: Style.space(14)

                Repeater {
                  model: root.articleParagraphs

                  Text {
                    required property var modelData
                    textFormat: Text.PlainText
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: modelData
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: root.zoomed(Style.font.body)
                    lineHeight: 1.65
                  }
                }
              }

              // Article placeholder while extraction runs.
              Column {
                visible: root.mode === "article" && root.articleParagraphs.length === 0
                width: parent.width
                spacing: Style.space(6)

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: "Extracting article text…"
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: root.zoomed(Style.font.body)
                }

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: "press o to open in the browser instead"
                  color: Qt.darker(root.foreground, 1.9)
                  font.family: root.fontFamily
                  font.pixelSize: root.zoomed(Style.font.caption)
                }
              }

              // Thread view.
              Repeater {
                model: root.mode === "thread" ? root.threadRows : []

                Item {
                  required property var modelData
                  width: bodyColumn.width
                  height: threadRow.implicitHeight
                  property int indent: Math.min(120, (modelData.depth || 0) * Style.space(20))

                  // Depth guide: thin accent rail beside nested replies.
                  Rectangle {
                    visible: parent.indent > 0
                    x: -Style.space(10)
                    y: 0
                    width: 2
                    height: parent.height
                    radius: 1
                    color: Color.accent
                    opacity: 0.3
                  }

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
                    font.pixelSize: root.zoomed(Style.font.body)
                    lineHeight: 1.5
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
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: root.current && root.current.hnId ? "Loading thread…" : "No HN thread for this story."
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: root.zoomed(Style.font.body)
              }
            }
          }
        }
      }
    }
  }
}
