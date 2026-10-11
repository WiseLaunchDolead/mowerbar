#!/bin/zsh
# Builds dist/MowerBar.app (ad hoc signed). Override BUNDLE_ID to build under your own identifier.
set -eu
ROOT="${0:A:h:h}"
cd "$ROOT"
VERSION="0.2.2"
BUNDLE_ID="${BUNDLE_ID:-io.github.wiselaunchdolead.mowerbar}"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/MowerBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MowerBar" "$APP/Contents/MacOS/MowerBar"
cp -R "$ROOT"/Resources/*.lproj "$APP/Contents/Resources/"
rm -rf "$ROOT/.build/MowerBar.iconset"
"$BIN_DIR/MowerBar" --export-icon "$ROOT/.build/MowerBar.iconset"
iconutil -c icns "$ROOT/.build/MowerBar.iconset" -o "$APP/Contents/Resources/MowerBar.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MowerBar</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>MowerBar</string>
<key>CFBundleDisplayName</key><string>MowerBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleIconFile</key><string>MowerBar</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>MIT License. Unofficial, not affiliated with Worx or Positec.</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
print "Built: $APP"
