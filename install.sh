#!/bin/bash
set -euo pipefail

APP_NAME="Goalong History"
EXECUTABLE_NAME="Goalong History"
PREVIOUS_APP_NAME="GoLong History"
LEGACY_APP_NAME="LocalHistory"
OBSOLETE_LOCAL_APP_NAME="Goalong History Local"
OBSOLETE_LOCAL_BUNDLE_ID="ai.goalong.localhistory.local"
DISPLAY_NAME="Goalong History"
BUNDLE_ID="ai.goalong.localhistory"
PRIVACY_MARKER_KEY="LocalHistoryAgentActivityDirectSourceV2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_LINK_INSTALLER="$ROOT_DIR/scripts/install_cli_link.sh"
# shellcheck source=scripts/install_cli_link.sh
source "$CLI_LINK_INSTALLER"
REPOSITORY="blancmathis/goalong-history"
RELEASE_TAG="${GOALONG_RELEASE_TAG:-latest-main}"
RELEASE_ASSET="Goalong-History-macOS-universal.zip"
SOURCE_ONLY=false
VERBOSE=false
WORK_DIR=""
INSTALL_STAGE_ROOT=""
STAGED_APP=""
TARGET_DIR=""
TARGET_APP=""
BACKUP_APP=""
REPLACEMENT_ACTIVE=0
ORIGINAL_TARGET_PRESENT=0
PRIVACY_REAUTH_REQUIRED=0

bundle_identifier_from_plist() {
  /usr/bin/plutil -extract CFBundleIdentifier raw -expect string -o - "$1/Contents/Info.plist" 2>/dev/null
}

bundle_identifier_from_signature() {
  local details
  if ! details="$(/usr/bin/codesign -dv --verbose=4 "$1" 2>&1)"; then
    return 1
  fi
  /usr/bin/awk -F= '/^Identifier=/{print $2; exit}' <<<"$details"
}

bundle_signature_kind() {
  local details
  details="$(/usr/bin/codesign -dv --verbose=4 "$1" 2>&1)" || return 1
  if /usr/bin/grep -Fxq 'Signature=adhoc' <<<"$details"; then
    printf '%s\n' 'adHoc'
  elif /usr/bin/grep -q '^Authority=Apple Development:' <<<"$details"; then
    printf '%s\n' 'development'
  elif /usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$details"; then
    printf '%s\n' 'developerID'
  elif /usr/bin/grep -q '^Authority=' <<<"$details"; then
    printf '%s\n' 'certificateBacked'
  else
    return 1
  fi
}

bundle_designated_requirement() {
  local requirement
  requirement="$(/usr/bin/codesign -d -r- "$1" 2>&1)" || return 1
  /usr/bin/sed -n 's/^designated => //p' <<<"$requirement"
}

privacy_identity_replacement_allowed() {
  local installed_kind="$1"
  local source_kind="$2"
  local installed_requirement="$3"
  local source_requirement="$4"

  if [[ "$source_kind" == 'adHoc' ]]; then
    PRIVACY_REAUTH_REQUIRED=1
    return 0
  fi
  [[ -n "$installed_requirement" \
     && "$installed_requirement" == "$source_requirement" ]]
}

verify_replacement_preserves_privacy_identity() {
  local installed_app="$1"
  local source_app="$2"
  local installed_kind
  local source_kind
  local installed_requirement
  local source_requirement

  [[ ! -e "$installed_app" && ! -L "$installed_app" ]] && return 0
  installed_kind="$(bundle_signature_kind "$installed_app")" || return 1
  source_kind="$(bundle_signature_kind "$source_app")" || return 1
  installed_requirement="$(bundle_designated_requirement "$installed_app")" || return 1
  source_requirement="$(bundle_designated_requirement "$source_app")" || return 1

  if privacy_identity_replacement_allowed \
      "$installed_kind" "$source_kind" "$installed_requirement" "$source_requirement"; then
    if [[ "$PRIVACY_REAUTH_REQUIRED" -eq 1 ]]; then
      warn "This free Community update has a new ad-hoc identity; macOS may ask for Goalong permissions again."
    fi
    return 0
  fi
  return 1
}

bundle_has_expected_identity() {
  local app_path="$1"
  local plist_identifier
  local signature_identifier

  [[ -d "$app_path" && ! -L "$app_path" ]] || return 1
  plist_identifier="$(bundle_identifier_from_plist "$app_path")" || return 1
  signature_identifier="$(bundle_identifier_from_signature "$app_path")" || return 1
  [[ "$plist_identifier" == "$BUNDLE_ID" && "$signature_identifier" == "$BUNDLE_ID" ]]
}

