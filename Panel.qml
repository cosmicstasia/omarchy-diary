import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Diary.js" as Diary

// The diary's popup: today's entry on top as the thing to press, then the last
// few weeks underneath.
//
// One list, one cursor. Today always has a row whether or not anything is
// written in it, because opening today's entry is what this panel is for and a
// row is what a keyboard cursor can land on. The word count sits on the right
// of each row, so "which day did I write something" is answerable by looking
// rather than by opening.
Panel {
  id: root

  moduleName: "io.github.cosmicstasia.diary"
  ipcTarget: "io.github.cosmicstasia.diary"
  // The bar widget owns the IPC target: it is loaded once per monitor and
  // always alive, while this panel is built lazily and would leave its
  // functions unroutable before the first click.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  // The bar identifies a panel by the widget mounted in its slot, not by this
  // nested panel: the popout coordinator and its open-panel dot compare
  // against that widget.
  readonly property var barIdentity: hostWidget || root

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  readonly property string iconGlyph: "\uf040"   // pencil

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color dimmer: Qt.darker(foreground, 2.1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Day and month names follow the Omarchy language, not the system locale,
  // which only catches up at the next login.
  readonly property var labelLocale: Qt.locale(Commons.I18n.formatLocale)

  readonly property string todayLabel: DiaryStore.now.toLocaleDateString(root.labelLocale, Locale.LongFormat)
  readonly property var rows: DiaryStore.rows
  // Everything after today's row.
  readonly property var pastRows: root.rows.slice(1)

  property int cursor: 0

  // How much has been written in total, rather than today's word count: the
  // row underneath already says that, and a diary is a thing that accumulates.
  readonly property string todayMeta: {
    var count = root.pastRows.length + (DiaryStore.todayWritten ? 1 : 0)
    if (count === 0) return strings.t("panel.empty")
    return strings.tn("panel.entries", count).arg(Commons.I18n.formatNumber(count))
  }

  readonly property string errorText: {
    if (DiaryStore.error === "unsafe") return strings.t("panel.unsafeFolder")
    if (DiaryStore.error === "folder") return strings.t("panel.folderFailed")
    if (DiaryStore.error !== "") return strings.t("panel.openFailed")
    return ""
  }

  function wordsLabel(count) {
    return strings.tn("panel.words", count).arg(Commons.I18n.formatNumber(count))
  }

  function rowLabel(key, isToday) {
    if (isToday) return strings.t("panel.today")
    var offset = Diary.dayOffset(key, DiaryStore.todayKey)
    if (offset === 1) return strings.t("panel.yesterday")
    var date = Diary.dateForKey(key)
    if (!date) return String(key)
    return date.toLocaleDateString(root.labelLocale, "ddd d MMM")
  }

  // A shorter list after a busy month must not leave the cursor pointing past
  // the end, where Enter would do nothing at all.
  onRowsChanged: {
    if (root.cursor > root.rows.length - 1) root.cursor = Math.max(0, root.rows.length - 1)
  }

  function open() {
    root.cursor = 0
    DiaryStore.refresh()
    root.controller.show()
    // The content stays loaded between opens, so the scroll position of the
    // last visit would otherwise put today's row above the top edge.
    Qt.callLater(function() {
      var content = panel.loadedContent
      if (content && content.resetScroll) content.resetScroll()
    })
  }

  function moveCursor(dy) {
    if (root.rows.length === 0) return
    root.cursor = Math.max(0, Math.min(root.rows.length - 1, root.cursor + dy))
  }

  function activate() {
    var row = root.rows[root.cursor]
    if (!row) return
    DiaryStore.writeEntry(row.key)
    root.close()
  }

  function activateToday() {
    DiaryStore.writeToday()
    root.close()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Anchored under the widget itself, so the card follows wherever the
    // widget is moved along the bar.
    centerOnBar: false
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(348))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(520))

    content: PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      implicitHeight: body.implicitHeight

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activate()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "t") root.activateToday()
        else if (key === "o") {
          DiaryStore.openFolder()
          root.close()
        } else if (key === "r") DiaryStore.refresh()
      }

      // The cursor moves by keyboard as well as by mouse, and the list can be
      // longer than the card; the row it lands on has to be on screen.
      function ensureVisible() {
        var target = root.cursor === 0 ? todayRow : pastRepeater.itemAt(root.cursor - 1)
        if (!target) return
        var top = target.y
        var bottom = target.y + target.height
        if (top < scroll.contentY) scroll.contentY = Math.max(0, top)
        else if (bottom > scroll.contentY + scroll.height) scroll.contentY = bottom - scroll.height
      }

      function resetScroll() {
        scroll.contentY = 0
      }

      Connections {
        target: root
        function onCursorChanged() { keyCatcher.ensureVisible() }
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: body
          width: scroll.width
          spacing: 0

          PanelHero {
            width: parent.width
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.iconGlyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            title: root.todayLabel
            meta: root.todayMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            visible: root.errorText !== ""
            width: parent.width
            topPadding: visible ? Style.space(8) : 0
            text: root.errorText
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Item {
            width: parent.width
            height: Style.space(14)
          }

          EntryRow {
            id: todayRow
            width: parent.width
            rowIndex: 0
            entry: root.rows.length > 0 ? root.rows[0] : null
          }

          PanelSeparator {
            width: parent.width
            visible: root.pastRows.length > 0
            foreground: root.foreground
          }

          PanelSectionHeader {
            width: parent.width
            visible: root.pastRows.length > 0
            topPadding: visible ? Math.ceil(Style.font.caption * 0.15) + Style.space(8) : 0
            text: strings.t("panel.earlier")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            id: pastRepeater
            model: root.pastRows

            EntryRow {
              required property var modelData
              required property int index

              width: body.width
              rowIndex: index + 1
              entry: modelData
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          // Spell the gestures out. Two of them are not discoverable by
          // clicking, and the writing app this hands off to is where the rest
          // of the keys live.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            topPadding: Style.space(8)
            text: strings.t("panel.hint")
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One entry as a row: the day, what it starts with, and how much of it there
  // is. CursorSurface owns the highlight, so exactly one row is lit whether the
  // cursor got there by key or by mouse.
  component EntryRow: CursorSurface {
    id: entryRow
    required property var entry
    required property int rowIndex

    readonly property bool isToday: entry ? entry.today === true : false
    readonly property bool hasExcerpt: entry ? entry.excerpt !== "" : false
    readonly property int words: entry ? entry.words : 0

    hasCursor: root.cursor === entryRow.rowIndex
    foreground: root.foreground
    accent: root.accent
    implicitHeight: rowBody.implicitHeight + Style.space(14)

    Column {
      id: rowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Item {
        width: parent.width
        height: Math.max(dayText.implicitHeight, wordsText.implicitHeight)

        Text {
          id: dayText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, Math.min(implicitWidth,
            parent.width - (wordsText.visible ? wordsText.implicitWidth + Style.space(8) : 0)))
          text: entryRow.entry ? root.rowLabel(entryRow.entry.key, entryRow.isToday) : ""
          color: entryRow.isToday ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: entryRow.isToday
          elide: Text.ElideRight
        }

        Text {
          id: wordsText
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: entryRow.words > 0
          text: root.wordsLabel(entryRow.words)
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        maximumLineCount: 1
        elide: Text.ElideRight
        // The first line of a file is untrusted text: it is whatever was typed
        // there, or whatever another program left in the folder. Plain text,
        // never AutoText.
        text: entryRow.hasExcerpt ? entryRow.entry.excerpt : strings.t("panel.nothingYet")
        color: entryRow.hasExcerpt ? root.dim : root.dimmer
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      // Hover drives the same single cursor the keyboard does, so the panel
      // never shows two highlights at once.
      onContainsMouseChanged: if (containsMouse) root.cursor = entryRow.rowIndex
      onClicked: {
        root.cursor = entryRow.rowIndex
        root.activate()
      }
    }
  }
}
