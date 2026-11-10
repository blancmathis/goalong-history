#!/bin/bash
# make local (scripts/local_try.sh) with NO_INSTALL=1 and stubbed build/verify steps: no signing, no
# install, no app launch. Checks the base choice, the manifest cap and the offline message.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo "test_local_try: skipped (needs macOS)"; exit 0; }
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/goalong-local-try-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/apps"
cp "$SRC/local_try.sh" "$SRC/build_number_policy.sh" "$T/scripts/"
cat >"$T/scripts/build_app.sh" <<'STUB'
#!/bin/bash
set -e
app="$LOCALHISTORY_OUTPUT_DIR/Goalong History.app"
mkdir -p "$app/Contents"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $LOCALHISTORY_BUILD_NUMBER" "$app/Contents/Info.plist" >/dev/null
STUB
printf '#!/bin/bash\nexit 0\n' | tee "$T/scripts/verify_release_identity.sh" >"$T/scripts/verify_local_bundle.sh"
chmod +x "$T/scripts/"*.sh
install_app() { # BUILD VERSION
  rm -rf "$T/apps/Goalong History.app"; mkdir -p "$T/apps/Goalong History.app/Contents"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $1" -c "Add :CFBundleShortVersionString string $2" \
    "$T/apps/Goalong History.app/Contents/Info.plist" >/dev/null
}
manifest() { printf '{"product":{"build":"%s","version":"%s"}}' "$1" "$2" >"$T/manifest.json"; }
run() { # extra env... ; output in $out, status in $status
  set +e
  out="$(env -u GITHUB_ACTIONS GOALONG_LOCAL_NO_INSTALL=1 GOALONG_LOCAL_OUT="$T/out" \
    GOALONG_LOCAL_TEST_APP_DIRS="$T/apps" GOALONG_LOCAL_TEST_MANIFEST="$T/manifest.json" "$@" \
    /bin/bash "$T/scripts/local_try.sh" 2>&1)"
  status=$?
  set -e
}
check() { [[ "$1" == "$2" ]] || { echo "FAIL: $3 (got: $out)" >&2; exit 1; }; }

# Base = installed release; try slot built into $OUT, nothing installed.
install_app 30000000.4266167.303702 0.6.90; manifest 30000000.4266167.303702 0.6.90
run
check "$status" 0 "NO_INSTALL run"
[[ "$out" == *"NO_INSTALL=1: stopped before install. App: $T/out/Goalong History.app"* ]] || { echo "FAIL: stop message: $out" >&2; exit 1; }
check "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$T/out/Goalong History.app/Contents/Info.plist")" 30000000.4266167.303799 "try build"
check "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$T/apps/Goalong History.app/Contents/Info.plist")" 30000000.4266167.303702 "installed app untouched"

# Implausible manifest is ignored; the installed release stays the base.
manifest 30000000.99999999.101 9.9.9
run
check "$status" 0 "implausible manifest run"
[[ "$out" == *"implausibly far ahead"* && "$out" == *"(30000000.4266167.303799)"* ]] || { echo "FAIL: manifest cap: $out" >&2; exit 1; }

# Offline with a local try installed: clear message, not "No published release".
install_app 30000000.4266167.303799 0.6.90; rm -f "$T/manifest.json"
run
check "$status" 1 "offline with try"
[[ "$out" == *"already a local try"* && "$out" != *"No published"* ]] || { echo "FAIL: offline message: $out" >&2; exit 1; }
echo "test_local_try: ok"
