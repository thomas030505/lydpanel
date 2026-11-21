#!/bin/zsh
# Bygger Lydpanel.app. Bruk: ./build.sh [--install]  (--install kopierer til ~/Applications og starter)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Lydpanel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14.2 \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework ServiceManagement \
  Sources/*.swift -o "$APP/Contents/MacOS/Lydpanel"

cp Info.plist "$APP/Contents/Info.plist"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Bygget: $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Lydpanel 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/Lydpanel.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Lydpanel.app
  echo "Installert og startet: ~/Applications/Lydpanel.app"
fi