bundle_has_direct_source_privacy_marker() {
  [[ "$(/usr/bin/plutil -extract "$PRIVACY_MARKER_KEY" raw -expect bool -o - "$1/Contents/Info.plist" 2>/dev/null)" == "true" ]]
}

verify_bundle_signature() {
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$1"
}

bundle_has_goalong_cli() {
  local cli="$1/Contents/MacOS/goalong"
  [[ -f "$cli" && ! -L "$cli" && -x "$cli" ]] || return 1
  /usr/bin/codesign --verify --strict --verbose=2 "$cli" >/dev/null 2>&1 || return 1
  [[ "$(bundle_identifier_from_signature "$cli")" == "$BUNDLE_ID" ]]
}

audit_bundle_privacy() {
  local app_path="$1"
  local audit_script="$ROOT_DIR/scripts/audit_privacy_boundaries.sh"
  local executable="$app_path/Contents/MacOS/$EXECUTABLE_NAME"

  if [[ ! -f "$audit_script" || -L "$audit_script" || ! -x "$audit_script" ]]; then
    echo "The required privacy audit is unavailable or unsafe: $audit_script" >&2
    return 1
  fi
  if [[ ! -f "$executable" || -L "$executable" || ! -r "$executable" || ! -x "$executable" ]]; then
    echo "Expected a readable regular executable at $executable" >&2
    return 1
  fi
  env LOCALHISTORY_AUDIT_BINARY="$executable" "$audit_script" >/dev/null
}

bundle_has_single_app_security_policy() {
  local app_path="$1"
  local info_plist="$app_path/Contents/Info.plist"

  [[ -f "$info_plist" && ! -L "$info_plist" ]] || return 1
  [[ "$(/usr/bin/plutil -extract GoalongBuildEdition raw -expect string -o - "$info_plist" 2>/dev/null)" == "unified" ]] \
    || return 1
  for forbidden_key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do
    if /usr/bin/plutil -extract "$forbidden_key" raw -o - "$info_plist" >/dev/null 2>&1; then
      return 1
    fi
  done
  [[ ! -e "$app_path/Contents/Frameworks/Sparkle.framework" ]]
}

validate_release_bundle() {
  local app_path="$1"

  if ! bundle_has_expected_identity "$app_path"; then
    echo "Refusing bundle with an identifier other than $BUNDLE_ID: $app_path" >&2
    return 1
  fi
  if ! bundle_has_direct_source_privacy_marker "$app_path"; then
    echo "Refusing a bundle without the direct-source Agent Activity privacy marker: $app_path" >&2
    return 1
  fi
  if ! bundle_has_goalong_cli "$app_path"; then
    echo "Refusing a release without the signed goalong CLI." >&2
    return 1
  fi
  if ! verify_bundle_signature "$app_path"; then
    echo "Refusing a bundle with an invalid code signature: $app_path" >&2
    return 1
  fi
  if ! audit_bundle_privacy "$app_path"; then
    echo "Refusing a bundle that failed the direct-source privacy audit: $app_path" >&2
    return 1
  fi
  if ! bundle_has_single_app_security_policy "$app_path"; then
    echo "Refusing a bundle that is not the unified updater-free Goalong app: $app_path" >&2
    return 1
  fi
}

safe_remove_download_stage() {
  local path="$1"
  local parent

  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  [[ -n "$TARGET_DIR" && -d "$path" && ! -L "$path" ]] || return 1
  parent="$(cd "$(/usr/bin/dirname "$path")" && pwd -P)" || return 1
  if [[ "$parent" != "$TARGET_DIR" || "$(/usr/bin/basename "$path")" != .goalong-history-download-stage.* ]]; then
    echo "Refusing to remove unexpected download staging directory: $path" >&2
    return 1
  fi
  /bin/rm -rf -- "$path"
}

safe_remove_work_directory() {
  local path="$1"

  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  if [[ -z "$path" || ! -d "$path" || -L "$path" || "$(/usr/bin/basename "$path")" != localhistory-install.* ]]; then
    echo "Refusing to remove unexpected installer work directory: $path" >&2
    return 1
  fi
  /bin/rm -rf -- "$path"
}

