#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODE_ROOTS=("$ROOT_DIR/Sources" "$ROOT_DIR/Features")
# shellcheck source=sparkle_release.env
source "$ROOT_DIR/scripts/sparkle_release.env"

CONTENT_FORBIDDEN='NSPasteboard|UIPasteboard|CGWindowListCreateImage|ScreenCaptureKit|SCStream|AVCaptureSession|AVAudioEngine|keyboardGetUnicodeString|NSEvent\.characters|CGEventKeyboardGetUnicodeString'
EXECUTION_FORBIDDEN='NSAppleScript|osascript|Process\(|NSTask|/bin/sh|/bin/bash'

failed=false

if grep -R -nE "$CONTENT_FORBIDDEN" "${CODE_ROOTS[@]}"; then
  echo "Forbidden content-capture API found." >&2
  failed=true
fi
if grep -R -nE "$EXECUTION_FORBIDDEN" "${CODE_ROOTS[@]}"; then
  echo "Forbidden shell/automation execution API found." >&2
  failed=true
fi

# Activity/verification networking remains isolated to the opaque commitment uploader.
# Sparkle owns its own HTTPS update transport inside the reviewed, exact-pinned dependency;
# LocalHistory source must not grow a second ad-hoc networking path for updates.
while IFS= read -r match; do
  file="${match%%:*}"
  if [[ "$file" != *"/CommitmentUploader.swift" ]]; then
    echo "Unexpected first-party network API outside CommitmentUploader.swift: $match" >&2
    failed=true
  fi
done < <(grep -R -nE 'URLSession|HTTPURLResponse|URLRequest' "${CODE_ROOTS[@]}" || true)

# Never allow obviously sensitive event fields into the anchor upload model.
ANCHOR_MODEL="$ROOT_DIR/Sources/LocalHistoryCore/SealModels.swift"
if grep -nE 'AnchorUploadRequest' "$ANCHOR_MODEL" >/dev/null; then
  block="$(awk '/public struct AnchorUploadRequest/{flag=1} flag{print} /^}/{if(flag){exit}}' "$ANCHOR_MODEL")"
  if echo "$block" | grep -Ei 'window|url|pointer|keyboard|scroll|applicationName|bundleIdentifier|eventRoots|minuteStart|minuteEnd'; then
    echo "AnchorUploadRequest appears to contain detailed activity fields." >&2
    failed=true
  fi
fi

# Apple Screen Time private stores are permitted only through the isolated read-only adapter.
APPLE_SYSTEM_SOURCE="$ROOT_DIR/Sources/LocalHistoryApp/AppleScreenTime/AppleSystemScreenTimeSource.swift"
if [[ -f "$APPLE_SYSTEM_SOURCE" ]]; then
  if ! grep -Fq 'SQLITE_OPEN_READONLY' "$APPLE_SYSTEM_SOURCE"; then
    echo "Apple system Screen Time SQLite access is not explicitly read-only." >&2
    failed=true
  fi
  if grep -nE 'sqlite3_exec|SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|INSERT[[:space:]]|UPDATE[[:space:]]|DELETE[[:space:]]|VACUUM|FileHandle\(forWritingTo:|\.write\(to:' "$APPLE_SYSTEM_SOURCE"; then
    echo "Apple system Screen Time adapter appears capable of mutating Apple-owned stores." >&2
    failed=true
  fi
fi

# The deprecated LocalHistory-derived Screen Time approximation must not return.
if [[ -e "$ROOT_DIR/Sources/LocalHistoryApp/AppleScreenTime/LiveMacScreenTimeSource.swift" ]]; then
  echo "Deprecated LocalHistory-derived Screen Time source is still present." >&2
  failed=true
fi

# Supply-chain rule: Sparkle is the only remote Swift dependency, and it must stay exact-pinned.
EXPECTED_SPARKLE=".package(url: \"$SPARKLE_PACKAGE_URL\", exact: \"$SPARKLE_VERSION\")"
REMOTE_DEPENDENCY_COUNT="$(grep -cE '\.package\s*\(' "$ROOT_DIR/Package.swift" || true)"
if [[ "$REMOTE_DEPENDENCY_COUNT" != "1" ]] || ! grep -Fq "$EXPECTED_SPARKLE" "$ROOT_DIR/Package.swift"; then
  echo "SwiftPM dependencies must contain exactly the reviewed Sparkle $SPARKLE_VERSION package pin." >&2
  failed=true
fi
if grep -nE '\.package\s*\(' "$ROOT_DIR/Package.swift" | grep -Fv "$EXPECTED_SPARKLE"; then
  echo "Unexpected remote Swift package dependency found." >&2
  failed=true
fi

if [[ "$failed" == true ]]; then
  echo "Privacy-boundary audit failed. Review the matches above." >&2
  exit 1
fi

echo "Privacy-boundary audit passed: sensitive capture APIs remain prohibited; Apple Screen Time access is isolated and read-only; first-party networking is limited to opaque commitments; Sparkle is the sole exact-pinned update dependency."
