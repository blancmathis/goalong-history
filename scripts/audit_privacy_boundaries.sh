#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODE_ROOTS=("$ROOT_DIR/Sources" "$ROOT_DIR/Features")
AGENT_ACTIVITY_SOURCE_ROOT="$ROOT_DIR/Features/AgentActivity/Sources"
AGENT_ACTIVITY_APP_ROOT="$ROOT_DIR/Sources/LocalHistoryApp/AgentActivity"
AGENT_ACTIVITY_RUNTIME_ROOTS=(
  "$AGENT_ACTIVITY_SOURCE_ROOT"
  "$AGENT_ACTIVITY_APP_ROOT"
  "$ROOT_DIR/Sources/LocalHistoryApp/AppDelegate.swift"
  "$ROOT_DIR/Sources/LocalHistoryApp/main.swift"
)
AGENT_ACTIVITY_DIRECT_ADAPTER="$AGENT_ACTIVITY_SOURCE_ROOT/SourceAdapters.swift"
AGENT_ACTIVITY_MODELS="$AGENT_ACTIVITY_SOURCE_ROOT/Models.swift"
AGENT_ACTIVITY_MIGRATION="$ROOT_DIR/Sources/LocalHistoryApp/AppPaths.swift"
AGENT_ACTIVITY_RECAP_CONTEXT="$ROOT_DIR/Sources/LocalHistoryApp/ChatGPT/ChatGPTRecapContext.swift"
AGENT_ACTIVITY_RECAP_RUNTIME="$ROOT_DIR/Sources/LocalHistoryApp/ChatGPT/ChatGPTRecapRuntime.swift"
CONTENT_FORBIDDEN='NSPasteboard|UIPasteboard|CGWindowListCreateImage|ScreenCaptureKit|SCStream|AVCaptureSession|AVAudioEngine|keyboardGetUnicodeString|NSEvent\.characters|CGEventKeyboardGetUnicodeString'
SHELL_EXECUTION_FORBIDDEN='NSAppleScript|osascript|NSTask|/bin/sh|/bin/bash'
CODEX_BRIDGE="$ROOT_DIR/Sources/LocalHistoryApp/ChatGPT/CodexAppServerClient.swift"
CLIPBOARD_WRITER="$ROOT_DIR/Sources/LocalHistoryApp/GoalongClipboardWriter.swift"
CLI_CONTRACT="$ROOT_DIR/Sources/LocalHistoryQueryCLI/GoalongCLIContract.swift"
CLI_IMPLEMENTATION="$ROOT_DIR/Sources/LocalHistoryQueryCLI/LocalHistoryQueryCLI.swift"
CLI_HELP_PAGE="$ROOT_DIR/Sources/LocalHistoryApp/CLIHelpPage.swift"
CLI_DOCS="$ROOT_DIR/docs/CLI.md"

failed=false

if grep -R -nE "$CONTENT_FORBIDDEN" "${CODE_ROOTS[@]}"; then
  echo "Forbidden content-capture API found." >&2
  failed=true
fi

# A user-triggered copy action may write Goalong's own static help text to the clipboard through
# one reviewed Carbon boundary. Clipboard reads remain forbidden everywhere, and pasteboard APIs
# may not spread to another source file.
while IFS= read -r match; do
  file="${match%%:*}"
  if [[ "$file" != "$CLIPBOARD_WRITER" ]]; then
    echo "Pasteboard API outside the reviewed write-only helper: $match" >&2
    failed=true
  fi
done < <(grep -R -nE --include='*.swift' 'Pasteboard(Create|Clear|PutItemFlavor|Copy|Get)' "${CODE_ROOTS[@]}" || true)
if [[ -f "$CLIPBOARD_WRITER" ]]; then
  if ! grep -Fq 'PasteboardClear(clipboard)' "$CLIPBOARD_WRITER" \
    || ! grep -Fq 'PasteboardPutItemFlavor(' "$CLIPBOARD_WRITER"; then
    echo "The reviewed clipboard helper is no longer an explicit clear-and-write boundary." >&2
    failed=true
  fi
  if grep -nE 'Pasteboard(Copy|Get)|NSPasteboard|UIPasteboard' "$CLIPBOARD_WRITER"; then
    echo "The reviewed clipboard helper contains a clipboard read-capable API." >&2
    failed=true
  fi
