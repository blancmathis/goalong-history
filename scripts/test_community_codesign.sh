#!/bin/bash
# Disposable GitHub runner only. Never modifies a developer Mac's trust settings.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
  echo 'SKIP: Community trust bootstrap is restricted to disposable GitHub-hosted runners.'
  exit 0
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "$RUNNER_TEMP/goalong-community-probe.XXXXXX")"
OUT="$ROOT/qa/community-signing"
mkdir -p "$OUT"
umask 077
PASSWORD="$(openssl rand -hex 32)"
echo "::add-mask::$PASSWORD"
KEYCHAIN="$WORK/probe.keychain-db"
cleanup() {
  sudo security remove-trusted-cert -d "$WORK/cert.pem" >/dev/null 2>&1 || true
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cat > "$WORK/codesign.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=codesign
prompt=no
[dn]
CN=Goalong Community Compatibility Test
O=Goalong
[codesign]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning
subjectKeyIdentifier=hash
EOF
openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 2 -config "$WORK/codesign.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
export PASSWORD
PKCS12_FLAGS=()
if [[ "$(openssl version)" == OpenSSL\ 3* ]]; then PKCS12_FLAGS=(-legacy); fi
openssl pkcs12 -export "${PKCS12_FLAGS[@]}" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/probe.p12" -passout env:PASSWORD
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/probe.p12" -f pkcs12 -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
# Only this ephemeral signing machine trusts the test certificate for code signing.
sudo security add-trusted-cert -d -r trustRoot -p codeSign "$WORK/cert.pem"
IDENTITY="$(openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
printf 'int answer(void) { return 42; }\n' > "$WORK/lib.c"
printf 'extern int answer(void); int main(void) { return answer() == 42 ? 0 : 1; }\n' > "$WORK/app.c"
for version in 1 2; do
  APP="$OUT/$version/Goalong Community Test.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
  clang -dynamiclib "$WORK/lib.c" -o "$APP/Contents/Frameworks/libprobe.dylib" -Wl,-install_name,@rpath/libprobe.dylib
  clang "$WORK/app.c" -L"$APP/Contents/Frameworks" -lprobe -Wl,-rpath,@executable_path/../Frameworks -o "$APP/Contents/MacOS/test"
  python3 - "$APP/Contents/Info.plist" "$version" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
 plistlib.dump({'CFBundleIdentifier':'ai.goalong.community-test','CFBundleExecutable':'test','CFBundlePackageType':'APPL','CFBundleVersion':sys.argv[2]},f)
PY
  codesign --force --timestamp=none --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP/Contents/Frameworks/libprobe.dylib"
  codesign --force --timestamp=none --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"
  codesign --verify --deep --strict "$APP"
  codesign -d -r- "$APP" 2>&1 | sed -nE 's/^(# )?designated => //p' > "$OUT/requirement-$version.txt"
  "$APP/Contents/MacOS/test"
done
cmp "$OUT/requirement-1.txt" "$OUT/requirement-2.txt"
sudo security remove-trusted-cert -d "$WORK/cert.pem"
security delete-keychain "$KEYCHAIN"
# Like an end user's Mac: the certificate is neither installed nor trusted.
for version in 1 2; do
  APP="$OUT/$version/Goalong Community Test.app"
  codesign --verify --deep --strict "-R=$(cat "$OUT/requirement-1.txt")" "$APP"
  "$APP/Contents/MacOS/test"
done
cp "$WORK/cert.pem" "$OUT/test-public-certificate.pem"
printf '%s\n' 'PASS: same certificate-pinned identity across two app versions; signed dylib loads; both run and verify after removing test trust and private key. No Apple account used.' | tee "$OUT/result.txt"
ditto -c -k --keepParent "$OUT/1/Goalong Community Test.app" "$OUT/probe-1.zip"
ditto -c -k --keepParent "$OUT/2/Goalong Community Test.app" "$OUT/probe-2.zip"
