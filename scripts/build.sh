#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Resources

if [[ $# -gt 0 ]]; then
  BAB_INPUT="$1" GK_SEED_OUTPUT="$PWD/Resources/InitialRules.json" swift run GestureCoreChecks
else
  swift run GestureCoreChecks
fi
swift build -c release --product GestureKeys
BIN="$(swift build -c release --show-bin-path)"
APP="$PWD/.build/bundle/GestureKeys.app"
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
        'CFBundleShortVersionString': '0.6.2',
        'CFBundleVersion': '11',
        'CFBundleIconFile': 'GestureKeys-B2.icns',
        'LSMinimumSystemVersion': '13.0',
        'NSHighResolutionCapable': True,
        'NSHumanReadableCopyright': 'GestureKeys',
        'NSInputMonitoringUsageDescription': '识别你配置的鼠标点击和手势。',
    }, f)
PY
if [[ -f Resources/InitialRules.json ]]; then
  cp Resources/InitialRules.json "$APP/Contents/Resources/InitialRules.json"
fi
swift scripts/make_icon.swift "$APP/Contents/Resources/GestureKeys-B2.icns"
codesign --force --sign - --identifier local.yy.GestureKeys "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
# Keep a single copy so the Accessibility entry always points at the same bundle.
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
