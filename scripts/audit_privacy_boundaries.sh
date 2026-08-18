#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CONTENT_FORBIDDEN='NSPasteboard|UIPasteboard|CGWindowListCreateImage|ScreenCaptureKit|SCStream|AVCaptureSession|AVAudioEngine|keyboardGetUnicodeString|NSEvent\.characters|CGEventKeyboardGetUnicodeString'
EXECUTION_FORBIDDEN='NSAppleScript|osascript|Process\(|NSTask|/bin/sh|/bin/bash'

failed=false

if grep -R -nE "$CONTENT_FORBIDDEN" "$ROOT_DIR/Sources"; then
  echo "Forbidden content-capture API found." >&2
  failed=true
fi
if grep -R -nE "$EXECUTION_FORBIDDEN" "$ROOT_DIR/Sources"; then
  echo "Forbidden shell/automation execution API found." >&2
  failed=true
fi

# Network access is intentionally limited to the opaque commitment uploader.
while IFS= read -r match; do
  file="${match%%:*}"
  if [[ "$file" != *"/CommitmentUploader.swift" ]]; then
    echo "Unexpected network API outside CommitmentUploader.swift: $match" >&2
    failed=true
  fi
done < <(grep -R -nE 'URLSession|HTTPURLResponse|URLRequest' "$ROOT_DIR/Sources" || true)

# Never allow obviously sensitive event fields into the anchor upload model.
ANCHOR_MODEL="$ROOT_DIR/Sources/LocalHistoryCore/SealModels.swift"
if grep -nE 'AnchorUploadRequest' "$ANCHOR_MODEL" >/dev/null; then
  block="$(awk '/public struct AnchorUploadRequest/{flag=1} flag{print} /^}/{if(flag){exit}}' "$ANCHOR_MODEL")"
  if echo "$block" | grep -Ei 'window|url|pointer|keyboard|scroll|applicationName|bundleIdentifier|eventRoots|minuteStart|minuteEnd'; then
    echo "AnchorUploadRequest appears to contain detailed activity fields." >&2
    failed=true
  fi
fi

if grep -nE '\.package\s*\(' "$ROOT_DIR/Package.swift"; then
  echo "Remote Swift package dependency found." >&2
  failed=true
fi

if [[ "$failed" == true ]]; then
  echo "Privacy-boundary audit failed. Review the matches above." >&2
  exit 1
fi

echo "Privacy-boundary audit passed: no clipboard/screen/audio/raw-key decoding/shell APIs; networking is isolated to opaque commitment upload."
