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
# newline into a TSV row, that a folder other accounts can write to is refused
# before any entry is touched, that a link planted mid-write is never written
# through, and that the two implementations of the folder rules (bin/diary and
# Diary.js) agree.
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

# ------------------------------------------------------------- private folder

section "private folder"

# Checking an entry cannot protect the editor: it opens the path after the
# helper has exited, so an account that can rename names in the folder could
# swap the entry for a symlink in between. bin/diary therefore refuses (exit 3)
# any folder another account could write to, before touching an entry.

expect_refused() {
  local what=$1 status
  shift
  "$@" >"$WORK/out" 2>"$WORK/err"
  status=$?
  check "$([ "$status" = "3" ] && echo 0 || echo 1)" "$what (exit $status)"
}

for perm in g+w o+w; do
  reset_diary
  printf 'kept\n' >"$WORK/diary/2026-07-01.md"
  chmod "$perm" "$WORK/diary"
  expect_refused "ensure refuses a folder with $perm" "$CLI" ensure 2026-07-02 "# heading"
  check "$([ ! -e "$WORK/diary/2026-07-02.md" ] && echo 0 || echo 1)" \
    "nothing is created in a folder with $perm"
  check "$([ ! -s "$WORK/out" ] && echo 0 || echo 1)" "no path is handed to the editor for a folder with $perm"
  expect_refused "stats refuses a folder with $perm" "$CLI" stats 2026-07-01
  check "$([[ $(cat "$WORK/out") != *kept* ]] && echo 0 || echo 1)" "stats reads nothing from a folder with $perm"
  expect_refused "list refuses a folder with $perm" "$CLI" list 10
  check "$([ ! -s "$WORK/out" ] && echo 0 || echo 1)" "list reads nothing from a folder with $perm"
  chmod go-w "$WORK/diary"
done

reset_diary
chmod 1777 "$WORK/diary"
expect_refused "a sticky, world-writable folder is still refused" "$CLI" ensure 2026-07-03 "# heading"

reset_diary
mkdir -p "$WORK/shared"
chmod 0777 "$WORK/shared"
mkdir -p "$WORK/shared/diary"
chmod 0700 "$WORK/shared/diary"
expect_refused "a private folder inside a writable, non-sticky parent is refused" \
  env DIARY_DIR="$WORK/shared/diary" "$CLI" ensure 2026-07-04 "# heading"
chmod 1777 "$WORK/shared"
out=$(DIARY_DIR="$WORK/shared/diary" "$CLI" ensure 2026-07-04 "# heading" 2>/dev/null)
check "$([ "$out" = "$WORK/shared/diary/2026-07-04.md" ] && echo 0 || echo 1)" \
  "a private folder inside a sticky parent, like /tmp, is accepted"
rm -rf -- "$WORK/shared"

reset_diary
mkdir -p "$WORK/open"
chmod 0777 "$WORK/open"
ln -s "$WORK/open" "$WORK/diary/link"
expect_refused "a folder that is a symlink to a writable directory is refused" \
  env DIARY_DIR="$WORK/diary/link" "$CLI" ensure 2026-07-05 "# heading"
check "$([ -z "$(ls -A "$WORK/open")" ] && echo 0 || echo 1)" "nothing is created behind that link"
chmod 0700 "$WORK/open"
out=$(DIARY_DIR="$WORK/diary/link" "$CLI" ensure 2026-07-05 "# heading" 2>/dev/null)
check "$([ "$out" = "$WORK/open/2026-07-05.md" ] && echo 0 || echo 1)" \
  "a symlink to a private folder works, and the resolved path is what gets opened"
rm -rf -- "$WORK/open"

if command -v setfacl >/dev/null 2>&1 && reset_diary && chmod 0700 "$WORK/diary" &&
  setfacl -m u:nobody:rwx "$WORK/diary" 2>/dev/null; then
  expect_refused "a folder another user can write to through an ACL is refused" \
    "$CLI" ensure 2026-07-06 "# heading"
  setfacl -m u:nobody:rx "$WORK/diary"
  out=$("$CLI" ensure 2026-07-06 "# heading" 2>/dev/null)
  check "$([ -n "$out" ] && echo 0 || echo 1)" "a read-only ACL entry is not refused"
  setfacl -b "$WORK/diary"
