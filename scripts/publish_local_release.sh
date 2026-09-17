#!/bin/bash
# Explicit owner action. Signs one tested CI archive locally; never exports signing keys.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RUN_ID=""
PUBLISH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    *) echo 'Usage: scripts/publish_local_release.sh --run-id RUN_ID [--publish]' >&2; exit 64 ;;
  esac
done
[[ "$RUN_ID" =~ ^[0-9]+$ ]] || { echo 'An exact completed CI run ID is required.' >&2; exit 64; }
[[ "$(uname -s)" == Darwin ]] || { echo 'Local signing requires the owner’s Mac.' >&2; exit 1; }
REPO=blancmathis/goalong-history
REVISION="$(git rev-parse HEAD)"
git diff --quiet && git diff --cached --quiet || { echo 'Commit tracked changes before publishing.' >&2; exit 1; }
REMOTE="$(git ls-remote origin refs/heads/main | cut -f1)"
[[ "$REMOTE" == "$REVISION" ]] || { echo 'Only the exact current origin/main revision can be published.' >&2; exit 1; }
WORK="$(mktemp -d /tmp/goalong-local-publish.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
umask 077
gh run view "$RUN_ID" --repo "$REPO" --json conclusion,headSha,headBranch,workflowName > "$WORK/run.json"
python3 - "$WORK/run.json" "$REVISION" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r['conclusion']=='success', 'The entire input workflow must succeed first'
assert r['headSha']==sys.argv[2] and r['headBranch']=='main', 'The signing input must match current main'
assert r['workflowName'] in ['Continuous Community macOS release','Prepare universal archive for local signing'], 'Unexpected workflow'
PY
gh run download "$RUN_ID" --repo "$REPO" --name "Goalong-Unsigned-Universal-$REVISION" --dir "$WORK/input"
python3 - "$WORK/input" <<'PY'
import hashlib,sys
from pathlib import Path
sys.path.insert(0,'scripts')
from prepare_presigned_release import validate_archive
p=Path(sys.argv[1]);z=p/'Goalong-History-macOS-universal.zip'
expected=(p/'staging-sha256.txt').read_text().split()[0]
assert len(expected)==64 and hashlib.sha256(z.read_bytes()).hexdigest()==expected, 'CI archive checksum mismatch'
validate_archive(z)
PY
[[ ! -L "$ROOT/dist" ]] || { echo 'Refusing symlinked output directory.' >&2; exit 1; }
mkdir -p "$ROOT/dist"
OUT="$(mktemp -d "$ROOT/dist/local-signed.XXXXXX")"
ditto -x -k "$WORK/input/Goalong-History-macOS-universal.zip" "$OUT"
APP="$OUT/Goalong History.app"
INFO="$APP/Contents/Info.plist"
python3 - "$INFO" "$REVISION" <<'PY'
import plistlib,sys
sys.path.insert(0,'scripts')
from update_policy import validate_info
p=plistlib.load(open(sys.argv[1],'rb'))
assert p['GoalongSourceRevision']==sys.argv[2], 'Embedded source revision mismatch'
assert p['CFBundleIdentifier']=='ai.goalong.localhistory'
validate_info(p,require_configured=True)
PY
lipo "$APP/Contents/MacOS/Goalong History" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
IDENTITY="$(python3 -c 'import json;print(json.load(open("Distribution/release-signing.json"))["certificateSHA1"])')"
source "$ROOT/scripts/source_codesign_identity.sh"
localhistory_verify_source_codesign_identity "$IDENTITY"
SIGN=(--force --timestamp=none --options runtime --sign "$IDENTITY")
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN[@]}" --identifier ai.goalong.localhistory.codex-runtime "$APP/Contents/Helpers/codex"
codesign "${SIGN[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN[@]}" "$FRAMEWORK"
codesign "${SIGN[@]}" --identifier ai.goalong.localhistory "$APP/Contents/MacOS/goalong"
codesign "${SIGN[@]}" --identifier ai.goalong.localhistory.relauncher "$APP/Contents/MacOS/goalong-relauncher"
codesign "${SIGN[@]}" --identifier ai.goalong.localhistory "$APP"
bash scripts/verify_release_identity.sh "$APP"
LOCALHISTORY_APP_PATH="$APP" LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED=1 bash scripts/verify_local_bundle.sh
ZIP="$OUT/Goalong-History-macOS-universal.zip"
ditto -c -k --keepParent --norsrc "$APP" "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
STAGE="presigned-${REVISION:0:12}-$VERSION"
echo "SIGNED_DIST=$OUT"
if [[ "$PUBLISH" != 1 ]]; then
  echo 'Verified local signature ready. Nothing published; --publish authorizes the release handoff.'
  exit 0
fi
[[ "$(git ls-remote origin refs/heads/main | cut -f1)" == "$REVISION" ]] || { echo 'Main changed while signing; refusing stale publication.' >&2; exit 1; }
# No clobber: the staging checksum is bound explicitly to the publication request.
gh release create "$STAGE" --repo "$REPO" --target "$REVISION" --prerelease --latest=false \
  --title "Local signing input for Goalong $VERSION" \
  --notes "Locally signed input for $REVISION. Awaiting independent CI checks and Ed25519 release signatures. No private signing key was exported." "$ZIP"
gh workflow run continuous-release.yml --repo "$REPO" --ref main -f "signed_stage=$STAGE" -f "signed_sha256=$SHA256"
echo "Publication requested for $REVISION; wait for CI and verify the public feed before claiming delivery."
echo "After success: bash scripts/verify_published_update.sh '$OUT'"
