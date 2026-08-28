#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install_from_source.sh
source "$SCRIPT_DIR/install_from_source.sh"

# Replacement mechanics are tested independently from the repository-wide audit. The real
# source installer runs that audit before building and again for every bundle copy.
audit_bundle_privacy() {
  return 0
}

TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/localhistory-source-install.XXXXXX")"
cleanup_test_root() {
  safe_remove_temporary_directory "$TEST_ROOT" || true
}
trap cleanup_test_root EXIT

make_fixture_bundle() {
  local app_bundle="$1"
  local identifier="$2"
  local build_number="$3"

  /bin/mkdir -p "$app_bundle/Contents/MacOS"
  /bin/cp /bin/echo "$app_bundle/Contents/MacOS/$EXECUTABLE_NAME"
  /bin/cp /bin/echo "$app_bundle/Contents/MacOS/goalong"
  /usr/bin/plutil -create xml1 "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$identifier" "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string "$EXECUTABLE_NAME" "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleVersion -string "$build_number" "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert LocalHistoryAgentActivityDirectSourceV2 -bool true "$app_bundle/Contents/Info.plist"
  /usr/bin/codesign --force --sign - --identifier "$identifier" "$app_bundle/Contents/MacOS/goalong" >/dev/null 2>&1
  /usr/bin/codesign --force --sign - --identifier "$identifier" "$app_bundle" >/dev/null 2>&1
}

USER_SELECTION_ROOT="$TEST_ROOT/select-user"
/bin/mkdir -p "$USER_SELECTION_ROOT/system" "$USER_SELECTION_ROOT/user"
make_fixture_bundle "$USER_SELECTION_ROOT/user/$APP_NAME.app" "$BUNDLE_ID" "user-existing"
select_install_target "$USER_SELECTION_ROOT/system" "$USER_SELECTION_ROOT/user"
[[ "$TARGET_DIR" == "$(cd "$USER_SELECTION_ROOT/user" && pwd -P)" ]]
[[ "$TARGET_APP" == "$TARGET_DIR/$APP_NAME.app" ]]

SYSTEM_SELECTION_ROOT="$TEST_ROOT/select-system"
/bin/mkdir -p "$SYSTEM_SELECTION_ROOT/system" "$SYSTEM_SELECTION_ROOT/user"
make_fixture_bundle "$SYSTEM_SELECTION_ROOT/system/$APP_NAME.app" "$BUNDLE_ID" "system-existing"
select_install_target "$SYSTEM_SELECTION_ROOT/system" "$SYSTEM_SELECTION_ROOT/user"
[[ "$TARGET_DIR" == "$(cd "$SYSTEM_SELECTION_ROOT/system" && pwd -P)" ]]
[[ "$TARGET_APP" == "$TARGET_DIR/$APP_NAME.app" ]]

DOUBLE_SELECTION_ROOT="$TEST_ROOT/select-double"
/bin/mkdir -p "$DOUBLE_SELECTION_ROOT/system" "$DOUBLE_SELECTION_ROOT/user"
make_fixture_bundle "$DOUBLE_SELECTION_ROOT/system/$APP_NAME.app" "$BUNDLE_ID" "system-copy"
make_fixture_bundle "$DOUBLE_SELECTION_ROOT/user/$APP_NAME.app" "$BUNDLE_ID" "user-copy"
set +e
double_selection_output="$(
  select_install_target "$DOUBLE_SELECTION_ROOT/system" "$DOUBLE_SELECTION_ROOT/user" 2>&1
)"
double_selection_status=$?
set -e
if [[ "$double_selection_status" -eq 0 ]] ||
   ! /usr/bin/grep -Fq 'Multiple Goalong History installations were found' <<<"$double_selection_output"; then
  echo "Source target selection did not fail closed for two installed copies." >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DOUBLE_SELECTION_ROOT/system/$APP_NAME.app/Contents/Info.plist")" == "system-copy" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DOUBLE_SELECTION_ROOT/user/$APP_NAME.app/Contents/Info.plist")" == "user-copy" ]]

SYMLINK_SELECTION_ROOT="$TEST_ROOT/select-symlink"
/bin/mkdir -p "$SYMLINK_SELECTION_ROOT/system" "$SYMLINK_SELECTION_ROOT/user" "$SYMLINK_SELECTION_ROOT/fixtures"
make_fixture_bundle "$SYMLINK_SELECTION_ROOT/fixtures/$APP_NAME.app" "$BUNDLE_ID" "symlink-target"
/bin/ln -s "$SYMLINK_SELECTION_ROOT/fixtures/$APP_NAME.app" "$SYMLINK_SELECTION_ROOT/user/$APP_NAME.app"
set +e
symlink_selection_output="$(
  select_install_target "$SYMLINK_SELECTION_ROOT/system" "$SYMLINK_SELECTION_ROOT/user" 2>&1
)"
symlink_selection_status=$?
set -e
if [[ "$symlink_selection_status" -eq 0 ]] ||
   ! /usr/bin/grep -Fq 'Refusing symlinked installed app' <<<"$symlink_selection_output"; then
  echo "Source target selection did not reject a symlinked installed app." >&2
  exit 1
