import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaBrief story popup: search, feed chips, keyboard-driven story list.
// BarWidget.qml owns the bar pill and hands this panel the button to anchor
// against. All data comes from the service; this panel never fetches.
Panel {
  id: root
  moduleName: "kshitij.omabrief"
  ipcTarget: "kshitij.omabrief"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var omabrief: null
  readonly property var barIdentity: hostWidget || root

  property string query: ""
  property string feedFilter: ""
  property bool hideRead: false
  property bool showAddFeed: false
  property string addError: ""
  // True between submit and the service reporting back (feedOpSeq bump).
  property bool addPending: false
  readonly property string opNotice: brief ? String(brief.feedNotice || "") : ""
  readonly property int opSeq: brief ? (brief.feedOpSeq || 0) : 0
  onOpSeqChanged: {
    if (root.addPending) {
      root.addPending = false
      if (root.opNotice === "") {
        root.showAddFeed = false
        addUrlField.text = ""
        addLabelField.text = ""
      }
    }
  }

  readonly property var allItems: brief ? brief.items : []
  readonly property var readMap: brief ? brief.readIds : ({})
  readonly property bool useScores: brief ? brief.showScores : true
  readonly property var visibleItems: Model.filterItems(allItems, root.query, root.feedFilter, root.hideRead, root.readMap)
  readonly property var feeds: Model.feedNames(allItems)
  readonly property var panelFeedKeys: {
    if (!brief || !brief.panelFeedsText) return ({})
    var keys = {}
    var lines = Model.parseFeeds(brief.panelFeedsText, "")
    for (var i = 0; i < lines.length; i++) {
      var k = Model.feedKey(lines[i])
      if (k) keys[k] = true
    }
    return keys
  }
  readonly property var failedFeeds: {
    if (!brief || !brief.feedHealth) return []
    var out = []
    for (var i = 0; i < brief.feedHealth.length; i++) {
      if (brief.feedHealth[i] && brief.feedHealth[i].ok === false) out.push(brief.feedHealth[i].feed)
    }
    return out
  }
  readonly property int unreadTotal: brief ? brief.unread : 0
  readonly property string updatedLabel: {
    if (!brief || !brief.updatedAt) return "never updated"
    return "updated " + Model.relativeTime(brief.updatedAt)
  }

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    root.controller.show()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function currentItem() {
    if (storyList.currentIndex < 0 || storyList.currentIndex >= visibleItems.length) return null
    return visibleItems[storyList.currentIndex]
  }

  function openCurrent() {
    var item = currentItem()
    if (!item) return
    if (brief) {
      brief.markRead(item.id)
      brief.openLink(item.link)
    }
    root.close()
  }

  function openThread(item) {
    var target = item || currentItem()
    if (!target) return
    if (brief) brief.markRead(target.id)
    if (root.hostWidget && typeof root.hostWidget.openReader === "function")
      root.hostWidget.openReader(target)
  }

  // Source line in feeds.txt backing a displayed feed label (for remove).
  function feedSourceFor(label) {
    if (!brief || !brief.feedsText) return ""
    var lines = Model.parseFeeds(brief.feedsText, "")
    for (var i = 0; i < lines.length; i++) {
      if (Model.feedLabel(lines[i]) === label) return lines[i]
    }
    return ""
  }

  function isPanelFeed(label) {
    var src = root.feedSourceFor(label)
    if (!src) return false
    return root.panelFeedKeys[Model.feedKey(src)] === true
  }

  // "Label | https://… | max:20", hn:*, or a bare URL.
  function submitFeed() {
    root.addError = ""
    var url = (addUrlField.text || "").replace(/^\s+|\s+$/g, "")
    var label = (addLabelField.text || "").replace(/^\s+|\s+$/g, "")
    if (!/^https?:\/\//i.test(url) && !/^hn\s*:/i.test(url)) {
      root.addError = "Need an http(s) feed URL or hn:top / hn:best / …"
      return
    }
    if (label !== "" && (label.indexOf("|") !== -1 || label.indexOf("\n") !== -1)) {
      root.addError = "Label can't contain | or newlines."
      return
    }
    var line = label !== "" ? label + " | " + url : url
    if (!brief || typeof brief.addFeed !== "function") {
      root.addError = "Service not ready — try again in a moment."
      return
    }
    root.addPending = true
    brief.addFeed(line)
  }

  function moveSelection(delta) {
    if (visibleItems.length === 0) return
    var next = storyList.currentIndex + delta
    if (storyList.currentIndex < 0) next = delta > 0 ? 0 : visibleItems.length - 1
    if (next < 0) next = 0
    if (next >= visibleItems.length) next = visibleItems.length - 1
    storyList.currentIndex = next
    storyList.positionViewAtIndex(next, ListView.Contain)
  }

  function focusSearch() {
    searchField.selectAll()
    searchField.forceActiveFocus()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + Style.space(16))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveSelection(dy) }
      onActivateRequested: root.openCurrent()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") root.focusSearch()
        else if (t === "j") root.moveSelection(1)
        else if (t === "k") root.moveSelection(-1)
        else if (t === "r" || t === "R") { if (root.brief) root.brief.refresh() }
        else if (t === "a" || t === "A") { if (root.brief) root.brief.markAllRead() }
        else if (t === "c" || t === "C") root.openThread(null)
        else if (t === "u" || t === "U") root.hideRead = !root.hideRead
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(8)

        // ---- Header: title, unread, actions.
        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: "OmaBrief"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.unreadTotal > 0 ? root.unreadTotal + " unread" : "caught up"
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Item { width: Style.space(4); height: 1 }

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑓"
            tooltipText: "Refresh now (r)"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: { if (root.brief) root.brief.refresh() }
          }

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰄬"
            tooltipText: "Mark all read (a)"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: { if (root.brief) root.brief.markAllRead() }
          }

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.hideRead ? "󰈈" : "󰈉"
            tooltipText: "Toggle unread only (u)"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.hideRead = !root.hideRead
          }

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰐕"
            tooltipText: "Add a custom RSS/Atom feed"
            foreground: root.showAddFeed ? Color.accent : root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: { root.showAddFeed = !root.showAddFeed; root.addError = "" }
          }
        }

        TextField {
          id: searchField
          width: parent.width
          placeholderText: "Search stories…  ( / )"
          foreground: root.contentForeground
          font.family: root.contentFontFamily
          onTextChanged: root.query = text

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.query = ""
              text = ""
              keyCatcher.forceActiveFocus()
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.openCurrent()
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              root.moveSelection(1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {
              root.moveSelection(-1)
              event.accepted = true
            }
          }
        }

        // ---- Feed chips (× removes feeds added via + Add feed).
        Flow {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.feeds

            Rectangle {
              required property string modelData
              visible: root.feeds.length > 1
              width: chipRow.implicitWidth + Style.space(20)
              height: chipRow.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: root.feedFilter === modelData
                ? Style.selectedStateColor(root.contentForeground, Color.accent)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Row {
                id: chipRow
                anchors.centerIn: parent
                spacing: Style.space(6)

                Text {
                  id: chipText
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData
                  color: root.feedFilter === modelData ? Color.background : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.isPanelFeed(modelData)
                  text: "×"
                  color: root.feedFilter === modelData ? Color.background : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    // Above the chip-wide MouseArea below so × clicks
                    // remove instead of filtering.
                    z: 1
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      var src = root.feedSourceFor(modelData)
                      if (src && root.brief) {
                        if (root.feedFilter === modelData) root.feedFilter = ""
                        root.brief.removeFeed(src)
                      }
                    }
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.feedFilter = root.feedFilter === modelData ? "" : modelData
                  storyList.currentIndex = 0
                }
              }
            }
          }
        }

        // ---- Add custom feed form.
        Column {
          visible: root.showAddFeed
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: addUrlField
            width: parent.width
            placeholderText: "Feed URL or hn:best …"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.submitFeed()
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                root.showAddFeed = false
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: addLabelField
              width: parent.width - addButton.width - Style.space(6)
              placeholderText: "Label (optional)"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.submitFeed()
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.showAddFeed = false
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            PanelActionButton {
              id: addButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰄬"
              tooltipText: "Add feed"
              foreground: Color.accent
              fontFamily: root.contentFontFamily
              onClicked: root.submitFeed()
            }
          }

          Text {
            visible: root.addError !== "" || root.opNotice !== ""
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.Wrap
            text: root.addError !== "" ? root.addError : root.opNotice
            color: Color.accent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.addError === "" && root.opNotice === ""
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.Wrap
            text: "Any RSS/Atom/JSON feed. Bar-settings feeds are managed in widget settings."
            color: Qt.darker(root.contentForeground, 1.6)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Story list.
        ListView {
          id: storyList
          width: parent.width
          height: Math.min(Style.space(420), Math.max(Style.space(120), count * 64))
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.visibleItems
          currentIndex: 0
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: Item {
            required property var modelData
            required property int index
            width: storyList.width
            height: 60

            readonly property bool isCurrent: storyList.currentIndex === index
            readonly property bool isRead: root.readMap[modelData.id] === true

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: isCurrent
                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                : "transparent"
            }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 6
                height: 6
                radius: 3
                color: isRead ? "transparent" : Color.accent
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 14
                spacing: 2

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  elide: Text.ElideRight
                  text: modelData.title
                  color: isRead ? Qt.darker(root.contentForeground, 1.6) : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  elide: Text.ElideRight
                  text: (modelData.feed || "") + " · "
                    + (root.useScores && modelData.score ? "\u25b2" + modelData.score + " · " : "")
                    + Model.relativeTime(modelData.published || 0)
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: storyList.currentIndex = index
              onClicked: function(mouse) {
                storyList.currentIndex = index
                if (mouse.button === Qt.MiddleButton) root.openThread(modelData)
                else root.openCurrent()
              }
            }
          }
        }

        // ---- Footer.
        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.updatedLabel + (root.brief && root.brief.refreshing ? " · fetching…" : "")
              + (root.failedFeeds.length > 0 ? " · " + root.failedFeeds.length + " feed failed" + (root.failedFeeds.length > 1 ? "s" : "") : "")
            color: Qt.darker(root.contentForeground, 1.6)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Item { width: 1; height: 1 }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: "Enter open · c thread · / search · ? "
            color: Qt.darker(root.contentForeground, 1.9)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