else
  skip "ACL cases (setfacl unavailable or unsupported here)"
fi

rm -rf -- "$WORK/diary"
(umask 000 && "$CLI" ensure 2026-07-07 "# heading" >/dev/null)
check "$([ "$(stat -c %a "$WORK/diary")" = "700" ] && echo 0 || echo 1)" \
  "a folder ensure creates is 0700 even under umask 000"
rm -rf -- "$WORK/diary"
(umask 000 && DIARY_DIR="$WORK/new/nested/diary" "$CLI" ensure 2026-07-07 "# heading" >/dev/null)
check "$([ "$(stat -c %a "$WORK/new")" = "700" ] && [ "$(stat -c %a "$WORK/new/nested/diary")" = "700" ] && echo 0 || echo 1)" \
  "so are the parents it has to create"
rm -rf -- "$WORK/new"

reset_diary
"$CLI" ensure 2026-07-08 "# heading" >/dev/null
check "$([ $? -eq 0 ] && echo 0 || echo 1)" "the default private folder still just works"

# ---------------------------------------------------------- the race window

section "a link planted in the race window"

# Deterministic, not a timing loop: a `mktemp` shim on PATH runs at the exact
# point inside ensure that is after every check on the entry and before the
# entry is created, and plants a symlink there -- what a concurrent attacker
# would have to win. (Once the folder is private nobody else can do this; the
# property tested is that even then the write cannot go through the link.)
SHIMS="$WORK/shims"
mkdir -p "$SHIMS"
cat >"$SHIMS/mktemp" <<'SHIM'
#!/usr/bin/env bash
for arg; do :; done
ln -sfn -- "$RACE_TARGET" "${arg%.XXXXXX}"
PATH=${PATH#*:} exec mktemp "$@"
SHIM
chmod +x "$SHIMS/mktemp"

race() { PATH="$SHIMS:$PATH" RACE_TARGET=$1 "$CLI" ensure "$2" "# heading" >"$WORK/out" 2>/dev/null; }

reset_diary
: >"$WORK/victim-empty"
race "$WORK/victim-empty" 2026-08-01
status=$?
check "$([ ! -s "$WORK/victim-empty" ] && echo 0 || echo 1)" "a link to an empty file planted mid-ensure is not written through"
check "$([ "$status" -ne 0 ] && [ ! -s "$WORK/out" ] && echo 0 || echo 1)" \
  "ensure then fails and prints no path, so the editor never opens the link"

reset_diary
printf 'keep me\n' >"$WORK/victim-full"
race "$WORK/victim-full" 2026-08-02
check "$([ "$(cat "$WORK/victim-full")" = "keep me" ] && echo 0 || echo 1)" \
  "a link to a file with content planted mid-ensure leaves it untouched"

reset_diary
printf 'x\n' >"$WORK/diary/2026-08-03.md"
: >"$WORK/diary/2026-08-03.md"
race "$WORK/victim-empty" 2026-08-03
check "$([ ! -s "$WORK/victim-empty" ] && echo 0 || echo 1)" \
  "the zero-byte refill path cannot be redirected mid-ensure either"

reset_diary
mkfifo "$WORK/victim-fifo"
timeout 5 env PATH="$SHIMS:$PATH" RACE_TARGET="$WORK/victim-fifo" "$CLI" ensure 2026-08-04 "# heading" >/dev/null 2>&1
status=$?
check "$([ "$status" -ne 124 ] && echo 0 || echo 1)" \
  "a link to a FIFO planted mid-ensure is never opened (noclobber alone would block on it)"

check "$([ -z "$(find "$WORK/diary" -name '*.XXXXXX' -o -name '*.md.*')" ] && echo 0 || echo 1)" \
  "no temporary files are left behind in the folder"

# No hard links (exFAT and the like): ensure still creates the entry.
cat >"$SHIMS/ln" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$SHIMS/ln"
rm -f "$SHIMS/mktemp"
reset_diary
out=$(PATH="$SHIMS:$PATH" "$CLI" ensure 2026-08-05 "# heading" 2>/dev/null)
check "$([ -n "$out" ] && [ -s "$out" ] && echo 0 || echo 1)" "on a filesystem without hard links, ensure still writes the entry"
rm -rf -- "$SHIMS"

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
