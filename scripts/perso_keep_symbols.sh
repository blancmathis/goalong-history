#!/bin/bash
# make perso: keep the main executable and its dSYM for the last KEEP perso builds, one folder per commit,
# so a later stall report (offsets in "Goalong History") can be resolved with atos:
#   atos -arch arm64 -o <dir>/LocalHistory.dSYM/Contents/Resources/DWARF/LocalHistory -l <load address> <addresses>
# Usage: perso_keep_symbols.sh APP DSYM COMMIT DEST [KEEP=3]
#   APP    the built "Goalong History.app"; its main executable is copied.
#   DSYM   the matching .dSYM (may be absent: the executable is kept alone). A dSYM whose UUID differs
#          from the executable's is not kept (it would resolve wrong lines).
#   DEST   root folder; each build lands in DEST/<commit>/. Folders beyond the KEEP newest are removed.
# Never fails the caller's build: errors are reported and exit non-zero, make perso only warns.
set -euo pipefail

APP="${1:?app}" DSYM="${2-}" COMMIT="${3:?commit}" DEST="${4:?dest}" KEEP="${5:-3}"
[[ "$COMMIT" =~ ^[0-9a-f]{7,40}$ ]] || { echo "perso symbols: bad commit '$COMMIT'." >&2; exit 2; }
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || { echo "perso symbols: KEEP must be a positive number." >&2; exit 2; }
[[ "$DEST" == /* ]] || { echo "perso symbols: DEST must be absolute." >&2; exit 2; }
EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
EXE="$APP/Contents/MacOS/$EXE_NAME"
[[ -f "$EXE" ]] || { echo "perso symbols: no executable at $EXE." >&2; exit 1; }

uuids() { xcrun dwarfdump -u "$1" 2>/dev/null | awk '/^UUID:/ { print $2, $3 }' | sort; }

mkdir -p "$DEST"
# Kept outside Git: the folder is local evidence, never committed.
[[ -f "$DEST/.gitignore" ]] || printf '*\n' >"$DEST/.gitignore"
TARGET="$DEST/$COMMIT"
TMP="$(mktemp -d "$DEST/.incoming.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ditto "$EXE" "$TMP/$EXE_NAME"
exe_uuids="$(uuids "$EXE")"
dsym_note="none"
if [[ -n "$DSYM" && -d "$DSYM" ]]; then
  if [[ -n "$exe_uuids" && "$(uuids "$DSYM")" == "$exe_uuids" ]]; then
    ditto "$DSYM" "$TMP/${DSYM##*/}"
    dsym_note="${DSYM##*/}"
  else
    dsym_note="skipped (UUID differs from the executable)"
    echo "perso symbols: $DSYM does not match $EXE; dSYM not kept." >&2
  fi
fi
{
  echo "commit=$COMMIT"
  echo "build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  echo "kept_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "executable=$EXE_NAME"
  echo "dsym=$dsym_note"
  printf 'uuid=%s\n' "$exe_uuids"
} >"$TMP/build.txt"

rm -rf "$TARGET"
mv "$TMP" "$TARGET"
trap - EXIT
touch "$TARGET"   # a rebuild of the same commit counts as the newest

# Keep the KEEP newest commit folders (by the time they were kept).
n=0
while IFS= read -r dir; do
  n=$((n + 1))
  (( n > KEEP )) && rm -rf "$dir"
done < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec stat -f '%Fm %N' {} + | sort -rn | cut -d' ' -f2-)

echo "Perso symbols kept: $TARGET ($(du -sh "$TARGET" | cut -f1); all kept builds $(du -sh "$DEST" | cut -f1))"