fi

TARGET_DIR="$TEST_ROOT/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME.app"
BACKUP_APP="$TARGET_DIR/.Goalong History.source-install-backup.app"
INSTALL_STAGE_ROOT="$TARGET_DIR/.goalong-history-source-stage.success"
/bin/mkdir -p "$TARGET_DIR" "$INSTALL_STAGE_ROOT"
make_fixture_bundle "$TARGET_APP" "$BUNDLE_ID" "1"
make_fixture_bundle "$INSTALL_STAGE_ROOT/$APP_NAME.app" "$BUNDLE_ID" "2"

validate_app_bundle "$TARGET_APP" >/dev/null 2>&1
replace_staged_bundle "$INSTALL_STAGE_ROOT/$APP_NAME.app" >/dev/null 2>&1
validate_app_bundle "$TARGET_APP" >/dev/null 2>&1
finalize_replacement
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")" == "2" ]]
[[ ! -e "$BACKUP_APP" && ! -L "$BACKUP_APP" ]]

INSTALL_STAGE_ROOT="$TARGET_DIR/.goalong-history-source-stage.rollback"
/bin/mkdir -p "$INSTALL_STAGE_ROOT"
make_fixture_bundle "$INSTALL_STAGE_ROOT/$APP_NAME.app" "invalid.example.bundle" "3"
if replace_staged_bundle "$INSTALL_STAGE_ROOT/$APP_NAME.app" >/dev/null 2>&1; then
  echo "A staged bundle with the wrong identifier was installed." >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")" == "2" ]]
[[ ! -e "$BACKUP_APP" && ! -L "$BACKUP_APP" ]]

LOG_DIR="$TEST_ROOT/logs"
LOG_FILE="$LOG_DIR/installer.log"
LOG_MAX_BYTES=1024
LOG_BACKUP_COUNT=2
prepare_installer_log
/bin/dd if=/dev/zero of="$LOG_FILE" bs=3072 count=1 >/dev/null 2>&1
trim_log_to_limit "$LOG_FILE"
[[ "$(/usr/bin/stat -f '%z' "$LOG_FILE")" -eq "$LOG_MAX_BYTES" ]]
prepare_installer_log
/bin/dd if=/dev/zero of="$LOG_FILE" bs=2048 count=1 >/dev/null 2>&1
trim_log_to_limit "$LOG_FILE"
prepare_installer_log
[[ -f "$LOG_FILE.1" && -f "$LOG_FILE.2" ]]
[[ "$(/usr/bin/stat -f '%z' "$LOG_FILE.1")" -le "$LOG_MAX_BYTES" ]]
[[ "$(/usr/bin/stat -f '%z' "$LOG_FILE.2")" -le "$LOG_MAX_BYTES" ]]

VERBOSE=1
run_step_state="before"
mutate_run_step_state() {
  run_step_state="after"
  echo "verbose state preservation fixture"
}
run_step "Checking verbose state preservation" mutate_run_step_state \
  >"$TEST_ROOT/run-step-output.log"
[[ "$run_step_state" == "after" ]]
/usr/bin/grep -Fq 'verbose state preservation fixture' "$TEST_ROOT/run-step-output.log"
/usr/bin/grep -Fq 'verbose state preservation fixture' "$LOG_FILE"
VERBOSE=0

set +e
test_override_output="$(LOCALHISTORY_RUN_TESTS=0 "$SCRIPT_DIR/install_from_source.sh" 2>&1)"
test_override_status=$?
set -e
if [[ "$test_override_status" -ne 64 ]] || ! /usr/bin/grep -Fq 'Source installation requires the full test suite' <<<"$test_override_output"; then
  echo "Source installation did not reject LOCALHISTORY_RUN_TESTS=0." >&2
  exit 1
fi

MARKER_FILE="$TEST_ROOT/legacy-marker"
/usr/bin/printf '%s\n' 'captureFullContents' >"$MARKER_FILE"
set +e
marker_audit_output="$(LOCALHISTORY_AUDIT_BINARY="$MARKER_FILE" "$SCRIPT_DIR/audit_privacy_boundaries.sh" 2>&1)"
marker_audit_status=$?
set -e
if [[ "$marker_audit_status" -eq 0 ]] || ! /usr/bin/grep -Fq 'Legacy Agent Activity content-vault marker found' <<<"$marker_audit_output"; then
  echo "Binary privacy audit did not reject a legacy marker." >&2
  exit 1
fi

echo "Source installer safety tests passed: forced tests, unique target selection, symlink refusal, exact identity, staged validation, rollback, verbose state preservation, binary audit and bounded logs."
