// Unit tests for Diary.js, run by test/run-tests.sh under node.
//
// These cover the rules that are cheap to get wrong and expensive to notice:
// a diary keyed to yesterday because the date was formatted in UTC, an entry
// labelled with a day it never had, a stray line on stdout becoming a row the
// panel offers to open, and untrusted file text reaching a Text unchanged.

const Diary = require(require('path').join(__dirname, '..', 'Diary.js'))

let passed = 0
let failed = 0

function ok(condition, name) {
  if (condition) {
    passed++
    console.log('  \x1b[32mpass\x1b[0m  ' + name)
  } else {
    failed++
    console.log('  \x1b[31mFAIL\x1b[0m  ' + name)
  }
}

function eq(actual, expected, name) {
  ok(Object.is(actual, expected), name + (Object.is(actual, expected) ? '' : ` (got ${JSON.stringify(actual)}, wanted ${JSON.stringify(expected)})`))
}

// ---- date keys

eq(Diary.dateKey(new Date(2026, 0, 9, 23, 59)), '2026-01-09', 'a late evening stays on its own local day')
eq(Diary.dateKey(new Date(2026, 11, 31, 0, 0)), '2026-12-31', 'midnight is the day that starts')
eq(Diary.dateKey(new Date('nonsense')), '', 'an invalid Date has no key')
eq(Diary.isValidKey('2026-02-29'), true, 'the shape is checked, not the calendar')
eq(Diary.isValidKey('26-02-01'), false, 'a short year is not a key')
eq(Diary.isValidKey('2026-2-01'), false, 'an unpadded month is not a key')
eq(Diary.isValidKey('../2026-02-01'), false, 'a path is not a key')
eq(Diary.isValidKey(undefined), false, 'undefined is not a key')

eq(Diary.dateForKey('2026-02-31'), null, 'a day that does not exist is refused, not rolled into March')
eq(Diary.dateForKey('2026-03-01').getDate(), 1, 'a real day parses')
eq(Diary.dateForKey('oops'), null, 'a malformed key does not parse')

// A DST change makes a day 23 or 25 hours long; the offset is still one day.
// Noon anchoring is what keeps this true in every timezone the widget runs in.
const dst = Diary.dayOffset('2026-03-07', '2026-03-09')
eq(dst, 2, 'a DST change does not change how many days passed')
eq(Diary.dayOffset('2026-03-09', '2026-03-09'), 0, 'the same key is zero days away')
eq(Diary.dayOffset('2026-03-10', '2026-03-09'), -1, 'a future key is negative')
eq(Diary.dayOffset('nope', '2026-03-09'), null, 'an invalid key has no offset')

// ---- paths

eq(Diary.entryPath('~/Documents/Diary', '2026-03-04', '/home/a'), '/home/a/Documents/Diary/2026-03-04.md',
  'an entry path is the folder, the key and .md')
eq(Diary.entryPath('Diary', '2026-03-04', '/home/a'), '/home/a/Diary/2026-03-04.md',
  'a relative folder lands under HOME')
eq(Diary.entryPath('', '2026-03-04', '/home/a'), '/home/a/Documents/Diary/2026-03-04.md',
  'an unset folder falls back to Documents/Diary')
eq(Diary.entryPath('/srv/d/', '2026-03-04', '/home/a'), '/srv/d/2026-03-04.md',
  'a trailing slash does not double up')
eq(Diary.entryPath('~/Diary', 'nonsense', '/home/a'), '', 'no path for an invalid key')

// ---- headings

eq(Diary.headerText('# %1', 'Wednesday, 4 March 2026'), '# Wednesday, 4 March 2026', '%1 becomes the date')
eq(Diary.headerText('Diary — %1', 'today'), 'Diary — today', 'a template can carry its own words')
eq(Diary.headerText('', 'today'), '', 'an empty template makes no heading')
eq(Diary.headerText('# %1\n# second', 'today'), '# today # second', 'a newline in a heading is folded, never kept')

// ---- untrusted text

eq(Diary.plain('a\u0000b\u001fc'), 'a b c', 'control characters become spaces')
eq(Diary.plain('  spaced\t\tout  '), 'spaced out', 'runs of whitespace collapse')
eq(Diary.plain(null), '', 'null is empty')
eq(Diary.plain('<img src="https://example.invalid/tracker">'), '<img src="https://example.invalid/tracker">',
  'markup-shaped text stays text, unaltered')

// ---- stats and listing

const stats = Diary.parseStats('12\tA first line\nignored second line')
eq(stats.words, 12, 'stats reads the word count')
eq(stats.excerpt, 'A first line', 'stats reads the first line')
eq(Diary.parseStats('0\t').words, 0, 'an untouched entry is zero words')
eq(Diary.parseStats('').words, 0, 'empty output is zero words')
eq(Diary.parseStats('\t').words, 0, 'a tab with no count is zero words')
eq(Diary.parseStats('not-a-number\tx').words, 0, 'a non-numeric count is zero, not NaN')

const rows = Diary.parseList('2026-03-04\t12\tfirst\n2026-03-03\t0\t\n', 14)
eq(rows.length, 2, 'two listing lines make two rows')
eq(rows[0].key, '2026-03-04', 'the key is kept')
eq(rows[0].words, 12, 'the count is kept')
eq(rows[1].excerpt, '', 'an empty excerpt stays empty')

// A shell error on stdout, or a half-written line, must never become a row the
// panel would offer to open.
const noise = Diary.parseList('bash: line 1: something went wrong\n2026-03-04\t1\tx\n../etc/passwd\t1\ty\n', 14)
eq(noise.length, 1, 'only real date keys become rows')
eq(noise[0].key, '2026-03-04', 'the real row survives the noise')

eq(Diary.parseList('2026-03-04\t1\tx\n', 0).length, 1, 'a zero limit falls back to the default')
eq(Diary.parseList('2026-03-04\t1\tx', -5).length, 1, 'a negative limit falls back to the default')

let many = ''
for (let i = 1; i <= 300; i++) {
  const day = String((i % 28) + 1).padStart(2, '0')
  many += `2026-02-${day}\t1\tx\n`
}
eq(Diary.parseList(many, 400).length, 200, 'a listing is capped at 200 rows however much arrives')

const longLine = Diary.parseList('2026-03-04\t1\t' + 'x'.repeat(5000), 14)
eq(longLine[0].excerpt.length, 400, 'an over-long excerpt is cut to 400 characters')

const countNoise = Diary.parseList('2026-03-04\t-3\tx\n2026-03-05\tabc\tx\n', 14)
eq(countNoise[0].words, 0, 'a negative count is treated as zero')
eq(countNoise[1].words, 0, 'a non-numeric count is treated as zero')

// ---- report

console.log(`\n  ${passed} passed, ${failed} failed`)
process.exit(failed === 0 ? 0 : 1)
