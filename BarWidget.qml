import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Diary.js" as Diary

// The diary's place in the bar: one glyph that opens today's entry.
//
// Left click writes, right click browses. That order is deliberate -- writing
// is what the widget is for, so it is what a click does -- and it is the one
// thing about this widget worth learning, so the tooltip says it out loud the
// first few times, with the day's word count beside it.
//
// The glyph is dimmed until something has been written today. A mark that
// keeps saying "not yet" without shouting is the whole nudge this makes;
// nothing is counted, nothing is broken, and a day with no entry is a day
// with no entry.
BarWidget {
  id: root
  moduleName: "io.github.cosmicstasia.diary"

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // Written as an escape on purpose: a literal private-use glyph does not
  // survive every trip from an editor to disk, and when it does not there is
  // no error anywhere -- just an invisible icon. This is the pencil.
  readonly property string iconGlyph: "\uf040"

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The tooltip is drawn by the shell, whose Text format this plugin cannot
  // set, so anything that goes into it is neutralised here first. Counts and
  // our own strings are safe by construction; this is what keeps that true
  // after someone edits a catalog.
  readonly property string tooltipText: {
    var count = DiaryStore.todayWords
    var text = count > 0
      ? strings.tn("tooltip.today", count).arg(Commons.I18n.formatNumber(count))
      : strings.t("tooltip.write")
    return Diary.plain(text)
  }

  // Bar slot chrome: the dot the bar paints under an open panel follows the
  // painted glyph, like every other icon widget.
  readonly property real openPanelIndicatorWidth: Style.bar.iconSize
  readonly property real openPanelIndicatorHeight: Style.bar.iconSize

  function writeToday() {
    DiaryStore.writeToday()
    root.closePanel()
  }

  function writeEntry(key) {
    DiaryStore.writeEntry(key)
    root.closePanel()
  }

  // ---- Panel. Same shape contract as the clock: open/close/opened live on the
  //      bar-widget root, which is what the bar's IPC router looks for.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function openPanel() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function closePanel() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // One place where the widget's shell.json entry becomes the store's
  // settings, run on completion and again whenever the bar rewrites the entry
  // (a `omarchy bar set`, or the settings panel).
  function syncStore() {
    DiaryStore.applySettings(root.settings)
  }

  Component.onCompleted: root.syncStore()
  onSettingsChanged: {
    root.syncStore()
    root.injectPanel()
  }
  onBarChanged: root.injectPanel()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconGlyph
    // Read, then pressed: the count is the thing worth seeing on hover, and a
    // click that only opens a panel would make the glyph feel like a menu.
    tooltipText: root.tooltipText
    dimmed: !DiaryStore.todayWritten

    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePanel()
      else if (b === Qt.MiddleButton) DiaryStore.openFolder()
      else root.writeToday()
    }
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

  // `omarchy-shell io.github.cosmicstasia.diary write` is the call a keybinding
  // makes. The panel has manageIpc off: two handlers on one target would answer
  // twice, and the shell routes a call to whichever it registered first.
  ShellIpc {
    target: "io.github.cosmicstasia.diary"

    function write(): void { root.writeToday() }
    function openDate(key: string): void { root.writeEntry(key) }
    function toggle(): void { root.togglePanel() }
    function open(): void { root.openPanel() }
    function close(): void { root.closePanel() }
    function todayPath(): string { return DiaryStore.entryPath(DiaryStore.todayKey) }
    function path(key: string): string { return DiaryStore.entryPath(key) }
  }
}
