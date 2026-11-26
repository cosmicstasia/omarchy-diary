#!/usr/bin/env bash
# Regression suite for the diary widget.
#
# Everything runs against a throwaway folder: DIARY_DIR is redirected into a
# temporary directory for every call, so a test can never create, read, or
# overwrite a real diary.
#
# Beyond "does it work", this pins down the properties that are expensive to
# discover later: that the heading the widget writes is not counted as the
# writer's words, that an existing entry is never truncated, that a stray file
# in the folder is not an entry, that the excerpt never carries a tab or a
# newline into a TSV row, and that the two implementations of the folder rules
# (bin/diary and Diary.js) agree.
#
#   test/run-tests.sh

set -uo pipefail

PLUGIN="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$PLUGIN/bin/diary"
JS="$PLUGIN/Diary.js"
WORK="$(mktemp -d)"
export DIARY_DIR="$WORK/diary"

PASSED=0
FAILED=0
SKIPPED=0

cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

ok() { PASSED=$((PASSED + 1)); printf '  \033[32mpass\033[0m  %s\n' "$1"; }
no() { FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  \033[33mskip\033[0m  %s\n' "$1"; }
check() {
  if [ "$1" = "0" ]; then ok "$2"; else no "$2"; fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# A fresh folder per test group, so no test can lean on another's leftovers.
reset_diary() {
  rm -rf -- "$WORK/diary"
  mkdir -p -- "$WORK/diary"
}

# ---------------------------------------------------------------- folder rules

section "folder rules"

out=$(DIARY_DIR="$WORK/diary" "$CLI" folder)
check "$([ "$out" = "$WORK/diary" ] && echo 0 || echo 1)" "an absolute DIARY_DIR is used as given"

out=$(DIARY_DIR="~/Documents/Diary" "$CLI" folder)
check "$([ "$out" = "$HOME/Documents/Diary" ] && echo 0 || echo 1)" "a leading ~/ expands against HOME"

out=$(DIARY_DIR="~" "$CLI" folder)
check "$([ "$out" = "$HOME" ] && echo 0 || echo 1)" "a bare ~ is HOME"

out=$(DIARY_DIR="Diary/Inner" "$CLI" folder)
check "$([ "$out" = "$HOME/Diary/Inner" ] && echo 0 || echo 1)" "a relative folder lands under HOME"

out=$(DIARY_DIR="$WORK/diary///" "$CLI" folder)
check "$([ "$out" = "$WORK/diary" ] && echo 0 || echo 1)" "trailing slashes are dropped"

out=$(DIARY_DIR="  " "$CLI" folder)
check "$([ "$out" != "" ] && [[ $out == /* ]] && echo 0 || echo 1)" "an empty DIARY_DIR still answers with a real path"

# The same rules on the QML side. Two implementations of one rule is exactly
# the kind of thing that drifts, so they are compared on the same inputs.
if command -v node >/dev/null 2>&1; then
  drift=$(node -e '
    const Diary = require(process.argv[1])
    const home = process.argv[2]
    const cases = {
      "~/Documents/Diary": home + "/Documents/Diary",
      "~": home,
      "Diary/Inner": home + "/Diary/Inner",
      "/srv/diary///": "/srv/diary",
      "": home + "/Documents/Diary"
    }
    const bad = Object.keys(cases).filter(function(k) {
      return Diary.resolveDirectory(k, home) !== cases[k]
    })
    process.stdout.write(bad.join(","))
  ' "$JS" "$HOME" 2>&1)

  check "$([ -z "$drift" ] && echo 0 || echo 1)" "Diary.resolveDirectory agrees with bin/diary${drift:+ (drifted: $drift)}"
else
  skip "Diary.resolveDirectory agrees with bin/diary (node not installed)"
fi

# --------------------------------------------------------------------- writing

section "a new entry"

reset_diary
path=$("$CLI" ensure 2026-03-04 "# Wednesday, 4 March 2026")
check "$([ "$path" = "$WORK/diary/2026-03-04.md" ] && echo 0 || echo 1)" "ensure prints the entry's path"
check "$([ -f "$path" ] && echo 0 || echo 1)" "ensure creates the entry"
check "$([ "$(cat "$path")" = "$(printf '# Wednesday, 4 March 2026\n\n')" ] && echo 0 || echo 1)" \
  "the entry starts with the heading and a blank line"

check "$([ "$("$CLI" stats 2026-03-04 | cut -f1)" = "0" ] && echo 0 || echo 1)" \
  "an untouched entry counts as zero words, not as its heading"
check "$([ "$("$CLI" stats 2026-03-04 | cut -f2)" = "" ] && echo 0 || echo 1)" \
  "an untouched entry has no excerpt"

printf 'Two words.\n' >"$path"
check "$([ "$("$CLI" stats 2026-03-04 | cut -f1)" = "2" ] && echo 0 || echo 1)" \
  "only what the writer wrote is counted"

before=$(sha256sum "$path" | cut -d' ' -f1)
"$CLI" ensure 2026-03-04 "# ignored" >/dev/null
after=$(sha256sum "$path" | cut -d' ' -f1)
check "$([ "$before" = "$after" ] && echo 0 || echo 1)" "ensure never rewrites an entry that already exists"

reset_diary
: >"$WORK/diary/2026-03-05.md"
check "$([ -f "$WORK/diary/2026-03-05.md" ] && [ ! -s "$WORK/diary/2026-03-05.md" ] && echo 0 || echo 1)" \
  "the test starts from a genuinely empty file"
"$CLI" ensure 2026-03-05 "# Thursday, 5 March 2026" >/dev/null
# The writing app only autosaves a file it has read content from; a zero-byte
# file would silently opt that entry out of autosaving.
check "$([ -s "$WORK/diary/2026-03-05.md" ] && echo 0 || echo 1)" \
  "ensure gives a zero-byte entry content, so the writer autosaves it"

reset_diary
long=$(printf 'line one\nline two')
path=$("$CLI" ensure 2026-03-06 "$long")
lines=$(wc -l <"$path")
check "$([ "$lines" -le 2 ] && echo 0 || echo 1)" "a multi-line heading is folded to one line"

reset_diary
path=$("$CLI" ensure 2026-03-07 "")
check "$([ -f "$path" ] && [ -s "$path" ] && echo 0 || echo 1)" \
  "an empty heading still makes a non-empty file"

section "bad input"

"$CLI" ensure 2026-13-01 x >/dev/null 2>&1
check "$([ $? -ne 0 ] && echo 0 || echo 1)" "a month outside 01-12 is refused"
"$CLI" ensure 04-03-2026 x >/dev/null 2>&1
check "$([ $? -ne 0 ] && echo 0 || echo 1)" "a non-ISO key is refused"
"$CLI" ensure "../../etc/passwd" x >/dev/null 2>&1
check "$([ $? -ne 0 ] && echo 0 || echo 1)" "a path is refused where a date key belongs"
"$CLI" stats 2026-00-10 >/dev/null 2>&1
check "$([ $? -ne 0 ] && echo 0 || echo 1)" "stats refuses a malformed key"
check "$([ ! -e "$WORK/diary/../../etc/passwd.md" ] && echo 0 || echo 1)" "nothing was written outside the folder"

# ------------------------------------------------------------------ symlinks

section "symlink safety"

# Another local account with write access to the folder can plant an entry name
# as a symlink. Writing then has to land in a file in this folder, never in
# whatever the link points at -- and reading must not follow one either.
reset_diary
target="$WORK/innocent.txt"
: >"$target"
ln -s "$target" "$WORK/diary/2026-06-01.md"
path=$("$CLI" ensure 2026-06-01 "# Monday, 1 June 2026")
check "$([ "$path" = "$WORK/diary/2026-06-01.md" ] && echo 0 || echo 1)" \
  "ensure answers with the entry path even over a planted symlink"
check "$([ -f "$WORK/diary/2026-06-01.md" ] && [ ! -L "$WORK/diary/2026-06-01.md" ] && echo 0 || echo 1)" \
  "the entry is a plain file afterwards, not a link"
check "$([ -s "$target" ] && echo 1 || echo 0)" \
  "nothing was written through the link to its target"
check "$([ -s "$WORK/diary/2026-06-01.md" ] && echo 0 || echo 1)" \
  "the entry itself still got its heading"

reset_diary
printf 'keep me\n' >"$WORK/keep.txt"
ln -s "$WORK/keep.txt" "$WORK/diary/2026-06-02.md"
"$CLI" ensure 2026-06-02 "# Tuesday, 2 June 2026" >/dev/null
check "$([ "$(cat "$WORK/keep.txt")" = "keep me" ] && echo 0 || echo 1)" \
  "a file behind a planted link keeps its content"

reset_diary
mkdir -p "$WORK/linked-dir"
ln -s "$WORK/linked-dir" "$WORK/diary/2026-06-03.md"
"$CLI" ensure 2026-06-03 "# Wednesday, 3 June 2026" >/dev/null 2>&1
check "$([ -f "$WORK/diary/2026-06-03.md" ] && [ ! -L "$WORK/diary/2026-06-03.md" ] && echo 0 || echo 1)" \
  "a link to a directory is replaced by a plain entry"
check "$([ -z "$(ls -A "$WORK/linked-dir")" ] && echo 0 || echo 1)" \
  "nothing was written into the linked directory"

reset_diary
printf 'a secret first line\n' >"$WORK/secret.txt"
ln -s "$WORK/secret.txt" "$WORK/diary/2026-06-04.md"
check "$([ "$("$CLI" stats 2026-06-04 | cut -f1)" = "0" ] && echo 0 || echo 1)" \
  "stats does not count words in a file behind a link"
check "$([[ $("$CLI" stats 2026-06-04) != *secret* ]] && echo 0 || echo 1)" \
  "stats does not read the linked file into the panel"
check "$([ -z "$("$CLI" list 10)" ] && echo 0 || echo 1)" \
  "a symlinked entry is not offered by the listing"

section "excerpts"

reset_diary
printf '# 2026-03-08\n\n## **A bold** first line with `code`\nsecond line\n' >"$WORK/diary/2026-03-08.md"
excerpt=$("$CLI" stats 2026-03-08 | cut -f2)
check "$([ "$excerpt" = "A bold first line with \`code\`" ] && echo 0 || echo 1)" \
  "the excerpt drops the heading markers, keeps the words"
check "$([[ $excerpt != *"$(printf '\t')"* ]] && echo 0 || echo 1)" "the excerpt carries no tab"

reset_diary
printf '# 2026-03-09\n\n\tTabbed\tand\ttabbed\n' >"$WORK/diary/2026-03-09.md"
"$CLI" stats 2026-03-09 >"$WORK/stats-tsv"
fields=$(awk -F'\t' '{ print NF }' "$WORK/stats-tsv")
check "$([ "$fields" = "2" ] && echo 0 || echo 1)" "tabs in the text cannot add TSV columns"

reset_diary
printf '# 2026-03-10\n\n<img src="https://example.invalid/tracker">\n' >"$WORK/diary/2026-03-10.md"
check "$([ "$("$CLI" stats 2026-03-10 | cut -f2)" = '<img src="https://example.invalid/tracker">' ] && echo 0 || echo 1)" \
  "markup-shaped text is passed through as text, unaltered"

section "listing"

reset_diary
for day in 01 02 03 04 05; do
  printf '# 2026-04-%s\n\nentry %s\n' "$day" "$day" >"$WORK/diary/2026-04-$day.md"
done
printf 'not an entry\n' >"$WORK/diary/notes.md"
printf 'not an entry\n' >"$WORK/diary/2026-04-06.txt"

count=$("$CLI" list 10 | wc -l)
check "$([ "$count" = "5" ] && echo 0 || echo 1)" "only YYYY-MM-DD.md files are listed"
check "$([ "$("$CLI" list 10 | head -1 | cut -f1)" = "2026-04-05" ] && echo 0 || echo 1)" "newest entry comes first"
check "$([ "$("$CLI" list 10 | tail -1 | cut -f1)" = "2026-04-01" ] && echo 0 || echo 1)" "oldest entry comes last"
check "$([ "$("$CLI" list 2 | wc -l)" = "2" ] && echo 0 || echo 1)" "the limit is honoured"
check "$([[ $("$CLI" list 10 2026-04-03 | grep -c '2026-04-03') == "0" ]] && echo 0 || echo 1)" \
  "the skipped entry is left out of the listing"
check "$([ "$("$CLI" list 10 2026-04-03 | wc -l)" = "4" ] && echo 0 || echo 1)" "skipping one entry drops exactly one row"

reset_diary
out=$("$CLI" list 5)
check "$([ -z "$out" ] && echo 0 || echo 1)" "an empty folder lists nothing and exits cleanly"
rm -rf -- "$WORK/diary"
out=$("$CLI" list 5)
check "$([ -z "$out" ] && [ $? -eq 0 ] && echo 0 || echo 1)" "a missing folder lists nothing and exits cleanly"

section "non-ASCII"

reset_diary
printf '# 2026-05-01\n\nCafé au lait, Grüße, 日本語\n' >"$WORK/diary/2026-05-01.md"
check "$([ "$("$CLI" stats 2026-05-01 | cut -f1)" = "5" ] && echo 0 || echo 1)" \
  "accented and CJK words count as words"
check "$([[ $("$CLI" stats 2026-05-01) == *"Grüße"* ]] && echo 0 || echo 1)" \
  "UTF-8 survives the excerpt"

# ------------------------------------------------------------------------- JS

section "Diary.js"

if ! command -v node >/dev/null 2>&1; then
  skip "Diary.js tests"
else
  node "$PLUGIN/test/js-test.js"
  js_status=$?
  check "$([ $js_status -eq 0 ] && echo 0 || echo 1)" "Diary.js unit tests"
fi

# ---------------------------------------------------------------------- report

printf '\n\033[1m%s passed, %s failed, %s skipped\033[0m\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ]