fi

# The public agent contract must remain honest about formats and the two explicit local writes:
# active-day Screen Time replaces one compact Goalong record, and export-proof creates a file.
for contract_surface in "$CLI_CONTRACT" "$CLI_HELP_PAGE" "$CLI_DOCS"; do
  if grep -nE 'Every result is structured JSON|Every command emits sorted JSON|All commands are read-only|identically signed Goalong app' "$contract_surface"; then
    echo "Misleading CLI format, mutation or client-signature claim found in $contract_surface." >&2
    failed=true
  fi
done
for required_fragment in \
  'help --json' \
  'nonzero exit' \
  'active-day' \
  'export-proof' \
  'Foreground' \
  'unknown coverage'; do
  if ! grep -Fq "$required_fragment" "$CLI_CONTRACT"; then
    echo "Canonical CLI safety contract is missing: $required_fragment" >&2
    failed=true
  fi
done
if ! grep -Fq 'GoalongCLIContract.usageText' "$CLI_IMPLEMENTATION" \
  || ! grep -Fq 'GoalongCLIContract.agentInstructions' "$CLI_HELP_PAGE"; then
  echo "CLI parser help and in-app agent brief no longer share the canonical contract." >&2
  failed=true
fi
status_block="$(awk '/public static func statusPayload\(/{flag=1} flag{print} /private static func versionEnvelope\(/{if(flag){exit}}' "$CLI_IMPLEMENTATION")"
if echo "$status_block" | grep -nE 'directRead\(|requestScreenTime\(|Data\(contentsOf:.*(codex|claude|opencode)'; then
  echo "Metadata-only CLI status appears to read a conversation body or Apple Screen Time payload." >&2
  failed=true
fi

# The event callback may classify a key transiently, but raw key codes, exact
# modifiers and repeat flags must be discarded before entering the bounded queue.
EVENT_TAP_MONITOR="$ROOT_DIR/Sources/LocalHistoryApp/EventTapMonitor.swift"
if [[ -f "$EVENT_TAP_MONITOR" ]]; then
  pending_input="$(awk '/struct EventTapPendingInput: Equatable/{flag=1} flag{print} /struct EventTapIngressMetrics: Equatable/{if(flag){exit}}' "$EVENT_TAP_MONITOR")"
  if echo "$pending_input" | grep -nE 'keyCode|flagsRawValue|isRepeat'; then
    echo "Raw keyboard detail entered the event-tap ingress buffer." >&2
    failed=true
  fi
  if grep -nE 'keyboardEventAutorepeat|KeyDescriptor|CGEventKeyboardGetUnicodeString' "$EVENT_TAP_MONITOR"; then
    echo "Exact keyboard detail or character decoding returned to the event pipeline." >&2
    failed=true
  fi
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
  # enabled, the exact custom profile, working directory and non-expanding workspace roots are
  # requested and verified, and threads remain ephemeral with execution environments disabled.
  for required_fragment in \
    '"experimentalApi": true' \
    '"permissions": Self.recapPermissionProfile' \
    '"runtimeWorkspaceRoots": [workingDirectory.path]' \
    '"ephemeral": true' \
    '"environments": [] as [Any]' \
    'started["activePermissionProfile"]' \
    'started["cwd"]' \
    'Self.workspaceRootsAreConfined(roots, to: workingDirectory)' \
    'rawPaths.isEmpty || pathsMatchExactly(rawPaths, expected: [workingDirectory])' \
    'default_permissions = "\(Self.recapPermissionProfile)"' \
    '[permissions.goalong-recap.filesystem]' \
    '":minimal" = "read"' \
    '":workspace_roots" = "read"' \
    '[permissions.goalong-recap.network]' \
    'web_search = "disabled"' \
    '[features]' \
    'plugins = false' \
    'remote_plugin = false' \
    'goals = false' \
    'memories = false' \
    'shell_tool = false' \
    'Self.pruneEphemeralCodexArtifacts(at: codexHomeURL)' \
    '"plugins", "rollouts", "sessions", "skills"' \
    '"tmp"' \
    'databasePrefixes = ["goals_", "logs_", "memories_", "queue_", "state_"]'; do
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