safe_remove_backup_bundle() {
  local path="$1"
  local expected="$TARGET_DIR/.Goalong History.download-install-backup.app"

  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  if [[ "$path" != "$expected" || ! -d "$path" || -L "$path" ]]; then
    echo "Refusing to remove unexpected rollback bundle: $path" >&2
    return 1
  fi
  if ! bundle_has_expected_identity "$path" || ! verify_bundle_signature "$path" >/dev/null 2>&1; then
    echo "Refusing to remove an unverified rollback bundle: $path" >&2
    return 1
  fi
  /bin/rm -rf -- "$path"
}

rollback_replacement() {
  local failed_app

  [[ "$REPLACEMENT_ACTIVE" -eq 1 ]] || return 0
  failed_app="$INSTALL_STAGE_ROOT/failed-$APP_NAME.app"
  if [[ -e "$TARGET_APP" || -L "$TARGET_APP" ]]; then
    if [[ ! -d "$INSTALL_STAGE_ROOT" || -L "$INSTALL_STAGE_ROOT" || -e "$failed_app" || -L "$failed_app" ]]; then
      echo "Cannot move the failed replacement into the verified staging directory." >&2
      return 1
    fi
    /bin/mv "$TARGET_APP" "$failed_app" || return 1
  fi
  if [[ "$ORIGINAL_TARGET_PRESENT" -eq 1 && -d "$BACKUP_APP" && ! -L "$BACKUP_APP" && ! -e "$TARGET_APP" && ! -L "$TARGET_APP" ]]; then
    /bin/mv "$BACKUP_APP" "$TARGET_APP" || return 1
  fi
  REPLACEMENT_ACTIVE=0
}

cleanup_install() {
  local status=$?

  trap - EXIT
  rollback_replacement || true
  safe_remove_download_stage "$INSTALL_STAGE_ROOT" || true
  safe_remove_work_directory "$WORK_DIR" || true
  exit "$status"
}

recover_interrupted_replacement() {
  [[ ! -e "$BACKUP_APP" && ! -L "$BACKUP_APP" ]] && return 0
  if [[ ! -d "$BACKUP_APP" || -L "$BACKUP_APP" ]] ||
     ! bundle_has_expected_identity "$BACKUP_APP" ||
     ! verify_bundle_signature "$BACKUP_APP" >/dev/null 2>&1; then
    echo "An unexpected rollback artifact requires manual inspection: $BACKUP_APP" >&2
    return 1
  fi

  if [[ ! -e "$TARGET_APP" && ! -L "$TARGET_APP" ]]; then
    /bin/mv "$BACKUP_APP" "$TARGET_APP"
    verify_bundle_signature "$TARGET_APP"
    echo "Restored the previous app after an interrupted installation."
    return 0
  fi

  if ! validate_release_bundle "$TARGET_APP"; then
    echo "Both an installed app and a rollback app exist; refusing to choose between them." >&2
    return 1
  fi
  safe_remove_backup_bundle "$BACKUP_APP"
}

preflight_existing_target() {
  [[ ! -e "$TARGET_APP" && ! -L "$TARGET_APP" ]] && return 0
  if [[ ! -d "$TARGET_APP" || -L "$TARGET_APP" ]] ||
     ! bundle_has_expected_identity "$TARGET_APP" ||
     ! verify_bundle_signature "$TARGET_APP" >/dev/null 2>&1; then
    echo "Refusing to replace an unexpected or invalid item at $TARGET_APP" >&2
    return 1
  fi
}

set_verified_target_directory() {
  local requested_directory="$1"
  local canonical_directory

  if [[ -z "$requested_directory" || ! -d "$requested_directory" || -L "$requested_directory" || ! -w "$requested_directory" ]]; then
    echo "Refusing an unavailable, symlinked, or non-writable application directory: $requested_directory" >&2
    return 1
  fi
  canonical_directory="$(cd "$requested_directory" && pwd -P)" || return 1
  if [[ -z "$canonical_directory" || "$canonical_directory" == "/" ]]; then
    echo "Refusing unsafe application directory: $canonical_directory" >&2
    return 1
  fi
  TARGET_DIR="$canonical_directory"
}

stage_release_bundle() {
  local source_app="$1"

  INSTALL_STAGE_ROOT="$(/usr/bin/mktemp -d "$TARGET_DIR/.goalong-history-download-stage.XXXXXX")"
  /bin/chmod 700 "$INSTALL_STAGE_ROOT"
  STAGED_APP="$INSTALL_STAGE_ROOT/$APP_NAME.app"
  /usr/bin/ditto "$source_app" "$STAGED_APP"
  validate_release_bundle "$STAGED_APP"
}

