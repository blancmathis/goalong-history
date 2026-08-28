#!/bin/bash
set -euo pipefail

APP_NAME="Goalong History"
EXECUTABLE_NAME="Goalong History"
PREVIOUS_APP_NAME="GoLong History"
LEGACY_APP_NAME="LocalHistory"
BUNDLE_ID="ai.goalong.localhistory"
PRIVACY_MARKER_KEY="LocalHistoryAgentActivityDirectSourceV2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_LINK_INSTALLER="$ROOT_DIR/scripts/install_cli_link.sh"
# shellcheck source=install_cli_link.sh
source "$CLI_LINK_INSTALLER"
LOG_DIR="$HOME/Library/Logs/LocalHistory"
LOG_FILE="$LOG_DIR/installer.log"
LOG_MAX_BYTES=$((2 * 1024 * 1024))
LOG_BACKUP_COUNT=2
VERBOSE="${LOCALHISTORY_INSTALL_VERBOSE:-0}"

BUILD_OUTPUT=""
INSTALL_STAGE_ROOT=""
TARGET_DIR=""
TARGET_APP=""
BACKUP_APP=""
REPLACEMENT_ACTIVE=0
ORIGINAL_TARGET_PRESENT=0

bundle_identifier_from_plist() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

bundle_identifier_from_signature() {
  local details
  if ! details="$(/usr/bin/codesign -dv --verbose=4 "$1" 2>&1)"; then
    return 1
  fi
  /usr/bin/awk -F= '/^Identifier=/{print $2; exit}' <<<"$details"
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
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$PRIVACY_MARKER_KEY" "$1/Contents/Info.plist" 2>/dev/null)" == "true" ]]
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
  local executable="$app_path/Contents/MacOS/$EXECUTABLE_NAME"

  if [[ ! -f "$executable" || -L "$executable" || ! -r "$executable" || ! -x "$executable" ]]; then
    echo "Expected a readable regular executable at $executable" >&2
    return 1
  fi
  env LOCALHISTORY_AUDIT_BINARY="$executable" "$ROOT_DIR/scripts/audit_privacy_boundaries.sh"
}

validate_app_bundle() {
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
    echo "Refusing a bundle without the signed goalong CLI." >&2
    return 1
  fi
  verify_bundle_signature "$app_path" || return 1
  audit_bundle_privacy "$app_path" || return 1
}

trim_log_to_limit() {
  local path="$1"
  local size
  local temporary

  [[ -e "$path" ]] || return 0
  if [[ ! -f "$path" || -L "$path" ]]; then
    echo "Installer log must be a regular file: $path" >&2
    return 1
  fi
  size="$(/usr/bin/stat -f '%z' "$path")"
  if [[ "$size" -le "$LOG_MAX_BYTES" ]]; then
    return 0
  fi

  temporary="$(/usr/bin/mktemp "$LOG_DIR/.installer-log.XXXXXX")"
  /usr/bin/tail -c "$LOG_MAX_BYTES" "$path" >"$temporary"
  /bin/chmod 600 "$temporary"
  /bin/mv -f "$temporary" "$path"
}

prepare_installer_log() {
  local index
  local source
  local destination

  /bin/mkdir -p "$LOG_DIR"
  /bin/chmod 700 "$LOG_DIR"
  if [[ -L "$LOG_FILE" ]]; then
    echo "Refusing symlinked installer log: $LOG_FILE" >&2
    return 1
  fi
  for ((index = 1; index <= LOG_BACKUP_COUNT; index++)); do
    destination="$LOG_FILE.$index"
    if [[ -e "$destination" || -L "$destination" ]]; then
      if [[ ! -f "$destination" || -L "$destination" ]]; then
        echo "Refusing unexpected installer log backup: $destination" >&2
        return 1
      fi
    fi
  done

  if [[ -f "$LOG_FILE" && -s "$LOG_FILE" ]]; then
    trim_log_to_limit "$LOG_FILE"
    for ((index = LOG_BACKUP_COUNT; index >= 2; index--)); do
      source="$LOG_FILE.$((index - 1))"
      destination="$LOG_FILE.$index"
      if [[ -e "$source" || -L "$source" ]]; then
        if [[ ! -f "$source" || -L "$source" ]]; then
          echo "Refusing unexpected installer log backup: $source" >&2
          return 1
        fi
        /bin/mv -f "$source" "$destination"
      fi
    done
    /bin/mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi

  : >"$LOG_FILE"
  /bin/chmod 600 "$LOG_FILE"
}

