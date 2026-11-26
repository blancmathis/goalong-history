#!/bin/bash
# Tests scripts/perso_keep_symbols.sh: make perso keeps the executable + dSYM of the last 3 builds by commit,
# and atos resolves an address of a kept build after newer builds. No Goalong build, no install.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP="$ROOT/scripts/perso_keep_symbols.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/perso-symbols-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A tiny app whose executable has a known function, built with a matching dSYM.
make_build() { # name variant
  local d="$T/$1" app="$T/$1/Goalong History.app"
  mkdir -p "$app/Contents/MacOS"
  printf 'int stall_marker_%s(int x) { return x * 3 + 1; }\nint main(int c, char **v) { (void)v; return stall_marker_%s(c); }\n' "$2" "$2" >"$d/main.c"
  cc -g -O0 -c -o "$d/main.o" "$d/main.c"
  cc -g -o "$d/LocalHistory" "$d/main.o"
  dsymutil "$d/LocalHistory" -o "$d/LocalHistory.dSYM"
  cp "$d/LocalHistory" "$app/Contents/MacOS/Goalong History"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string Goalong History' -c 'Add :CFBundleVersion string 1' "$app/Contents/Info.plist" >/dev/null
}
for v in a b c d; do make_build "$v" "$v"; done
DEST="$T/suivi/dsym"
c1=1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa c2=2222222aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
c3=3333333aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa c4=4444444aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bash "$KEEP" "$T/a/Goalong History.app" "$T/a/LocalHistory.dSYM" "$c1" "$DEST" >/dev/null
bash "$KEEP" "$T/b/Goalong History.app" "$T/b/LocalHistory.dSYM" "$c2" "$DEST" >/dev/null
bash "$KEEP" "$T/c/Goalong History.app" "$T/c/LocalHistory.dSYM" "$c3" "$DEST" >/dev/null
# Rebuild of the oldest commit: it becomes the newest, so c2 is the one dropped next.
bash "$KEEP" "$T/a/Goalong History.app" "$T/a/LocalHistory.dSYM" "$c1" "$DEST" >/dev/null
bash "$KEEP" "$T/d/Goalong History.app" "$T/d/LocalHistory.dSYM" "$c4" "$DEST" >/dev/null

kept="$(cd "$DEST" && ls | sort | tr '\n' ' ')"
[[ "$kept" == "$c1 $c3 $c4 " ]] || fail "expected the 3 newest commits ($c1 $c3 $c4), kept: $kept"
[[ "$(cat "$DEST/.gitignore")" == '*' ]] || fail "kept symbols must stay outside Git"
for c in "$c1" "$c3" "$c4"; do
  [[ -x "$DEST/$c/Goalong History" ]] || fail "$c: executable missing"
  [[ -d "$DEST/$c/LocalHistory.dSYM" ]] || fail "$c: dSYM missing"
  grep -F "commit=$c" "$DEST/$c/build.txt" >/dev/null || fail "$c: build.txt lacks the commit"
done

# atos on the kept dSYM of an older build (c3 = variant c) resolves its own function, after newer builds.
addr="$(nm "$DEST/$c3/Goalong History" | awk '/ _stall_marker_c$/ { print "0x" $1 }')"
[[ -n "$addr" ]] || fail "marker symbol not found"
sym="$(xcrun atos -arch "$(uname -m)" -o "$DEST/$c3/LocalHistory.dSYM/Contents/Resources/DWARF/LocalHistory" -l 0x100000000 "$addr")"
[[ "$sym" == *"stall_marker_c"*"main.c:1"* ]] || fail "atos did not resolve the kept build: $sym"

# A dSYM from another build is refused: wrong lines are worse than none. The executable is still kept.
c5=5555555aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bash "$KEEP" "$T/a/Goalong History.app" "$T/b/LocalHistory.dSYM" "$c5" "$DEST" >/dev/null 2>&1
[[ -x "$DEST/$c5/Goalong History" && ! -e "$DEST/$c5/LocalHistory.dSYM" ]] || fail "mismatched dSYM must not be kept"
# No dSYM at all: executable alone.
c6=6666666aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bash "$KEEP" "$T/d/Goalong History.app" "$T/missing.dSYM" "$c6" "$DEST" >/dev/null
[[ -x "$DEST/$c6/Goalong History" ]] || fail "executable must be kept without a dSYM"
[[ "$(cd "$DEST" && ls | wc -l | tr -d ' ')" == 3 ]] || fail "more than 3 builds kept"
# Bad input is refused.
if bash "$KEEP" "$T/a/Goalong History.app" "" "not-a-commit" "$DEST" >/dev/null 2>&1; then fail "bad commit accepted"; fi

# make perso calls it for every installed perso build.
grep -F 'scripts/perso_keep_symbols.sh' "$ROOT/scripts/local_try.sh" >/dev/null || fail "local_try.sh does not keep perso symbols"
echo "perso_keep_symbols: ok"
