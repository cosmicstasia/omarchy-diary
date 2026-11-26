// Pure helpers for the diary widget: dates, paths, and the parsing of what
// bin/diary prints. Nothing here touches Qt, a file, or a process, so the
// whole file runs under node (test/run-tests.sh) and every rule that could
// disagree with the shell script is checked there.
//
// The QML owns the *wording*: names, plurals, and number formatting come from
// Commons.I18n and Qt.locale, which follow the Omarchy language.

var KEY_RE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/
var MS_PER_DAY = 86400000

function pad2(value) {
  return (value < 10 ? "0" : "") + value
}

// Local calendar date, never UTC: a diary day is the day the writer is living
// in. Formatting with toISOString would move the key a day back every evening
// east of Greenwich.
function dateKey(date) {
  if (!(date instanceof Date) || isNaN(date.getTime())) return ""
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function isValidKey(key) {
  return typeof key === "string" && KEY_RE.test(key)
}

// Local noon, so a day that has no midnight (Havana, April 2012) still names
// itself, and a day that lost an hour to DST still measures as one day.
function dateForKey(key) {
  if (!isValidKey(key)) return null
  var year = parseInt(key.slice(0, 4), 10)
  var month = parseInt(key.slice(5, 7), 10)
  var day = parseInt(key.slice(8, 10), 10)
  var date = new Date(year, month - 1, day, 12, 0, 0, 0)
  // 2026-02-31 is a well-formed string and not a day; refuse it rather than
  // letting the Date roll it into March and label an entry with a date it
  // never had.
  if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) return null
  return date
}

// Whole days between two keys, positive when `key` is in the past. Rounded,
// because a DST day is 23 or 25 hours long and truncation would call it 0.
function dayOffset(key, todayKey) {
  var then = dateForKey(key)
  var now = dateForKey(todayKey)
  if (!then || !now) return null
  return Math.round((now.getTime() - then.getTime()) / MS_PER_DAY)
}

// The same expansion bin/diary does, so a path shown in the panel and a path
// opened by the script are the same file. Written out rather than guessed:
// what a shell would do with "~friend/diary" is not what we want here.
function resolveDirectory(directory, home) {
  var dir = String(directory === undefined || directory === null ? "" : directory).trim()
  var base = String(home === undefined || home === null ? "" : home)
  if (!dir) dir = "Documents/Diary"

  if (dir === "~") dir = base
  else if (dir.indexOf("~/") === 0) dir = base + dir.slice(1)
  if (dir.charAt(0) !== "/") dir = base + "/" + dir

  dir = dir.replace(/\/{2,}/g, "/")
  while (dir.length > 1 && dir.charAt(dir.length - 1) === "/") dir = dir.slice(0, -1)
  return dir
}

function entryPath(directory, key, home) {
  if (!isValidKey(key)) return ""
  return resolveDirectory(directory, home) + "/" + key + ".md"
}

// Control characters, and runs of whitespace with them, never reach a Text.
// A file name, an excerpt, and a heading are all user data as far as this
// widget is concerned, and markup-shaped input must never be left able to
// promote itself to rich text in whatever sink it lands in.
function plain(value) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
  return text.replace(/\s+/g, " ").trim()
}

// The heading `ensure` writes for a new entry. %1 is the date; a template
// without it is used as-is. Always one line, because it becomes the first line
// of a file the writer will read.
function headerText(template, longDate) {
  var text = String(template === undefined || template === null ? "" : template)
  text = text.replace(/[\r\n\t]+/g, " ").trim()
  if (!text) return ""
  return plain(text.replace(/%1/g, String(longDate === undefined ? "" : longDate)))
}

var MAX_EXCERPT = 400
var MAX_ROWS = 200

// "words<TAB>first line", as `bin/diary stats` prints it.
function parseStats(text) {
  var line = String(text === undefined || text === null ? "" : text).split("\n")[0]
  var fields = line.split("\t")
  var words = parseInt(fields[0], 10)
  return {
    words: isFinite(words) && words >= 0 ? words : 0,
    excerpt: plain(fields.slice(1).join(" ")).slice(0, MAX_EXCERPT)
  }
}

// One row per entry from `bin/diary list`: "key<TAB>words<TAB>first line".
// A line that does not carry a real date key is dropped rather than repaired,
// so a shell error message on stdout can never become a row the panel would
// try to open.
function parseList(text, limit) {
  var cap = parseInt(limit, 10)
  if (!isFinite(cap) || cap < 1) cap = 14
  cap = Math.min(cap, MAX_ROWS)

  var rows = []
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  for (var i = 0; i < lines.length && rows.length < cap; i++) {
    if (!lines[i]) continue
    var fields = lines[i].split("\t")
    var key = fields[0]
    if (!isValidKey(key)) continue
    var words = parseInt(fields[1], 10)
    rows.push({
      key: key,
      words: isFinite(words) && words >= 0 ? words : 0,
      excerpt: plain(fields.slice(2).join(" ")).slice(0, MAX_EXCERPT)
    })
  }
  return rows
}

if (typeof module !== "undefined") {
  module.exports = {
    pad2: pad2,
    dateKey: dateKey,
    isValidKey: isValidKey,
    dateForKey: dateForKey,
    dayOffset: dayOffset,
    resolveDirectory: resolveDirectory,
    entryPath: entryPath,
    plain: plain,
    headerText: headerText,
    parseStats: parseStats,
    parseList: parseList
  }
}