# Goalong contains no first-party network client. Optional ChatGPT analysis delegates transport
# to the reviewed local Codex app-server process after a separate Goalong consent.
while IFS= read -r match; do
  file="${match%%:*}"
  if [[ "$file" != *"/CommitmentUploader.swift" ]]; then
    echo "Unexpected first-party network API outside CommitmentUploader.swift: $match" >&2
    failed=true
  fi
done < <(grep -R -nE 'URLSession|HTTPURLResponse|URLRequest' "${CODE_ROOTS[@]}" || true)
if ! grep -Fq '"CommitmentUploader.swift"' "$ROOT_DIR/Package.swift" \
  || ! grep -Fq '"SoftwareUpdateManager.swift"' "$ROOT_DIR/Package.swift" \
  || ! grep -Fq '"AppAttestManager.swift"' "$ROOT_DIR/Package.swift"; then
  echo "The retired network and updater implementations are not physically excluded from the app target." >&2
  failed=true
fi

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
APPLE_SYSTEM_SOURCE="$ROOT_DIR/Features/AppleSystemScreenTime/Sources/AppleSystemScreenTimeSource.swift"
if [[ -f "$APPLE_SYSTEM_SOURCE" ]]; then
  for required_fragment in \
    'SQLITE_OPEN_READONLY' \
    'SQLITE_OPEN_NOFOLLOW' \
    'sqlite3_db_readonly(database, "main") == 1' \
    'PRAGMA query_only=ON' \
    'PRAGMA temp_store=MEMORY' \
    'PRAGMA mmap_size=0' \
    'sqlite3_set_authorizer('; do
    if ! grep -Fq "$required_fragment" "$APPLE_SYSTEM_SOURCE"; then
      echo "Apple system Screen Time read-only invariant is missing: $required_fragment" >&2
      failed=true
    fi
  done
  if grep -nE 'sqlite3_exec|SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|INSERT[[:space:]]|UPDATE[[:space:]]|DELETE[[:space:]]|VACUUM|FileHandle\(forWritingTo:|\.write\(to:' "$APPLE_SYSTEM_SOURCE"; then
    echo "Apple system Screen Time adapter appears capable of mutating Apple-owned stores." >&2
    failed=true
  fi
fi

# LaunchServices is a network-capable escape hatch when handed an HTTP URL. Every app-side open
# must pass through the reviewed policy, which rejects HTTP(S) entirely in the Local edition.
WORKSPACE_OPEN_POLICY="$ROOT_DIR/Sources/LocalHistoryApp/WorkspaceOpenPolicy.swift"
if [[ ! -f "$WORKSPACE_OPEN_POLICY" ]] \
  || ! grep -Fq 'GoalongBuildCapabilities.permitsHTTPWorkspaceOpening' "$WORKSPACE_OPEN_POLICY" \
  || ! grep -Fq 'scheme == "https"' "$WORKSPACE_OPEN_POLICY"; then
  echo "The centralized NSWorkspace URL policy is missing or no longer edition-aware." >&2
  failed=true
fi
while IFS= read -r match; do
  file="${match%%:*}"
  if [[ "$file" != "$WORKSPACE_OPEN_POLICY" ]]; then
    echo "NSWorkspace.open bypasses the reviewed policy: $match" >&2
    failed=true
  fi
done < <(grep -R -nE --include='*.swift' 'NSWorkspace\.shared\.open\(' "$ROOT_DIR/Sources/LocalHistoryApp" || true)

# The deprecated LocalHistory-derived Screen Time approximation must not return.
if [[ -e "$ROOT_DIR/Sources/LocalHistoryApp/AppleScreenTime/LiveMacScreenTimeSource.swift" ]]; then
  echo "Deprecated LocalHistory-derived Screen Time source is still present." >&2
  failed=true
fi

# Agent Activity is a direct, read-only view over provider-owned histories. Runtime code must
# never regain the old versioned vault or another transcript/payload persistence path. Tests and
# migration documentation are intentionally outside these roots so they can name legacy behavior.
LEGACY_AGENT_ACTIVITY_IDENTIFIERS='captureFullContents|keepEveryVersion|blobsDirectory|manifestsDirectory|materializedDirectory|AgentHookInboxWriter'
if grep -R -nE --include='*.swift' "$LEGACY_AGENT_ACTIVITY_IDENTIFIERS" "${AGENT_ACTIVITY_RUNTIME_ROOTS[@]}"; then
  echo "Legacy Agent Activity content-vault mechanism found in runtime source." >&2
  failed=true
