#!/bin/bash

# Compatibility entry points preserve the caller's exact lockfile bytes so a build or test cannot
# create an unrelated source-tree change. The unified graph deliberately has no remote dependency.
goalong_preserve_package_resolved() {
  local root_dir="$1"
  GOALONG_PACKAGE_RESOLVED="$root_dir/Package.resolved"
  GOALONG_PACKAGE_RESOLVED_BACKUP="$(mktemp "${TMPDIR:-/tmp}/goalong-package-resolved.XXXXXX")"
  GOALONG_PACKAGE_RESOLVED_EXISTED=0
  if [[ -f "$GOALONG_PACKAGE_RESOLVED" ]]; then
    GOALONG_PACKAGE_RESOLVED_EXISTED=1
    cp "$GOALONG_PACKAGE_RESOLVED" "$GOALONG_PACKAGE_RESOLVED_BACKUP"
  fi
  trap goalong_restore_package_resolved EXIT
}

goalong_restore_package_resolved() {
  if [[ "${GOALONG_PACKAGE_RESOLVED_EXISTED:-0}" -eq 1 ]]; then
    cp "$GOALONG_PACKAGE_RESOLVED_BACKUP" "$GOALONG_PACKAGE_RESOLVED"
  else
    rm -f "$GOALONG_PACKAGE_RESOLVED"
  fi
  rm -f "$GOALONG_PACKAGE_RESOLVED_BACKUP"
}