replace_staged_bundle() {
  local staged_app="$1"

  if [[ ! -d "$staged_app" || -L "$staged_app" || "$(cd "$(/usr/bin/dirname "$staged_app")" && pwd -P)" != "$INSTALL_STAGE_ROOT" ]]; then
    echo "Refusing an unexpected staged application path: $staged_app" >&2
    return 1
  fi
  if [[ -e "$BACKUP_APP" || -L "$BACKUP_APP" ]]; then
    echo "Refusing to overwrite an existing rollback bundle: $BACKUP_APP" >&2
    return 1
  fi

  ORIGINAL_TARGET_PRESENT=0
  REPLACEMENT_ACTIVE=1
  if [[ -e "$TARGET_APP" || -L "$TARGET_APP" ]]; then
    ORIGINAL_TARGET_PRESENT=1
    if ! /bin/mv "$TARGET_APP" "$BACKUP_APP"; then
      REPLACEMENT_ACTIVE=0
      return 1
    fi
  fi
  if ! /bin/mv "$staged_app" "$TARGET_APP"; then
    rollback_replacement
    return 1
  fi
  if ! validate_release_bundle "$TARGET_APP"; then
    rollback_replacement
    return 1
  fi
}

finalize_replacement() {
  if [[ "$ORIGINAL_TARGET_PRESENT" -eq 1 ]]; then
    safe_remove_backup_bundle "$BACKUP_APP" || return 1
  fi
  REPLACEMENT_ACTIVE=0
}

remove_verified_legacy_bundle() {
  local legacy_app="$1"

  [[ ! -e "$legacy_app" && ! -L "$legacy_app" ]] && return 0
  if [[ ! -d "$legacy_app" || -L "$legacy_app" ]] ||
     ! bundle_has_expected_identity "$legacy_app" ||
     ! verify_bundle_signature "$legacy_app" >/dev/null 2>&1; then
    return 0
  fi
  /bin/rm -rf -- "$legacy_app"
}

remove_verified_obsolete_local_bundle() {
  local app_path="$1"

  [[ ! -e "$app_path" && ! -L "$app_path" ]] && return 0
  [[ -d "$app_path" && ! -L "$app_path" ]] || return 0
  [[ "$(bundle_identifier_from_plist "$app_path" 2>/dev/null || true)" == "$OBSOLETE_LOCAL_BUNDLE_ID" ]] \
    || return 0
  [[ "$(bundle_identifier_from_signature "$app_path" 2>/dev/null || true)" == "$OBSOLETE_LOCAL_BUNDLE_ID" ]] \
    || return 0
  verify_bundle_signature "$app_path" >/dev/null 2>&1 || return 0
  /bin/rm -rf -- "$app_path"
}

main() {

for argument in "$@"; do
  case "$argument" in
    --source) SOURCE_ONLY=true ;;
    --verbose) VERBOSE=true ;;
    -h|--help)
      cat <<HELP
Usage: ./install.sh [--source] [--verbose]

The normal path downloads the latest free Goalong History Community Build from GitHub.
Use --source for an audited local developer build. All updates are manual replacements.
HELP
      exit 0
      ;;
    *)
      echo "Unknown option: $argument" >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "$DISPLAY_NAME can only be installed on macOS." >&2
  exit 1
fi

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$MACOS_MAJOR" -lt 13 ]]; then
  echo "$DISPLAY_NAME requires macOS 13 Ventura or later." >&2
  exit 1
fi

if [[ -t 1 ]]; then
  RESET='\033[0m'
  BOLD='\033[1m'
  DIM='\033[2m'
  BLUE='\033[38;5;75m'
  GREEN='\033[38;5;78m'
  YELLOW='\033[38;5;214m'
  RED='\033[38;5;203m'
else
  RESET='' BOLD='' DIM='' BLUE='' GREEN='' YELLOW='' RED=''
fi

headline() {
  printf '\n%b%s%b\n' "$BOLD$BLUE" "$1" "$RESET"
}
status() {
  printf '  %b✓%b %s\n' "$GREEN" "$RESET" "$1"
}
note() {
  printf '  %b%s%b\n' "$DIM" "$1" "$RESET"
}
warn() {
  printf '  %b!%b %s\n' "$YELLOW" "$RESET" "$1"
}
fail() {
  printf '  %b×%b %s\n' "$RED" "$RESET" "$1" >&2
}

