#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../install.sh
source "$SCRIPT_DIR/../install.sh"

BASE_URL="https://example.invalid/releases/latest-main"
AUDIT_FAIL_PATH=""

privacy_identity_replacement_allowed \
  'adHoc' 'developerID' 'cdhash H"old"' 'identifier "ai.goalong.localhistory" and anchor apple generic'
privacy_identity_replacement_allowed \
  'development' 'developerID' 'identifier "development"' 'identifier "public"'
privacy_identity_replacement_allowed \
  'developerID' 'developerID' 'identifier "stable"' 'identifier "stable"'
PRIVACY_REAUTH_REQUIRED=0
if ! privacy_identity_replacement_allowed \
    'adHoc' 'adHoc' 'cdhash H"old"' 'cdhash H"new"'; then
  echo "A valid Community update with a changed ad-hoc identity was rejected." >&2
  exit 1
fi
[[ "$PRIVACY_REAUTH_REQUIRED" -eq 1 ]]
if privacy_identity_replacement_allowed \
    'developerID' 'developerID' 'identifier "team-one"' 'identifier "team-two"'; then
  echo "A changed public signing identity was allowed to reset macOS permissions." >&2
  exit 1
fi

# Exercise replacement mechanics without running the repository-wide binary audit. The
# production path invokes the real audit before staging, after staging, and after rename.
audit_bundle_privacy() {
  [[ "$1" != "$AUDIT_FAIL_PATH" ]]
}

TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/goalong-public-installer-test.XXXXXX")"
cleanup_test_root() {
  if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" && ! -L "$TEST_ROOT" &&
        "$(/usr/bin/basename "$TEST_ROOT")" == goalong-public-installer-test.* ]]; then
    /bin/rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup_test_root EXIT

make_fixture_bundle() {
  local app_bundle="$1"
  local identifier="$2"
  local build_number="$3"
  local include_marker="${4:-true}"
  local include_single_app_policy="${5:-true}"

  /bin/mkdir -p "$app_bundle/Contents/MacOS"
  /bin/cp /bin/echo "$app_bundle/Contents/MacOS/$EXECUTABLE_NAME"
  /bin/cp /bin/echo "$app_bundle/Contents/MacOS/goalong"
  /usr/bin/plutil -create xml1 "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$identifier" "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string "$EXECUTABLE_NAME" "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleVersion -string "$build_number" "$app_bundle/Contents/Info.plist"
  if [[ "$include_marker" == true ]]; then
    /usr/bin/plutil -insert "$PRIVACY_MARKER_KEY" -bool true "$app_bundle/Contents/Info.plist"
  fi
  if [[ "$include_single_app_policy" == true ]]; then
    /usr/bin/plutil -insert GoalongBuildEdition -string unified "$app_bundle/Contents/Info.plist"
  fi
  /usr/bin/codesign --force --sign - --identifier "$identifier" "$app_bundle/Contents/MacOS/goalong" >/dev/null 2>&1
  /usr/bin/codesign --force --sign - --identifier "$identifier" "$app_bundle" >/dev/null 2>&1
}

reset_stage() {
  safe_remove_download_stage "$INSTALL_STAGE_ROOT"
  INSTALL_STAGE_ROOT=""
  STAGED_APP=""
}

TARGET_DIR="$TEST_ROOT/Applications"
/bin/mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd -P)"
TARGET_APP="$TARGET_DIR/$APP_NAME.app"
BACKUP_APP="$TARGET_DIR/.Goalong History.download-install-backup.app"

downloaded_app="$TEST_ROOT/downloaded/$APP_NAME.app"
make_fixture_bundle "$TARGET_APP" "$BUNDLE_ID" "1"
make_fixture_bundle "$downloaded_app" "$BUNDLE_ID" "2"
preflight_existing_target
validate_release_bundle "$downloaded_app" >/dev/null 2>&1
stage_release_bundle "$downloaded_app" >/dev/null 2>&1
[[ "$(cd "$(/usr/bin/dirname "$STAGED_APP")" && pwd -P)" == "$TARGET_DIR/$(/usr/bin/basename "$INSTALL_STAGE_ROOT")" ]]
[[ "$(/usr/bin/stat -f '%d' "$TARGET_DIR")" == "$(/usr/bin/stat -f '%d' "$STAGED_APP")" ]]
replace_staged_bundle "$STAGED_APP" >/dev/null 2>&1
validate_release_bundle "$TARGET_APP" >/dev/null 2>&1
finalize_replacement
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")" == "2" ]]
[[ ! -e "$BACKUP_APP" && ! -L "$BACKUP_APP" ]]
reset_stage

verified_target_directory="$TARGET_DIR"
real_target_directory="$TEST_ROOT/RealApplications"
symlinked_target_directory="$TEST_ROOT/SymlinkApplications"
/bin/mkdir -p "$real_target_directory"
/bin/ln -s "$real_target_directory" "$symlinked_target_directory"
if set_verified_target_directory "$symlinked_target_directory" >/dev/null 2>&1; then
  echo "A symlinked target application directory was accepted." >&2
  exit 1