fi

AGENT_ACTIVITY_STORAGE_FILES=(
  "$AGENT_ACTIVITY_SOURCE_ROOT/ActivityStore.swift"
  "$AGENT_ACTIVITY_SOURCE_ROOT/HookInbox.swift"
)
AGENT_ACTIVITY_CONTENT_PATHS='"(blobs?|manifests?|materialized|hook-inbox|snapshots?|versions?|transcripts?|payloads?|contents?|bodies|messages?)"'
if grep -nE "$AGENT_ACTIVITY_CONTENT_PATHS" "${AGENT_ACTIVITY_STORAGE_FILES[@]}"; then
  echo "Agent Activity runtime declares a transcript/content storage path." >&2
  failed=true
fi

# Treat write-capable APIs as an allow-listed boundary, not merely as a list of old
# vault names. A renamed transcript archive must fail this audit unless its writer is
# deliberately reviewed and added here. ActivityStore is limited below to the v2
# metadata files, HookInbox to bounded wake-up signals, and IntegrationInstaller to
# provider hook configuration (never provider history).
AGENT_ACTIVITY_APPROVED_WRITERS=(
  "$AGENT_ACTIVITY_SOURCE_ROOT/ActivityStore.swift"
  "$AGENT_ACTIVITY_SOURCE_ROOT/HookInbox.swift"
  "$AGENT_ACTIVITY_SOURCE_ROOT/IntegrationInstaller.swift"
)
AGENT_ACTIVITY_WRITE_APIS='\.write\(to:|FileHandle\(forWritingTo:|FileHandle\(forUpdating:|createFile\(|copyItem\(|moveItem\(|replaceItem|removeItem\(|O_WRONLY|O_RDWR|O_CREAT|sqlite3_exec|SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|INSERT[[:space:]]|UPDATE[[:space:]]|DELETE[[:space:]]|VACUUM'
while IFS= read -r match; do
  file="${match%%:*}"
  approved=false
  for writer in "${AGENT_ACTIVITY_APPROVED_WRITERS[@]}"; do
    if [[ "$file" == "$writer" ]]; then
      approved=true
      break
    fi
  done
  if [[ "$approved" != true ]]; then
    echo "Unexpected Agent Activity write-capable API outside the reviewed writers: $match" >&2
    failed=true
  fi
done < <(grep -R -nE --include='*.swift' "$AGENT_ACTIVITY_WRITE_APIS" "${AGENT_ACTIVITY_RUNTIME_ROOTS[@]}" || true)

if [[ -f "$AGENT_ACTIVITY_SOURCE_ROOT/ActivityStore.swift" ]]; then
  for required_fragment in \
    'appendingPathComponent("configuration.json"' \
    'appendingPathComponent("index.json"' \
    'appendingPathComponent("signals"'; do
    if ! grep -Fq "$required_fragment" "$AGENT_ACTIVITY_SOURCE_ROOT/ActivityStore.swift"; then
      echo "Agent Activity metadata-store path invariant is missing: $required_fragment" >&2
      failed=true
    fi
  done
  while IFS= read -r match; do
    if [[ "$match" != *'appendingPathComponent("configuration.json"'* \
      && "$match" != *'appendingPathComponent("index.json"'* \
      && "$match" != *'appendingPathComponent("signals"'* \
      && "$match" != *'appendingPathComponent("\(provider.rawValue).json"'* ]]; then
      echo "Unreviewed Agent Activity metadata-store path: $match" >&2
      failed=true
    fi
  done < <(grep -n 'appendingPathComponent(' "$AGENT_ACTIVITY_SOURCE_ROOT/ActivityStore.swift" || true)
fi