clear 2>/dev/null || true
printf '%b' "$BLUE"
cat <<'BANNER'

       ╭──────────────────────────────╮
       │      ◷  Goalong History      │
       │   private • local • trusted  │
       ╰──────────────────────────────╯
BANNER
printf '%b' "$RESET"

note "A clean, private setup for this Mac. No sudo required."

install_source() {
  headline "Developer installation"
  warn "This creates a local development build without production update credentials."
  if [[ ! -x "$ROOT_DIR/scripts/install_from_source.sh" ]]; then
    fail "This folder does not contain the source installer."
    return 1
  fi
  if [[ "$VERBOSE" == true ]]; then
    LOCALHISTORY_INSTALL_VERBOSE=1 "$ROOT_DIR/scripts/install_from_source.sh"
  else
    "$ROOT_DIR/scripts/install_from_source.sh"
  fi
}

if [[ "$SOURCE_ONLY" == true ]]; then
  install_source
  exit $?
fi

headline "Preparing $DISPLAY_NAME"
status "macOS $(sw_vers -productVersion) detected"
status "$(uname -m) Mac detected"

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/localhistory-install.XXXXXX")"
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
ZIP_PATH="$WORK_DIR/$RELEASE_ASSET"
CHECKSUM_PATH="$WORK_DIR/$RELEASE_ASSET.sha256"
BASE_URL="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG"
DOWNLOAD_LOG="$WORK_DIR/download.log"

printf '  • Downloading the latest Goalong Community Build… '
set +e
/usr/bin/curl --fail --location --silent --show-error --retry 2 --connect-timeout 12 \
  "$BASE_URL/$RELEASE_ASSET" -o "$ZIP_PATH" >"$DOWNLOAD_LOG" 2>&1
DOWNLOAD_STATUS=$?
set -e
if [[ $DOWNLOAD_STATUS -ne 0 ]]; then
  echo "unavailable"
  fail "No rolling release is currently available from GitHub."
  note "The installer will not silently compile or install a different artifact."
  note "Developers can explicitly run ./install.sh --source."
  if [[ "$VERBOSE" == true ]]; then
    cat "$DOWNLOAD_LOG" >&2
  fi
  exit 1
fi
echo "done"

printf '  • Checking the download… '
set +e
/usr/bin/curl --fail --location --silent --show-error --retry 2 --connect-timeout 12 \
  "$BASE_URL/$RELEASE_ASSET.sha256" -o "$CHECKSUM_PATH" >>"$DOWNLOAD_LOG" 2>&1
CHECKSUM_DOWNLOAD_STATUS=$?
set -e
if [[ $CHECKSUM_DOWNLOAD_STATUS -ne 0 ]]; then
  echo "failed"
  fail "The release checksum could not be downloaded."
  exit 1
fi

EXPECTED_HASH="$(awk '{print $1}' "$CHECKSUM_PATH" | head -n 1)"
ACTUAL_HASH="$(/usr/bin/shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
if [[ -z "$EXPECTED_HASH" || "$EXPECTED_HASH" != "$ACTUAL_HASH" ]]; then
  echo "failed"
  fail "The downloaded archive did not match its published checksum."
  exit 1
fi
echo "verified"

printf '  • Verifying the release bundle… '
/usr/bin/ditto -x -k "$ZIP_PATH" "$WORK_DIR/unpacked"
SOURCE_APP="$WORK_DIR/unpacked/$APP_NAME.app"
if [[ ! -d "$SOURCE_APP" || -L "$SOURCE_APP" ]]; then
  echo "failed"
  fail "The release archive does not contain a regular $APP_NAME.app bundle."
  exit 1
fi

if ! validate_release_bundle "$SOURCE_APP"; then
  echo "failed"
  fail "The downloaded bundle failed identity, signature, single-app, or privacy validation."
  note "Use ./install.sh --source until a privacy-compatible release is published."
  exit 1
fi

SOURCE_SIGNATURE_KIND="$(bundle_signature_kind "$SOURCE_APP" 2>/dev/null || true)"
if [[ "$SOURCE_SIGNATURE_KIND" != 'adHoc' ]]; then
  echo "failed"
  fail "The public artifact is not the expected free ad-hoc Community Build."
  exit 1
fi
if /usr/sbin/spctl --assess --type execute --verbose=2 "$SOURCE_APP" >/dev/null 2>&1; then
  echo "failed"
  fail "The Community Build unexpectedly passed Apple notarization assessment."
  note "Refusing a release whose published trust mode does not match its bundle."
  exit 1