fi
[[ "$TARGET_DIR" == "$verified_target_directory" ]]
/bin/rm -- "$symlinked_target_directory"

preserved_target="$TEST_ROOT/preserved-$APP_NAME.app"
/bin/mv "$TARGET_APP" "$preserved_target"
/bin/ln -s "$downloaded_app" "$TARGET_APP"
if preflight_existing_target >/dev/null 2>&1; then
  echo "An existing symlink at the installation target was accepted." >&2
  exit 1
fi
[[ -L "$TARGET_APP" && -d "$downloaded_app" ]]
/bin/rm -- "$TARGET_APP"
/bin/mv "$preserved_target" "$TARGET_APP"

/bin/mv "$TARGET_APP" "$preserved_target"
make_fixture_bundle "$TARGET_APP" "invalid.example.target" "2.1"
if preflight_existing_target >/dev/null 2>&1; then
  echo "An existing app with the wrong identity was accepted for replacement." >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist")" == "invalid.example.target" ]]
/bin/rm -rf -- "$TARGET_APP"
/bin/mv "$preserved_target" "$TARGET_APP"

missing_marker_app="$TEST_ROOT/missing-marker/$APP_NAME.app"
make_fixture_bundle "$missing_marker_app" "$BUNDLE_ID" "3" false true
if stage_release_bundle "$missing_marker_app" >/dev/null 2>&1; then
  echo "A bundle without the direct-source privacy marker passed staging." >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")" == "2" ]]
reset_stage

wrong_marker_type_app="$TEST_ROOT/wrong-marker-type/$APP_NAME.app"
make_fixture_bundle "$wrong_marker_type_app" "$BUNDLE_ID" "3.1"
/usr/bin/plutil -replace "$PRIVACY_MARKER_KEY" -string true "$wrong_marker_type_app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$wrong_marker_type_app" >/dev/null 2>&1
if stage_release_bundle "$wrong_marker_type_app" >/dev/null 2>&1; then
  echo "A string-valued privacy marker passed the required boolean check." >&2
  exit 1
fi
reset_stage

missing_policy_app="$TEST_ROOT/missing-policy/$APP_NAME.app"
make_fixture_bundle "$missing_policy_app" "$BUNDLE_ID" "4" true false
if stage_release_bundle "$missing_policy_app" >/dev/null 2>&1; then
  echo "A bundle without the unified single-app policy passed staging." >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")" == "2" ]]
reset_stage

wrong_identity_app="$TEST_ROOT/wrong-identity/$APP_NAME.app"
make_fixture_bundle "$wrong_identity_app" "invalid.example.bundle" "5"
if stage_release_bundle "$wrong_identity_app" >/dev/null 2>&1; then
  echo "A bundle with the wrong plist/signature identity passed staging." >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")" == "2" ]]
reset_stage

tampered_signature_app="$TEST_ROOT/tampered-signature/$APP_NAME.app"
make_fixture_bundle "$tampered_signature_app" "$BUNDLE_ID" "5.1"
/usr/bin/printf '%s\n' 'tampered after signing' >>"$tampered_signature_app/Contents/MacOS/$EXECUTABLE_NAME"
if stage_release_bundle "$tampered_signature_app" >/dev/null 2>&1; then
  echo "A bundle modified after code signing passed staging." >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")" == "2" ]]
reset_stage

rollback_app="$TEST_ROOT/rollback/$APP_NAME.app"
make_fixture_bundle "$rollback_app" "$BUNDLE_ID" "6"
stage_release_bundle "$rollback_app" >/dev/null 2>&1
AUDIT_FAIL_PATH="$TARGET_APP"
if replace_staged_bundle "$STAGED_APP" >/dev/null 2>&1; then
  echo "An installed copy that failed its post-rename privacy audit was retained." >&2
  exit 1
fi
AUDIT_FAIL_PATH=""
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")" == "2" ]]
[[ ! -e "$BACKUP_APP" && ! -L "$BACKUP_APP" ]]
reset_stage

/bin/mv "$TARGET_APP" "$BACKUP_APP"
recover_interrupted_replacement >/dev/null 2>&1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")" == "2" ]]
[[ ! -e "$BACKUP_APP" && ! -L "$BACKUP_APP" ]]

obsolete_local_app="$TEST_ROOT/$OBSOLETE_LOCAL_APP_NAME.app"
make_fixture_bundle "$obsolete_local_app" "$OBSOLETE_LOCAL_BUNDLE_ID" "1"
remove_verified_obsolete_local_bundle "$obsolete_local_app"
[[ ! -e "$obsolete_local_app" && ! -L "$obsolete_local_app" ]]

echo "Public installer safety tests passed: Community reauthorization disclosure, exact identity, symlink/tamper refusal, target-filesystem staging, privacy/single-app fail-closed checks, rollback, interrupted-install recovery, and obsolete Local-edition cleanup."
