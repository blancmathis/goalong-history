#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODE_ROOTS=("$ROOT_DIR/Sources" "$ROOT_DIR/Features")
# shellcheck source=sparkle_release.env
source "$ROOT_DIR/scripts/sparkle_release.env"

CONTENT_FORBIDDEN='NSPasteboard|UIPasteboard|CGWindowListCreateImage|ScreenCaptureKit|SCStream|AVCaptureSession|AVAudioEngine|keyboardGetUnicodeString|NSEvent\.characters|CGEventKeyboardGetUnicodeString'
SHELL_EXECUTION_FORBIDDEN='NSAppleScript|osascript|NSTask|/bin/sh|/bin/bash'
CODEX_BRIDGE="$ROOT_DIR/Sources/LocalHistoryApp/ChatGPT/CodexAppServerClient.swift"

failed=false

if grep -R -nE "$CONTENT_FORBIDDEN" "${CODE_ROOTS[@]}"; then
  echo "Forbidden content-capture API found." >&2
  failed=true
fi
if grep -R -nE "$SHELL_EXECUTION_FORBIDDEN" "${CODE_ROOTS[@]}"; then
  echo "Forbidden shell/automation execution API found." >&2
  failed=true
fi

# Process execution is isolated to one reviewed bridge. It may launch only the exact
# Codex executable discovered from reviewed locations, with the fixed `app-server`
# argument. No shell, arbitrary command, or user-provided argument vector is allowed.
while IFS= read -r match; do
  file="${match%%:*}"
  if [[ "$file" != "$CODEX_BRIDGE" ]]; then
    echo "Unexpected Process API outside the Codex app-server bridge: $match" >&2
    failed=true
  fi
done < <(grep -R -nE 'Process\(' "${CODE_ROOTS[@]}" || true)

if [[ -f "$CODEX_BRIDGE" ]]; then
  if ! grep -Fq 'process.executableURL = executableURL' "$CODEX_BRIDGE" \
    || ! grep -Fq 'process.arguments = ["app-server"]' "$CODEX_BRIDGE"; then
    echo "Codex bridge no longer pins the reviewed executable and app-server argument." >&2
    failed=true
  fi
  if grep -nE 'process\.arguments[[:space:]]*=.*CommandLine|process\.arguments[[:space:]]*=.*environment|executableURL[[:space:]]*=[[:space:]]*URL\(fileURLWithPath:[[:space:]]*[^e]' "$CODEX_BRIDGE"; then
    echo "Codex bridge appears to accept an unreviewed executable or argument source." >&2
    failed=true
  fi

  # The child process receives a strict environment allow-list so shell tools cannot read API
  # keys, cloud credentials, proxy passwords or SSH-agent sockets inherited by the app.
  if ! grep -Fq 'process.environment = Self.codexEnvironment(' "$CODEX_BRIDGE" \
    || ! grep -Fq 'let allowedKeys = ["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE"]' "$CODEX_BRIDGE" \
    || ! grep -Fq 'environment["SHELL"] = "/bin/zsh"' "$CODEX_BRIDGE" \
    || ! grep -Fq 'environment["CODEX_HOME"] = codexHomeURL.path' "$CODEX_BRIDGE"; then
    echo "Codex bridge no longer applies the reviewed child-environment allow-list." >&2
    failed=true
  fi

  # Recap agents must fail closed on old Codex versions: experimental permission APIs are
  # enabled, the exact custom profile and workspace roots are requested and verified, and
  # threads remain ephemeral with execution environments disabled.
  for required_fragment in \
    '"experimentalApi": true' \
    '"permissions": Self.recapPermissionProfile' \
    '"runtimeWorkspaceRoots": [workingDirectory.path]' \
    '"ephemeral": true' \
    '"environments": [] as [Any]' \
    'started["activePermissionProfile"]' \
    'Self.pathsMatchExactly(roots, expected: [workingDirectory])' \
    'default_permissions = "\(Self.recapPermissionProfile)"' \
    '[permissions.goalong-recap.filesystem]' \
    '":minimal" = "read"' \
    '":workspace_roots" = "read"' \
    '[permissions.goalong-recap.network]' \
    'web_search = "disabled"'; do
    if ! grep -Fq "$required_fragment" "$CODEX_BRIDGE"; then
      echo "Codex recap confinement invariant is missing: $required_fragment" >&2
      failed=true
    fi
  done
  if grep -nE '"sandbox(Policy)?"[[:space:]]*:|readOnlyAccess|workspaceWrite|dangerFullAccess' "$CODEX_BRIDGE"; then
    echo "Codex bridge contains a legacy or broadened sandbox override instead of the reviewed permission profile." >&2
    failed=true
  fi
fi

# Activity/verification networking remains isolated to the opaque commitment uploader.
# The optional ChatGPT recap path delegates its HTTPS transport and managed OAuth tokens
# to the reviewed local Codex app-server process; Goalong source must not add direct AI networking.
# Sparkle owns its own HTTPS update transport inside the reviewed, exact-pinned dependency.
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

echo "Privacy-boundary audit passed: sensitive capture APIs remain prohibited; Apple Screen Time access is isolated and read-only; Process execution is isolated to the fixed Codex app-server bridge; first-party networking is limited to opaque commitments; Sparkle is the sole exact-pinned update dependency."