if [[ -f "$AGENT_ACTIVITY_SOURCE_ROOT/HookInbox.swift" ]]; then
  if ! grep -Fq 'maximumSignalFileBytes = 16 * 1_024' "$AGENT_ACTIVITY_SOURCE_ROOT/HookInbox.swift" \
    || ! grep -Fq 'appendingPathComponent("signals"' "$AGENT_ACTIVITY_SOURCE_ROOT/HookInbox.swift"; then
    echo "Agent Activity hook writer is no longer limited to bounded signal metadata." >&2
    failed=true
  fi
  while IFS= read -r match; do
    if [[ "$match" != *'appendingPathComponent("signals"'* \
      && "$match" != *'appendingPathComponent(".writer.lock"'* \
      && "$match" != *'appendingPathComponent("\(provider.rawValue).json"'* ]]; then
      echo "Unreviewed Agent Activity signal-store path: $match" >&2
      failed=true
    fi
  done < <(grep -n 'appendingPathComponent(' "$AGENT_ACTIVITY_SOURCE_ROOT/HookInbox.swift" || true)
fi

# Direct readers, parsers and scanners may inspect original sources but must not write, copy,
# move, delete or mutate them. Persistence is limited to the reviewed metadata store and hook
# signal writer; provider integration configuration is reviewed separately.
AGENT_ACTIVITY_READ_ONLY_FILES=(
  "$AGENT_ACTIVITY_SOURCE_ROOT/SourceAdapters.swift"
  "$AGENT_ACTIVITY_SOURCE_ROOT/TranscriptParser.swift"
  "$AGENT_ACTIVITY_SOURCE_ROOT/Scanner.swift"
  "$AGENT_ACTIVITY_SOURCE_ROOT/Discovery.swift"
)
if grep -nE '\.write\(to:|FileHandle\(forWritingTo:|createFile\(|copyItem\(|moveItem\(|replaceItem|removeItem\(|sqlite3_exec|SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|INSERT[[:space:]]|UPDATE[[:space:]]|DELETE[[:space:]]|VACUUM' "${AGENT_ACTIVITY_READ_ONLY_FILES[@]}"; then
  echo "Agent Activity direct-source analysis appears capable of mutating source storage." >&2
  failed=true
fi

# The two Codable index structures are the complete on-disk Agent Activity schema. Reject fields
# that could turn either of them into a transcript cache while allowing transient summaries.
if [[ -f "$AGENT_ACTIVITY_MODELS" ]]; then
  persisted_agent_index="$({
    awk '/public struct AgentSourceIndexEntry: Codable/{flag=1} /\/\/\/ An index entry paired with a non-persisted/{flag=0} flag{print}' "$AGENT_ACTIVITY_MODELS"
    awk '/public struct AgentActivityIndex: Codable/{flag=1} /public struct AgentActivityOverview:/{flag=0} flag{print}' "$AGENT_ACTIVITY_MODELS"
  })"
  if echo "$persisted_agent_index" | grep -nEi 'public var [[:alnum:]_]*(content|payload|transcript|body|messages?|excerpt|summary|commands?|tools?|touchedFiles|models?)[[:alnum:]_]*[[:space:]]*:'; then
    echo "Persisted Agent Activity index schema contains transcript-derived content." >&2
    failed=true
  fi
fi

# Daily Activity may project bounded user requests and final assistant replies transiently from
# each provider's original storage. The durable recap schema must remain a small derived
# five-line assessment, never the prompt, source excerpts, paths, transcript bodies or message
# collection.
if [[ -f "$AGENT_ACTIVITY_RECAP_CONTEXT" ]]; then
  for required_fragment in \
    'User-visible dialogue (transient; not persisted by Goalong)' \
    'Only user-authored requests and final assistant replies are included below.' \
    'The final five-line report must paraphrase rather than quote the dialogue.'; do
    if ! grep -Fq "$required_fragment" "$AGENT_ACTIVITY_RECAP_CONTEXT"; then
      echo "Transient Agent Activity recap boundary is missing: $required_fragment" >&2
      failed=true
    fi
  done
fi
if [[ -f "$AGENT_ACTIVITY_RECAP_RUNTIME" ]]; then
  persisted_recap_schema="$(awk '/struct ChatGPTDailyRecap: Codable/{flag=1} /enum ChatGPTRecapPersistence/{flag=0} flag{print}' "$AGENT_ACTIVITY_RECAP_RUNTIME")"
  if echo "$persisted_recap_schema" | grep -nEi 'let [[:alnum:]_]*(prompt|contextData|sourcePath|relativePath|transcript|body|messages?|excerpt|commands?|tools?|touchedFiles)[[:alnum:]_]*[[:space:]]*:'; then
    echo "Daily Activity persistence schema contains source or transcript content fields." >&2
    failed=true
  fi
  for required_fragment in \
    'summaryLines.count == ChatGPTDailyAssessment.requiredSummaryLineCount' \
    'static let maximumMarkdownBytes = 8 * 1_024' \
    'static let maximumJSONBytes = 64 * 1_024'; do
    if ! grep -Fq "$required_fragment" "$AGENT_ACTIVITY_RECAP_RUNTIME"; then
      echo "Bounded Daily Activity persistence invariant is missing: $required_fragment" >&2
      failed=true
    fi
  done
