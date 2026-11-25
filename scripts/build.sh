#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode=local
if [[ "${1:-}" == --release || "${1:-}" == --self-signed ]]; then
  mode=${1#--}
  shift
  # Never include a private rule seed in a distribution artifact.
  [[ $# -eq 0 ]] || { echo "Usage: ./scripts/build.sh --$mode" >&2; exit 1; }
fi
if [[ "$mode" == release ]]; then
  : "${GESTUREKEYS_SIGN_IDENTITY:?Set the full Developer ID Application certificate name}"
  : "${GESTUREKEYS_TEAM_ID:?Set the Developer ID signing team ID}"
  : "${GESTUREKEYS_NOTARY_PROFILE:?Set the notarytool Keychain profile name}"
  if [[ "$GESTUREKEYS_SIGN_IDENTITY" != 'Developer ID Application: '* || ! "$GESTUREKEYS_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo 'Release requires a Developer ID Application identity and a 10-character Team ID.' >&2
    exit 1
  fi
  identities=$(security find-identity -v -p codesigning)
  if [[ "$identities" != *\""$GESTUREKEYS_SIGN_IDENTITY"\"* ]]; then
    echo 'The release signing identity is not available in the Keychain.' >&2
    exit 1
  fi
elif [[ "$mode" == self-signed ]]; then
  : "${GESTUREKEYS_SIGN_PEM:?Set the absolute path to the existing certificate and private key PEM}"
  signer=${GESTUREKEYS_RCODESIGN:-rcodesign}
  command -v "$signer" >/dev/null || { echo 'Self-signed builds require rcodesign.' >&2; exit 1; }
  [[ "$GESTUREKEYS_SIGN_PEM" = /* && -r "$GESTUREKEYS_SIGN_PEM" ]] || { echo 'Signing PEM must be a readable absolute path.' >&2; exit 1; }
  /usr/bin/openssl x509 -in "$GESTUREKEYS_SIGN_PEM" -checkend 0 -noout
fi

swift run GestureCoreChecks
swift build -c release --product GestureKeys
BIN="$(swift build -c release --show-bin-path)"
APP="$PWD/.build/bundle/GestureKeys.app"
# Remove stale resources so a build without a private seed cannot retain one.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/GestureKeys" "$APP/Contents/MacOS/GestureKeys"
/usr/libexec/PlistBuddy -c 'Clear dict' "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({
        'CFBundleExecutable': 'GestureKeys',
        'CFBundleIdentifier': 'local.yy.GestureKeys',
        'CFBundleName': 'GestureKeys',
        'CFBundleDisplayName': 'GestureKeys',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '0.7.5',
        'CFBundleVersion': '22',
        'CFBundleDevelopmentRegion': 'zh-Hans',
        'CFBundleIconFile': 'GestureKeys-B2.icns',
        'LSMinimumSystemVersion': '13.0',
        'NSHighResolutionCapable': True,
        'NSHumanReadableCopyright': 'GestureKeys',
        'NSInputMonitoringUsageDescription': '识别你配置的鼠标点击和手势。',
    }, f)
PY
if [[ $# -gt 0 ]]; then
  swift run GestureSeed "$1" "$APP/Contents/Resources/InitialRules.json"
fi
ditto "$BIN/GestureKeys_GestureCore.bundle" "$APP/Contents/Resources/GestureKeys_GestureCore.bundle"
for language in en zh-Hans; do
  mkdir -p "$APP/Contents/Resources/$language.lproj"
  cp "Resources/$language.lproj/InfoPlist.strings" "$APP/Contents/Resources/$language.lproj/"
done
swift scripts/make_icon.swift "$APP/Contents/Resources/GestureKeys-B2.icns"
if [[ "$mode" != local && "$(lipo -archs "$APP/Contents/MacOS/GestureKeys")" != arm64 ]]; then
  echo 'Distribution packaging expects an arm64 build. Run it on Apple Silicon.' >&2
  exit 1
fi
if [[ "$mode" == release ]]; then
  codesign --force --sign "$GESTUREKEYS_SIGN_IDENTITY" --identifier local.yy.GestureKeys --options runtime --timestamp "$APP"
  # Check the actual signer without pinning a particular certificate or binary hash.
  requirement="identifier \"local.yy.GestureKeys\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$GESTUREKEYS_TEAM_ID\""
  codesign --verify --strict -R "=$requirement" "$APP"

  mkdir -p dist
  staging=$(mktemp -d "$PWD/dist/.release.XXXXXX")
  trap 'rm -rf "$staging"' EXIT
  ditto -c -k --keepParent "$APP" "$staging/notary.zip"
  report=$(xcrun notarytool submit "$staging/notary.zip" --keychain-profile "$GESTUREKEYS_NOTARY_PROFILE" --wait --timeout 30m --output-format json)
  printf '%s\n' "$report"
  printf '%s\n' "$report" | python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["status"] == "Accepted" else "Notarization did not return Accepted.")'
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  suffix=
fi
if [[ "$mode" == self-signed ]]; then
  "$signer" sign -C /dev/null --pem-file "$GESTUREKEYS_SIGN_PEM" --timestamp-url none "$APP"
  fingerprint=$(/usr/bin/openssl x509 -in "$GESTUREKEYS_SIGN_PEM" -outform der | shasum -a 1 | awk '{print $1}')
  requirement="identifier \"local.yy.GestureKeys\" and certificate root = H\"$fingerprint\""
  actual=$(codesign -d -r- "$APP" 2>&1 | awk -F' => ' '/^designated => /{print $2}')
  [[ "$actual" == "$requirement" ]] || { echo 'Self-signed app lacks the expected certificate-based identity.' >&2; exit 1; }
  codesign --verify --strict -R "=$requirement" "$APP"
  suffix=-self-signed
  mkdir -p dist
  staging=$(mktemp -d "$PWD/dist/.release.XXXXXX")
  trap 'rm -rf "$staging"' EXIT
fi
if [[ "$mode" != local ]]; then
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
  archive="GestureKeys-$version-arm64$suffix.zip"
  ditto -c -k --keepParent "$APP" "$staging/$archive"
  mv "$staging/$archive" "$PWD/dist/$archive"
  echo "Release: $PWD/dist/$archive"
  exit 0
fi

codesign --force --sign - --identifier local.yy.GestureKeys "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
# Install local builds at a consistent path. This does not preserve permissions across ad-hoc rebuilds.
# An empty GESTUREKEYS_INSTALL_DIR skips installation.
INSTALL_DIR="${GESTUREKEYS_INSTALL_DIR-/Applications}"
if [[ -n "$INSTALL_DIR" && -w "$INSTALL_DIR" ]]; then
  swift -e 'import AppKit; for app in NSRunningApplication.runningApplications(withBundleIdentifier: "local.yy.GestureKeys") { _ = app.terminate() }' || true
  sleep 1
  # Replace, never merge: an old file left behind invalidates the code signature.
  rm -rf "$INSTALL_DIR/GestureKeys.app"
  ditto "$APP" "$INSTALL_DIR/GestureKeys.app"
  codesign --verify --strict "$INSTALL_DIR/GestureKeys.app"
  touch "$INSTALL_DIR/GestureKeys.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/GestureKeys.app"
  echo "Installed: $INSTALL_DIR/GestureKeys.app"
fi
