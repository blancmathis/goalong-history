#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "Source security verification failed: $*" >&2
  exit 1
}

grep -Fq '.define("GOALONG_UNIFIED_APP")' Package.swift \
  || fail "the unified app compile marker is missing"
for excluded in AppAttestManager.swift CommitmentUploader.swift SoftwareUpdateManager.swift LocalOnlyCodexAppServerClient.swift; do
  grep -Fq "\"$excluded\"" Package.swift \
    || fail "$excluded is not physically excluded from the public app target"
done

if grep -Eq '\.package[[:space:]]*\(' Package.swift; then
  fail "a remote Swift package dependency is present"
fi

for retired_tool in \
  scripts/fetch_sparkle_tools.sh \
  scripts/generate_sparkle_appcast.sh \
  scripts/setup_sparkle_keys.sh \
  scripts/sparkle_release.env \
  scripts/verify_sparkle_bundle.sh; do
  [[ ! -e "$retired_tool" && ! -L "$retired_tool" ]] \
    || fail "retired updater tooling is still present: $retired_tool"
done

for required in \
  'static let disabledByDefault' \
  'case localComputerHistory' \
  'case appleScreenTime' \
  'case aiConversations' \
  'case chatGPTAnalysis'; do
  grep -Fq "$required" Sources/LocalHistoryApp/CapabilityConsentStore.swift \
    || fail "consent invariant is missing: $required"
done

for default_off in \
  'captureClicks: false' \
  'captureScroll: false' \
  'captureKeyboardActivity: false' \
  'captureShortcuts: false' \
  'captureWindowTitles: false' \
  'captureElementLabels: false' \
  'captureURLs: false' \
  'verificationEnabled: false' \
  'enableAppAttest: false'; do
  grep -Fq "$default_off" Sources/LocalHistoryCore/Config.swift \
    || fail "all-off recorder default is missing: $default_off"
done

for active_file in Package.swift scripts/build_app.sh scripts/build_app_core.sh .github/workflows/macos.yml .github/workflows/release.yml .github/workflows/continuous-release.yml; do
  if grep -Eq 'Goalong History Local|ai\.goalong\.localhistory\.local|edition connected|LOCALHISTORY_BUILD_EDITION[=:]local' "$active_file"; then
    fail "a second app identity remains in $active_file"
  fi
done

./scripts/audit_privacy_boundaries.sh

if [[ "${1:-}" == "--with-tests" ]]; then
  xcrun swift test \
    --filter CapabilityConsentStoreTests \
    --filter GoalongReadOnlyQueryBrokerTests \
    --filter BuildEditionSecurityTests
fi

cat <<'EOF'
Goalong source security verification passed.
- one public app identity
- sensitive capabilities off by default
- no first-party HTTP client, in-app updater or remote Swift dependency in the app target
- Screen Time CLI access brokered through the consented app
- Agent Activity direct-source readers remain read-only and metadata-only on disk

Honest residual boundary: Full Disk Access readers still run in the main app process. Optional
ChatGPT analysis starts the fixed local Codex app-server bridge only after separate consent.
EOF