fi

# The retired ChatGPT export importer may clean up an old archive, but cannot read an export or
# create a normalized transcript archive. Daily analysis uses direct provider sources instead.
CHATGPT_HISTORY_STORE="$ROOT_DIR/Sources/LocalHistoryApp/ChatGPT/ChatGPTHistoryStore.swift"
if [[ ! -f "$CHATGPT_HISTORY_STORE" ]] \
  || ! grep -Fq 'throw ChatGPTHistoryStoreError.importsDisabled' "$CHATGPT_HISTORY_STORE" \
  || grep -Fq 'importConversations(' "$AGENT_ACTIVITY_RECAP_RUNTIME"; then
  echo "The retired ChatGPT transcript importer can still be reached or create a second vault." >&2
  failed=true
fi

# The one-time v2 migration may delete the retired vault only after normalizing recognized
# metadata. It must never byte-copy an arbitrary legacy index/configuration into the new store.
if [[ -f "$AGENT_ACTIVITY_MIGRATION" ]]; then
  for required_fragment in \
    'agent-activity-v2' \
    'migrateValidatedConfiguration(' \
    'migrateValidatedIndex(' \
    'migratedIndexJSONContainsOnlyMetadataKeys(' \
    'readRegularFileNoFollow(' \
    'isValidMigratedIndex(' \
    'validatePreparedAgentActivityStore(' \
    'removeRecognizableLegacyQuarantines(' \
    'maximumMigratedConfigurationBytes' \
    'maximumMigratedIndexBytes'; do
    if ! grep -Fq "$required_fragment" "$AGENT_ACTIVITY_MIGRATION"; then
      echo "Agent Activity v2 migration invariant is missing: $required_fragment" >&2
      failed=true
    fi
  done
  if grep -nE 'copyItem\(' "$AGENT_ACTIVITY_MIGRATION"; then
    echo "Agent Activity migration contains an unvalidated byte-copy path." >&2
    failed=true
  fi
  if grep -nE 'mergeMissingSignalFiles|migrateValidatedSignal|maximumMigratedSignalBytes' "$AGENT_ACTIVITY_MIGRATION"; then
    echo "Agent Activity migration must discard regenerable legacy hook signals instead of copying free-form event values." >&2
    failed=true
  fi
fi

# Provider-specific adapters and immutable-at-the-API-boundary SQLite access are mandatory.
# A non-empty OpenCode WAL is deferred: opening the main database with `immutable=1` is the only
# mode that has proven not to create or mutate SQLite sidecars during direct-source analysis.
if [[ ! -f "$AGENT_ACTIVITY_DIRECT_ADAPTER" ]]; then
  echo "Agent Activity direct-source adapter is missing." >&2
  failed=true
else
  for required_fragment in \
    'enum AgentDirectSourceReader' \
    'discoverCodex(' \
    'discoverClaude(' \
    'discoverOpenCode(' \
    'discoverGemini(' \
    'discoverCopilot(' \
    'case .codex:' \
    'case .claudeCode:' \
    'case .openCode:' \
    'case .gemini:' \
    'case .copilot:' \
    'SQLITE_OPEN_READONLY' \
    'SQLITE_OPEN_URI' \
    'mode=ro&immutable=1'; do
    if ! grep -Fq "$required_fragment" "$AGENT_ACTIVITY_DIRECT_ADAPTER"; then
      echo "Agent Activity direct-read invariant is missing: $required_fragment" >&2
      failed=true
    fi
  done
  if grep -nE 'SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|sqlite3_exec|INSERT[[:space:]]|UPDATE[[:space:]]|DELETE[[:space:]]|VACUUM' "$AGENT_ACTIVITY_DIRECT_ADAPTER"; then
    echo "Agent Activity SQLite adapter is not strictly read-only." >&2
    failed=true
  fi
