#!/usr/bin/env bash
# Builds Duo.app and installs it into /Applications (skip with INSTALL=0).
# Works with plain Command Line Tools — no Xcode needed, because the Metal
# shaders are compiled at launch rather than ahead of time.
set -euo pipefail
cd "$(dirname "$0")"

# The Command Line Tools that came with macOS 27 carry an SDK whose SwiftUI
# declares @State as a macro, but not the plugin that implements it. Xcode's
# toolchain has a matching pair, so prefer it when it is installed.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG="${1:-release}"
APP="build/Duo.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Duo"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Duo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# TCC ties Screen Recording to the signature. An ad-hoc signature changes with
# every build and silently revokes the grant; a local certificate keeps it.
IDENTITY="Duo Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier app.duo.Duo "$APP"
else
  echo "note: no \"$IDENTITY\" certificate — signing ad-hoc, Screen Recording resets on every build"
  codesign --force --sign - --identifier app.duo.Duo "$APP"
fi
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ "${INSTALL:-1}" = 1 ]; then
  pkill -x Duo 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/Duo.app
  ditto "$APP" /Applications/Duo.app
  # Drop the staging bundle: left behind, Launch Services lists Duo twice.
  "$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
  rm -rf "$APP"
  "$LSREGISTER" -f /Applications/Duo.app
  echo "installed /Applications/Duo.app"
else
  echo "built $PWD/$APP"
fi