run_step() {
  local title="$1"
  local status
  local initial_log_bytes
  shift

  printf '  • %s… ' "$title"
  set +e
  if [[ "$VERBOSE" == "1" ]]; then
    echo
    initial_log_bytes="$(/usr/bin/stat -f '%z' "$LOG_FILE" 2>/dev/null || echo 0)"
    "$@" >>"$LOG_FILE" 2>&1
    status=$?
    /usr/bin/tail -c "+$((initial_log_bytes + 1))" "$LOG_FILE"
  else
    "$@" >>"$LOG_FILE" 2>&1
    status=$?
  fi
  set -e
  trim_log_to_limit "$LOG_FILE"

  if [[ "$status" -eq 0 ]]; then
    if [[ "$VERBOSE" == "1" ]]; then
      echo "    done"
    else
      echo "done"
    fi
    return 0
  fi

  echo "failed"
  echo "See $LOG_FILE" >&2
  /usr/bin/tail -n 40 "$LOG_FILE" >&2 || true
  return "$status"
}

safe_remove_temporary_directory() {
  local path="$1"
  local name

  [[ -n "$path" && -d "$path" && ! -L "$path" ]] || return 0
  name="$(/usr/bin/basename "$path")"
  case "$name" in
    localhistory-source-install.*|.goalong-history-source-stage.*)
      /bin/rm -rf -- "$path"
      ;;
    *)
      echo "Refusing to remove unexpected temporary directory: $path" >&2
      return 1
      ;;
  esac
}

safe_remove_backup_bundle() {
  local path="$1"
  local expected="$TARGET_DIR/.Goalong History.source-install-backup.app"

  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  if [[ "$path" != "$expected" || ! -d "$path" || -L "$path" ]]; then
    echo "Refusing to remove unexpected rollback bundle: $path" >&2
    return 1
  fi
  if ! bundle_has_expected_identity "$path"; then
    echo "Refusing to remove rollback bundle with an unexpected identifier: $path" >&2
    return 1
  fi
  verify_bundle_signature "$path" >/dev/null 2>&1 || return 1
  /bin/rm -rf -- "$path"
}