fi

# Audit only an explicitly supplied build artifact. This avoids treating an unrelated stale
# .build product as the current build while still letting CI and release workflows verify the
# linked binary: LOCALHISTORY_AUDIT_BINARY=/path/to/Goalong\ History.
if [[ -n "${LOCALHISTORY_AUDIT_BINARY:-}" ]]; then
  if [[ ! -f "$LOCALHISTORY_AUDIT_BINARY" || -L "$LOCALHISTORY_AUDIT_BINARY" || ! -r "$LOCALHISTORY_AUDIT_BINARY" ]]; then
    echo "LOCALHISTORY_AUDIT_BINARY is not a readable binary: $LOCALHISTORY_AUDIT_BINARY" >&2
    failed=true
  elif [[ ! -x /usr/bin/strings ]]; then
    echo "/usr/bin/strings is required to audit LOCALHISTORY_AUDIT_BINARY." >&2
    failed=true
  else
    STRINGS_AUDIT_OUTPUT="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/goalong-history-strings.XXXXXX")"
    set +e
    /usr/bin/strings "$LOCALHISTORY_AUDIT_BINARY" \
      | /usr/bin/grep -nE "$LEGACY_AGENT_ACTIVITY_IDENTIFIERS" >"$STRINGS_AUDIT_OUTPUT"
    STRINGS_PIPELINE_STATUS=("${PIPESTATUS[@]}")
    set -e
    if [[ "${STRINGS_PIPELINE_STATUS[0]}" -ne 0 ]]; then
      echo "/usr/bin/strings failed while auditing LOCALHISTORY_AUDIT_BINARY." >&2
      failed=true
    elif [[ "${STRINGS_PIPELINE_STATUS[1]}" -eq 0 ]]; then
      /bin/cat "$STRINGS_AUDIT_OUTPUT"
      echo "Legacy Agent Activity content-vault marker found in the built binary." >&2
      failed=true
    elif [[ "${STRINGS_PIPELINE_STATUS[1]}" -ne 1 ]]; then
      echo "/usr/bin/grep failed while auditing LOCALHISTORY_AUDIT_BINARY." >&2
      failed=true
    fi
    /bin/rm -f -- "$STRINGS_AUDIT_OUTPUT"
  fi
fi

# Supply-chain rule: the single public app has no remote Swift package dependency.
REMOTE_DEPENDENCY_COUNT="$(grep -cE '\.package\s*\(' "$ROOT_DIR/Package.swift" || true)"
if [[ "$REMOTE_DEPENDENCY_COUNT" != "0" ]]; then
  echo "The single public app must not introduce a remote Swift package dependency." >&2
  failed=true
fi
if ! grep -Fq 'capabilityConsents.isEnabled(.appleScreenTime)' "$ROOT_DIR/Sources/LocalHistoryApp/AppDelegate.swift" \
  || ! grep -Fq 'configureReadOnlyQueryServer()' "$ROOT_DIR/Sources/LocalHistoryApp/AppDelegate.swift" \
  || ! grep -Fq 'the CLI never reads Apple' "$ROOT_DIR/Sources/LocalHistoryQueryCLI/LocalHistoryQueryCLI.swift" \
  || ! grep -Fq 'capability: "aiConversations"' "$ROOT_DIR/Sources/LocalHistoryQueryCLI/LocalHistoryQueryCLI.swift" \
  || ! grep -Fq 'status: "consentRequired"' "$ROOT_DIR/Sources/LocalHistoryQueryCLI/LocalHistoryQueryCLI.swift"; then
  echo "A protected-source app/CLI consent boundary is missing." >&2
  failed=true
fi

if [[ "$failed" == true ]]; then
  echo "Privacy-boundary audit failed. Review the matches above." >&2
  exit 1
fi

echo "Privacy-boundary audit passed: sensitive capture APIs remain prohibited; Apple Screen Time and Agent Activity sources remain direct-read and read-only; the CLI cannot bypass Goalong consent; Agent Activity persists only bounded metadata; Process execution is isolated to the fixed Codex app-server bridge; first-party networking, Sparkle and remote Swift dependencies are absent from the single app target."
