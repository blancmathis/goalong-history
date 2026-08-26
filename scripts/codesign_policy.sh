#!/bin/bash

# Developer ID distribution signatures need Apple's trusted timestamp service.
# Local development identities remain fully local and must not contact it.
localhistory_codesign_timestamp_argument() {
  local identity="$1"
  case "$identity" in
    -)
      return 0
      ;;
    "Developer ID Application:"*)
      printf '%s\n' '--timestamp'
      ;;
    *)
      printf '%s\n' '--timestamp=none'
      ;;
  esac
}
