#!/bin/bash

# Choose a stable local signing identity when one is available. Ad-hoc signing
# makes the designated requirement depend on the exact binary CDHash, which can
# make macOS privacy permissions look like they belong to a different app after
# every rebuild.

localhistory_choose_source_codesign_identity() {
  local identities="$1"
  local installed_authority="${2:-}"
  local candidates
  local candidate_count

  candidates="$({
    printf '%s\n' "$identities" \
      | /usr/bin/sed -nE 's/^[[:space:]]*[0-9]+\) [[:xdigit:]]+ "(Apple Development: [^"]+)"$/\1/p'
  } | /usr/bin/sort -u)"

  if [[ -n "$installed_authority" ]] \
     && printf '%s\n' "$candidates" | /usr/bin/grep -Fxq "$installed_authority"; then
    printf '%s\n' "$installed_authority"
    return 0
  fi

  candidate_count="$(printf '%s\n' "$candidates" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')"
  case "$candidate_count" in
    0)
      printf '%s\n' '-'
      ;;
    1)
      printf '%s\n' "$candidates"
      ;;
    *)
      echo "Multiple Apple Development signing identities are available." >&2
      echo "Set LOCALHISTORY_CODESIGN_IDENTITY to the identity Goalong History should keep using." >&2
      return 1
      ;;
  esac
}

localhistory_installed_signing_authority() {
  local app_path
  local details

  for app_path in \
    "/Applications/Goalong History.app" \
    "$HOME/Applications/Goalong History.app"; do
    [[ -d "$app_path" && ! -L "$app_path" ]] || continue
    details="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1 || true)"
    printf '%s\n' "$details" \
      | /usr/bin/awk -F= '/^Authority=Apple Development:/{print $2; exit}'
    return 0
  done
}

localhistory_resolve_source_codesign_identity() {
  local identities
  local installed_authority

  if [[ -n "${LOCALHISTORY_CODESIGN_IDENTITY+x}" ]]; then
    if [[ -z "$LOCALHISTORY_CODESIGN_IDENTITY" ]]; then
      echo "LOCALHISTORY_CODESIGN_IDENTITY must not be empty." >&2
      return 1
    fi
    printf '%s\n' "$LOCALHISTORY_CODESIGN_IDENTITY"
    return 0
  fi

  identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
  installed_authority="$(localhistory_installed_signing_authority)"
  localhistory_choose_source_codesign_identity "$identities" "$installed_authority"
}

localhistory_verify_source_codesign_identity() {
  local identity="$1"
  local probe_directory
  local probe_binary

  [[ "$identity" != "-" ]] || return 0
  probe_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/goalong-codesign-probe.XXXXXX")"
  probe_binary="$probe_directory/probe"
  /bin/cp /usr/bin/true "$probe_binary"
  if ! /usr/bin/codesign --force --timestamp=none --sign "$identity" "$probe_binary" >/dev/null 2>&1; then
    /bin/rm -rf -- "$probe_directory"
    echo "The selected signing identity exists but its private key is unavailable to codesign: $identity" >&2
    echo "Unlock its keychain and allow codesign to use the private key. Goalong will not fall back to a changing ad-hoc identity when that would reset macOS permissions." >&2
    return 1
  fi
  /bin/rm -rf -- "$probe_directory"
}
