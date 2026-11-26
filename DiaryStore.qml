pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Diary.js" as Diary

// Everything with state or a process lives here, and there is a concrete
// reason: a bar widget is instantiated once per monitor, so a Timer or a
// Process declared in BarWidget.qml would exist twice on a two-monitor setup
// and poll twice for the same answer. This file is the model; BarWidget.qml
// and Panel.qml are views.
//
// The only things that touch the disk are subcommands of bin/diary, so this
// store never builds a path or counts a word of its own, and the two agree
// because the script is the single implementation.
Singleton {
  id: root

  // --- settings, pushed in by the bar widget ------------------------------
  //
  // Read from the widget's inline shell.json entry rather than from a config
  // file of our own: that is where every other bar widget keeps its settings,
  // and `omarchy bar set io.github.cosmicstasia.diary editor omawrite` then
  // works.
  property string directory: "~/Documents/Diary"
  property string editor: "auto"
  property string headerTemplate: "# %1"
  property int recentCount: 14

  function applySettings(values) {
    var settings = Util.isPlainObject(values) ? values : ({})

    var dir = settings.directory === undefined || settings.directory === null ? "" : String(settings.directory)
    root.directory = dir !== "" ? dir : "~/Documents/Diary"

    // Anything but the two explicit choices means "auto": omawrite when it is
    // installed, the Omarchy default editor otherwise.
    var choice = String(settings.editor === undefined || settings.editor === null ? "auto" : settings.editor)
    root.editor = (choice === "omawrite" || choice === "default") ? choice : "auto"

    // An empty heading is a choice, not a missing value: it means the entry
    // opens on a blank page.
    root.headerTemplate = settings.header === undefined || settings.header === null ? "# %1" : String(settings.header)

    var count = parseInt(settings.recentCount, 10)
    root.recentCount = isFinite(count) ? Math.max(3, Math.min(60, count)) : 14
  }

  readonly property string home: Quickshell.env("HOME")

  // The CLI sits next to this file, so the plugin works from wherever it was
  // installed without putting anything on $PATH.
  readonly property string helper: decodeURIComponent(
    Qt.resolvedUrl("bin/diary").toString().replace(/^file:\/\//, ""))

  readonly property string dirPath: Diary.resolveDirectory(root.directory, root.home)
  // Handed to every Process instead of assembling `DIARY_DIR=... some command`
  // for a shell: an argument vector plus the environment is the only way the
  // folder (which comes from shell.json, so from outside) cannot become a
  // command.
  readonly property var environment: ({ DIARY_DIR: root.dirPath })

  // --- today ---------------------------------------------------------------
  property date now: new Date()
  property int todayWords: 0
  property string todayExcerpt: ""
  property var entries: []
  property bool omawriteAvailable: false

  // An i18n-free code, mapped to a sentence by the panel. Keeping the text out
  // of here means a failed write is translated like everything else.
  property string error: ""

  readonly property string todayKey: Diary.dateKey(root.now)
  readonly property bool todayWritten: root.todayWords > 0 || root.todayExcerpt !== ""

  // The panel's rows: today always has one, written or not, because opening
  // today's entry is the point of the widget and a row is what the keyboard
  // cursor can land on. Then everything else, newest first.
  readonly property var rows: root.buildRows()

  function buildRows() {
    var out = [{
      key: root.todayKey,
      words: root.todayWords,
      excerpt: root.todayExcerpt,
      today: true
    }]
    for (var i = 0; i < root.entries.length; i++) {
      var entry = root.entries[i]
      if (!entry || entry.key === root.todayKey) continue
      out.push({ key: entry.key, words: entry.words, excerpt: entry.excerpt, today: false })
    }
    return out
  }

  // --- reading -------------------------------------------------------------

  // `now` is re-read here, not only at startup, so the widget rolls over to a
  // new day's entry on its own: the bar is long-lived and nothing else would
  // tell it that midnight happened.
  function refreshStats() {
    root.now = new Date()
    statsProc.command = ["bash", root.helper, "stats", root.todayKey]
    statsProc.running = true
  }

  function reloadEntries() {
    listProc.command = ["bash", root.helper, "list", String(root.recentCount), root.todayKey]
    listProc.running = true
  }

  function refresh() {
    root.error = ""
    root.refreshStats()
    root.reloadEntries()
  }

  Process {
    id: statsProc
    environment: root.environment
    stdout: StdioCollector {
      onStreamFinished: {
        var stats = Diary.parseStats(text)
        root.todayWords = stats.words
        root.todayExcerpt = stats.excerpt
      }
    }
  }

  Process {
    id: listProc
    environment: root.environment
    stdout: StdioCollector {
      onStreamFinished: root.entries = Diary.parseList(text, root.recentCount)
    }
  }

  // Sixty seconds: enough for the word count in the tooltip to catch up with
  // what the writer just typed, and cheap enough to be invisible -- one awk
  // over one small file, no network and no daemon.
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: {
      var yesterdayKey = root.todayKey
      root.refreshStats()
      if (root.todayKey !== yesterdayKey) root.reloadEntries()
    }
  }

  // --- writing -------------------------------------------------------------

  property string pendingKey: ""
  property string pendingPath: ""

  // The heading of a new entry, in the Omarchy language rather than the system
  // locale, which only catches up at the next login.
  function headerFor(key) {
    var date = Diary.dateForKey(key)
    var longDate = date ? date.toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), Locale.LongFormat) : ""
    return Diary.headerText(root.headerTemplate, longDate)
  }

  function writeToday() { root.writeEntry(root.todayKey) }

  // Creates the file first, then opens it, in that order and only then. This
  // is what makes autosaving work: the writing app only autosaves a file it
  // has already read content from, and waits for an explicit save for one that
  // does not exist yet. A template written ahead of the app is the difference
  // between a diary that saves itself and one that loses an evening's writing.
  function writeEntry(key) {
    var wanted = String(key === undefined || key === null ? "" : key)
    if (!Diary.isValidKey(wanted)) return
    root.error = ""
    root.pendingKey = wanted
    root.pendingPath = ""
    ensureProc.command = ["bash", root.helper, "ensure", wanted, root.headerFor(wanted)]
    ensureProc.running = true
  }

  Process {
    id: ensureProc
    environment: root.environment
    stdout: StdioCollector {
      onStreamFinished: root.pendingPath = text.trim()
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 || root.pendingPath === "") {
        root.error = "ensure"
        return
      }
      root.launch(root.pendingPath)
      root.refreshStats()
      root.reloadEntries()
    }
  }

  // omawrite is the Omarchy writing app, and it autosaves half a second after
  // the last keystroke. The Omarchy default editor is the fallback, because a
  // handoff to whatever the user actually edits in beats an argument about
  // which one is better.
  function editorArgv(path) {
    var target = String(path === undefined || path === null ? "" : path)
    if (target === "") return []
    var wantsOmawrite = (root.editor === "omawrite" || root.editor === "auto") && root.omawriteAvailable
    return wantsOmawrite ? ["omawrite", target] : ["omarchy-launch-editor", target]
  }

  function launch(path) {
    var argv = root.editorArgv(path)
    if (argv.length === 0) return
    // argv, never a command string: a folder named `$(rm -rf ~)` is a folder
    // someone typed into shell.json, and it stays a file name here.
    Util.execArgv(argv)
  }

  // Checked once, because "auto" has to resolve to something before the first
  // click and the answer does not change while the shell runs.
  Process {
    id: editorProbe
    command: ["omarchy-cmd-present", "omawrite"]
    onExited: function(exitCode) { root.omawriteAvailable = exitCode === 0 }
  }

  // --- the folder ----------------------------------------------------------

  property string pendingFolder: ""

  function openFolder() {
    root.error = ""
    root.pendingFolder = ""
    folderProc.command = ["bash", root.helper, "folder"]
    folderProc.running = true
  }

  Process {
    id: folderProc
    environment: root.environment
    stdout: StdioCollector {
      onStreamFinished: root.pendingFolder = text.trim()
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 || root.pendingFolder === "") {
        root.error = "folder"
        return
      }
      Util.execArgv(["xdg-open", root.pendingFolder])
    }
  }

  // --- startup -------------------------------------------------------------

  // A path without a process, for scripts that want to point something else at
  // today's entry:
  //   foot -e nvim "$(omarchy-shell io.github.cosmicstasia.diary todayPath)"
  function entryPath(key) {
    return Diary.entryPath(root.directory, String(key === undefined || key === null ? "" : key), root.home)
  }

  Component.onCompleted: {
    editorProbe.running = true
    root.refresh()
  }
}
