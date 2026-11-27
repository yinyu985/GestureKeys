#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode=local
INSTALL_DIR="${GESTUREKEYS_INSTALL_DIR-/Applications}"
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
fi

signing_pem=${GESTUREKEYS_SIGN_PEM-}
if [[ "$mode" == self-signed ]]; then
  : "${signing_pem:?Set GESTUREKEYS_SIGN_PEM to the existing certificate and private key PEM}"
elif [[ "$mode" == local && -n "$INSTALL_DIR" && ! ${GESTUREKEYS_SIGN_PEM+x} ]]; then
  local_identity="$HOME/.config/GestureKeys-signing/identity.pem"
  if [[ -r "$local_identity" ]]; then signing_pem=$local_identity; fi
fi
if [[ "$mode" != release && -n "$signing_pem" ]]; then
  signer=${GESTUREKEYS_RCODESIGN:-rcodesign}
  if [[ ! ${GESTUREKEYS_RCODESIGN+x} && -x "$PWD/.build/signing-tools/rcodesign" ]]; then
    signer="$PWD/.build/signing-tools/rcodesign"
  fi
  command -v "$signer" >/dev/null || { echo 'Self-signed builds require rcodesign.' >&2; exit 1; }
  [[ "$signing_pem" = /* && -r "$signing_pem" ]] || { echo 'Signing PEM must be a readable absolute path.' >&2; exit 1; }
  /usr/bin/openssl x509 -in "$signing_pem" -checkend 0 -noout
fi

designated_requirement() {
  codesign -d -r- "$1" 2>&1 | awk -F' => ' '/^designated => /{print $2}'
}

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
        'CFBundleShortVersionString': '0.7.9',
        'CFBundleVersion': '32',
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
if [[ "$mode" != release && -n "$signing_pem" ]]; then
  "$signer" sign -C /dev/null --pem-file "$signing_pem" --timestamp-url none "$APP"
  fingerprint=$(/usr/bin/openssl x509 -in "$signing_pem" -outform der | shasum -a 1 | awk '{print $1}')
  requirement="identifier \"local.yy.GestureKeys\" and certificate root = H\"$fingerprint\""
  actual=$(designated_requirement "$APP")
  [[ "$actual" == "$requirement" ]] || { echo 'Self-signed app lacks the expected certificate-based identity.' >&2; exit 1; }
  codesign --verify --strict -R "=$requirement" "$APP"
fi
if [[ "$mode" == self-signed ]]; then
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

if [[ -z "$signing_pem" ]]; then
  codesign --force --sign - --identifier local.yy.GestureKeys "$APP"
fi
codesign --verify --strict "$APP"
echo "Built: $APP"
# An empty GESTUREKEYS_INSTALL_DIR skips installation.
if [[ -n "$INSTALL_DIR" && -w "$INSTALL_DIR" ]]; then
  installed="$INSTALL_DIR/GestureKeys.app"
  if [[ -e "$installed" ]]; then
    current_requirement=$(designated_requirement "$installed")
    if [[ -n "$current_requirement" && "$current_requirement" != "$(designated_requirement "$APP")" ]]; then
      echo "Installation skipped: the new build does not match the signing identity at $installed. Set GESTUREKEYS_SIGN_PEM to its signing identity." >&2
      exit 1
    fi
  fi
  staging=$(mktemp -d "$INSTALL_DIR/.gesturekeys-install.XXXXXX")
  cleanup_install() {
    if [[ -e "$staging/previous.app" && ! -e "$installed" ]]; then
      mv "$staging/previous.app" "$installed" || return
    fi
    rm -rf "$staging"
  }
  trap cleanup_install EXIT
  ditto "$APP" "$staging/GestureKeys.app"
  codesign --verify --strict "$staging/GestureKeys.app"
  GESTUREKEYS_INSTALLED_APP="$installed" swift -e '
    import AppKit
    let path = ProcessInfo.processInfo.environment["GESTUREKEYS_INSTALLED_APP"]!
    let installed = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "local.yy.GestureKeys")
        .filter { $0.bundleURL?.resolvingSymlinksInPath().path == installed.path }
    apps.forEach { _ = $0.terminate() }
    let deadline = Date().addingTimeInterval(5)
    while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if apps.contains(where: { !$0.isTerminated }) {
        fputs("Close the installed GestureKeys before replacing it.\n", stderr)
        exit(1)
    }
  '
  # Replace, never merge: an old file left behind invalidates the code signature.
  if [[ -e "$installed" ]]; then mv "$installed" "$staging/previous.app"; fi
  mv "$staging/GestureKeys.app" "$installed"
  touch "$installed"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed"
  echo "Installed: $installed"
fi
