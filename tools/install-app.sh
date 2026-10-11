#!/bin/zsh
# Builds, replaces ~/Applications/MowerBar.app and relaunches it.
set -eu
ROOT="${0:A:h:h}"
APP="$HOME/Applications/MowerBar.app"
BUNDLE_ID="${BUNDLE_ID:-io.github.wiselaunchdolead.mowerbar}"
"$ROOT/tools/build-app.sh"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
for _ in {1..10}; do pgrep -f "MowerBar.app/Contents/MacOS" >/dev/null || break; sleep 1; done
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$ROOT/dist/MowerBar.app" "$APP"
codesign --verify --strict "$APP"
# Without this, Finder and the Dock keep showing a previous icon from their cache.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
killall Dock
open "$APP"
print "Installed: $APP"