fi
echo "verified by Goalong's signature, identity, privacy, and single-app gates"

SYSTEM_INSTALL_PRESENT=false
USER_INSTALL_PRESENT=false
for related_app in "$APP_NAME" "$PREVIOUS_APP_NAME" "$LEGACY_APP_NAME" "$OBSOLETE_LOCAL_APP_NAME"; do
  if [[ -e "/Applications/$related_app.app" || -L "/Applications/$related_app.app" ]]; then
    SYSTEM_INSTALL_PRESENT=true
  fi
  if [[ -e "$HOME/Applications/$related_app.app" || -L "$HOME/Applications/$related_app.app" ]]; then
    USER_INSTALL_PRESENT=true
  fi
done

if [[ "$SYSTEM_INSTALL_PRESENT" == true ]]; then
  if [[ ! -d /Applications || ! -w /Applications ]]; then
    echo "failed"
    fail "The existing system-wide app cannot be replaced atomically without write access to /Applications."
    exit 1
  fi
  TARGET_DIR="/Applications"
elif [[ "$USER_INSTALL_PRESENT" == true ]]; then
  TARGET_DIR="$HOME/Applications"
  /bin/mkdir -p "$TARGET_DIR"
elif [[ -d /Applications && -w /Applications ]]; then
  TARGET_DIR="/Applications"
else
  TARGET_DIR="$HOME/Applications"
  /bin/mkdir -p "$TARGET_DIR"
fi
if ! set_verified_target_directory "$TARGET_DIR"; then
  echo "failed"
  fail "No safe writable application directory is available."
  exit 1
fi
TARGET_APP="$TARGET_DIR/$APP_NAME.app"
BACKUP_APP="$TARGET_DIR/.Goalong History.download-install-backup.app"
recover_interrupted_replacement
preflight_existing_target
stage_release_bundle "$SOURCE_APP"
status "Verified a target-filesystem staging copy"
if ! verify_replacement_preserves_privacy_identity "$TARGET_APP" "$STAGED_APP"; then
  echo "failed"
  fail "The update would change Goalong History's macOS privacy identity."
  note "Use a release signed for the same Team ID; changing identity resets Accessibility and Full Disk Access."
  exit 1
fi
if [[ "$PRIVACY_REAUTH_REQUIRED" -eq 1 ]]; then
  warn "This replacement can require fresh macOS permission approvals; Goalong data is preserved."
else
  status "macOS privacy identity is unchanged"
fi

headline "Installing"
/usr/bin/launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist" >/dev/null 2>&1 || true
/bin/rm -f -- "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
/usr/bin/pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
/usr/bin/pkill -x "$PREVIOUS_APP_NAME" >/dev/null 2>&1 || true
/usr/bin/pkill -x "$LEGACY_APP_NAME" >/dev/null 2>&1 || true
/usr/bin/pkill -x "$OBSOLETE_LOCAL_APP_NAME" >/dev/null 2>&1 || true
/bin/sleep 0.4
replace_staged_bundle "$STAGED_APP"
validate_release_bundle "$TARGET_APP"
install_goalong_cli_link "$TARGET_APP"
finalize_replacement
for legacy_app in \
  "/Applications/$PREVIOUS_APP_NAME.app" \
  "$HOME/Applications/$PREVIOUS_APP_NAME.app" \
  "/Applications/$LEGACY_APP_NAME.app" \
  "$HOME/Applications/$LEGACY_APP_NAME.app"; do
  remove_verified_legacy_bundle "$legacy_app"
done
for obsolete_local_app in \
  "/Applications/$OBSOLETE_LOCAL_APP_NAME.app" \
  "$HOME/Applications/$OBSOLETE_LOCAL_APP_NAME.app"; do
  remove_verified_obsolete_local_bundle "$obsolete_local_app"
done
status "Installed in $TARGET_DIR"
status "Legacy background service cleaned up"
status "Your existing history, settings, and bundle ID were preserved"
status "Single updater-free app policy verified"
warn "This free build is not Apple-notarized; macOS may require Privacy & Security → Open Anyway"
warn "Never disable Gatekeeper globally"

headline "Ready"
note "Opening the guided setup now…"
/usr/bin/open "$TARGET_APP"

printf '\n%bInstallation complete.%b The rest happens inside %s.\n\n' "$BOLD$GREEN" "$RESET" "$DISPLAY_NAME"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
