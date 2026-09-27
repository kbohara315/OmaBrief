import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Herald story popup: search, feed chips, keyboard-driven story list.
// BarWidget.qml owns the bar pill and hands this panel the button to anchor
// against. All data comes from the service; this panel never fetches.
Panel {
  id: root
  moduleName: "kshitij.herald"
  ipcTarget: "kshitij.herald"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var herald: null
  readonly property var barIdentity: hostWidget || root

  property string query: ""
  property string feedFilter: ""
  property bool hideRead: false

  readonly property var allItems: herald ? herald.items : []
  readonly property var readMap: herald ? herald.readIds : ({})
  readonly property bool useScores: herald ? herald.showScores : true
  readonly property var visibleItems: Model.filterItems(allItems, root.query, root.feedFilter, root.hideRead, root.readMap)
  readonly property var feeds: Model.feedNames(allItems)
  readonly property int unreadTotal: herald ? herald.unread : 0
  readonly property string updatedLabel: {
    if (!herald || !herald.updatedAt) return "never updated"
    return "updated " + Model.relativeTime(herald.updatedAt)
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
    if (herald) {
      herald.markRead(item.id)
      herald.openLink(item.link)
    }
    root.close()
  }

  function openThread(item) {
    var target = item || currentItem()
    if (!target) return
    if (herald) herald.markRead(target.id)
    if (root.hostWidget && typeof root.hostWidget.openReader === "function")
      root.hostWidget.openReader(target)
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
        else if (t === "r" || t === "R") { if (root.herald) root.herald.refresh() }
        else if (t === "a" || t === "A") { if (root.herald) root.herald.markAllRead() }
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
            text: "Herald"
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
            onClicked: { if (root.herald) root.herald.refresh() }
          }

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰄬"
            tooltipText: "Mark all read (a)"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: { if (root.herald) root.herald.markAllRead() }
          }

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.hideRead ? "󰈈" : "󰈉"
            tooltipText: "Toggle unread only (u)"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.hideRead = !root.hideRead
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

        // ---- Feed chips.
        Flow {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.feeds

            Rectangle {
              required property string modelData
              visible: root.feeds.length > 1
              width: chipText.implicitWidth + Style.space(20)
              height: chipText.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: root.feedFilter === modelData
                ? Style.selectedStateColor(root.contentForeground, Color.accent)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Text {
                id: chipText
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: modelData
                color: root.feedFilter === modelData ? Color.background : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
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

        // ---- Story list.
        ListView {
          id: storyList
          width: parent.width
          height: Math.min(Style.space(420), Math.max(Style.space(120), count * 64))
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.visibleItems
          currentIndex: 0

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
            text: root.updatedLabel + (root.herald && root.herald.refreshing ? " · fetching…" : "")
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