rollback_replacement() {
  local failed_app=""

  if [[ "$REPLACEMENT_ACTIVE" -ne 1 ]]; then
    return 0
  fi

  if [[ -n "$TARGET_APP" && ( -e "$TARGET_APP" || -L "$TARGET_APP" ) ]]; then
    if [[ -n "$INSTALL_STAGE_ROOT" && -d "$INSTALL_STAGE_ROOT" && ! -L "$INSTALL_STAGE_ROOT" ]]; then
      failed_app="$INSTALL_STAGE_ROOT/failed-$APP_NAME.app"
      /bin/mv "$TARGET_APP" "$failed_app" 2>/dev/null || true
    fi
  fi
  if [[ "$ORIGINAL_TARGET_PRESENT" -eq 1 && -d "$BACKUP_APP" && ! -L "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
    /bin/mv "$BACKUP_APP" "$TARGET_APP" 2>/dev/null || true
  fi
  REPLACEMENT_ACTIVE=0
}

cleanup() {
  local status=$?
  rollback_replacement || true
  safe_remove_temporary_directory "$INSTALL_STAGE_ROOT" || true
  safe_remove_temporary_directory "$BUILD_OUTPUT" || true
  exit "$status"
}

recover_interrupted_replacement() {
  [[ ! -e "$BACKUP_APP" && ! -L "$BACKUP_APP" ]] && return 0
  if [[ ! -d "$BACKUP_APP" || -L "$BACKUP_APP" ]] || ! bundle_has_expected_identity "$BACKUP_APP"; then
    echo "An unexpected rollback artifact requires manual inspection: $BACKUP_APP" >&2
    return 1
  fi

  if [[ ! -e "$TARGET_APP" && ! -L "$TARGET_APP" ]]; then
    /bin/mv "$BACKUP_APP" "$TARGET_APP"
    if ! verify_bundle_signature "$TARGET_APP"; then
      echo "Restored the prior app, but its signature no longer validates: $TARGET_APP" >&2
      return 1
    fi
    echo "Restored the previous app after an interrupted source installation."
    return 0
  fi

  if ! bundle_has_expected_identity "$TARGET_APP" || ! verify_bundle_signature "$TARGET_APP"; then
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
    echo "Refusing to replace an unexpected item at $TARGET_APP" >&2
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

select_install_target() {
  local system_directory="${1:-/Applications}"
  local user_directory="${2:-$HOME/Applications}"
  local directory
  local app_name
  local candidate
  local selected_directory=""
  local existing_count=0
  local -a application_names=("$APP_NAME" "$PREVIOUS_APP_NAME" "$LEGACY_APP_NAME")

  for directory in "$system_directory" "$user_directory"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      if [[ ! -d "$directory" || -L "$directory" ]]; then
        echo "Refusing unsafe application directory: $directory" >&2
        return 1
      fi
    fi

    for app_name in "${application_names[@]}"; do
      candidate="$directory/$app_name.app"
      [[ ! -e "$candidate" && ! -L "$candidate" ]] && continue
      if [[ -L "$candidate" ]]; then
        echo "Refusing symlinked installed app: $candidate" >&2
        return 1
      fi
      if [[ ! -d "$candidate" ]] ||
         ! bundle_has_expected_identity "$candidate" ||
         ! verify_bundle_signature "$candidate" >/dev/null 2>&1; then
        echo "Refusing unexpected or invalid installed app: $candidate" >&2
        return 1
      fi
      existing_count=$((existing_count + 1))
      selected_directory="$directory"
    done
  done

  if [[ "$existing_count" -gt 1 ]]; then
    echo "Multiple Goalong History installations were found; refusing to create or remove a second copy." >&2
    return 1
  fi

  if [[ "$existing_count" -eq 0 ]]; then
    if [[ -d "$system_directory" && ! -L "$system_directory" && -w "$system_directory" ]]; then
      selected_directory="$system_directory"
    else
      if [[ -L "$user_directory" || ( -e "$user_directory" && ! -d "$user_directory" ) ]]; then
        echo "Refusing unsafe user application directory: $user_directory" >&2
        return 1
      fi
      /bin/mkdir -p "$user_directory"
      selected_directory="$user_directory"
    fi
  fi

  set_verified_target_directory "$selected_directory"
  TARGET_APP="$TARGET_DIR/$APP_NAME.app"
  BACKUP_APP="$TARGET_DIR/.Goalong History.source-install-backup.app"
}

unregister_login_item_if_possible() {
  local app_path="$1"
  local executable_name="$2"
  local executable="$app_path/Contents/MacOS/$executable_name"

  [[ -d "$app_path" && ! -L "$app_path" ]] || return 0
  bundle_has_expected_identity "$app_path" || return 0
  verify_bundle_signature "$app_path" >/dev/null 2>&1 || return 0
  [[ -f "$executable" && ! -L "$executable" && -x "$executable" ]] || return 0

  if "$executable" --unregister-login-item >>"$LOG_FILE" 2>&1; then
    echo "  ✓ Login item unregistered from $app_path"
  else
    echo "  ! Could not unregister the login item from $app_path; continuing with legacy cleanup." >&2
  fi
  trim_log_to_limit "$LOG_FILE"
}

replace_staged_bundle() {
  local staged_app="$1"

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
  if ! validate_app_bundle "$TARGET_APP"; then
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
    echo "Refusing to remove an unexpected or invalid legacy app: $legacy_app" >&2
    return 1
  fi
  /bin/rm -rf -- "$legacy_app"
}

main() {
  local source_app
  local source_build_number
  local selected_target_directory
  local staged_app

  if [[ -n "${LOCALHISTORY_RUN_TESTS+x}" && "${LOCALHISTORY_RUN_TESTS}" != "1" ]]; then
    echo "Source installation requires the full test suite; LOCALHISTORY_RUN_TESTS must be 1." >&2
    exit 64
  fi
  prepare_installer_log
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are needed only for source installation." >&2
    echo "Run: xcode-select --install" >&2
    exit 1
  fi

  run_step "Checking source installer safety" "$ROOT_DIR/scripts/test_install_from_source_safety.sh"
  run_step "Checking code-signing network policy" /bin/bash "$ROOT_DIR/scripts/test_codesign_policy.sh"
  run_step "Checking privacy boundaries" "$ROOT_DIR/scripts/audit_privacy_boundaries.sh"

  BUILD_OUTPUT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/localhistory-source-install.XXXXXX")"
  source_build_number="${LOCALHISTORY_BUILD_NUMBER:-$(/bin/date -u +%Y%m%d.%H%M%S)}"
  run_step "Testing and building the native app" env \
    LOCALHISTORY_VERSION="${LOCALHISTORY_VERSION:-0.5.1}" \
    LOCALHISTORY_BUILD_NUMBER="$source_build_number" \
    LOCALHISTORY_ARCHS="$(/usr/bin/uname -m)" \
    LOCALHISTORY_OUTPUT_DIR="$BUILD_OUTPUT" \
    LOCALHISTORY_RUN_TESTS=1 \
    "$ROOT_DIR/scripts/build_app.sh"

  source_app="$BUILD_OUTPUT/$APP_NAME.app"
  if [[ ! -d "$source_app" || -L "$source_app" ]]; then
    echo "The source build did not produce a regular app bundle at $source_app" >&2
    exit 1
  fi
  run_step "Verifying the source bundle" validate_app_bundle "$source_app"

  select_install_target
  selected_target_directory="$TARGET_DIR"
  recover_interrupted_replacement
  preflight_existing_target

  INSTALL_STAGE_ROOT="$(/usr/bin/mktemp -d "$TARGET_DIR/.goalong-history-source-stage.XXXXXX")"
  /bin/chmod 700 "$INSTALL_STAGE_ROOT"
  staged_app="$INSTALL_STAGE_ROOT/$APP_NAME.app"
  run_step "Staging the verified source bundle" /usr/bin/ditto "$source_app" "$staged_app"
  run_step "Verifying the staged bundle" validate_app_bundle "$staged_app"
  select_install_target
  if [[ "$TARGET_DIR" != "$selected_target_directory" ]]; then
    echo "The selected application location changed during installation; refusing replacement." >&2
    exit 1
  fi
  recover_interrupted_replacement
  preflight_existing_target
  unregister_login_item_if_possible "$TARGET_APP" "$EXECUTABLE_NAME"
  unregister_login_item_if_possible "/Applications/$PREVIOUS_APP_NAME.app" "$PREVIOUS_APP_NAME"
  unregister_login_item_if_possible "$HOME/Applications/$PREVIOUS_APP_NAME.app" "$PREVIOUS_APP_NAME"
  unregister_login_item_if_possible "/Applications/$LEGACY_APP_NAME.app" "$LEGACY_APP_NAME"
  unregister_login_item_if_possible "$HOME/Applications/$LEGACY_APP_NAME.app" "$LEGACY_APP_NAME"

  /bin/launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist" >/dev/null 2>&1 || true
  /bin/rm -f -- "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
  /usr/bin/pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
  /usr/bin/pkill -x "$PREVIOUS_APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/pkill -x "$LEGACY_APP_NAME" >/dev/null 2>&1 || true
  /bin/sleep 0.4

  run_step "Installing with rollback protection" replace_staged_bundle "$staged_app"
  run_step "Validating the installed bundle" validate_app_bundle "$TARGET_APP"
  run_step "Installing the goalong terminal command" install_goalong_cli_link "$TARGET_APP"

  remove_verified_legacy_bundle "/Applications/$PREVIOUS_APP_NAME.app"
  remove_verified_legacy_bundle "$HOME/Applications/$PREVIOUS_APP_NAME.app"
  remove_verified_legacy_bundle "/Applications/$LEGACY_APP_NAME.app"
  remove_verified_legacy_bundle "$HOME/Applications/$LEGACY_APP_NAME.app"
  finalize_replacement

  /usr/bin/open "$TARGET_APP"
  printf '\nInstalled from source at %s\n' "$TARGET_APP"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
