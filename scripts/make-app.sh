#!/bin/zsh
# Build a release SerialTerm.app in ./build. Ad-hoc signed: fine for this Mac;
# use a Developer ID identity and notarization to give it to others.
set -euo pipefail

cd "$(dirname "$0")/.."
# Use Xcode even if xcode-select still points at the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* \
      && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"

swift build -c release --product SerialTerm
BIN="$(swift build -c release --show-bin-path)/SerialTerm"

APP=build/SerialTerm.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SerialTerm"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SerialTerm</string>
    <key>CFBundleDisplayName</key><string>SerialTerm</string>
    <key>CFBundleIdentifier</key><string>com.example.SerialTerm</string>
    <key>CFBundleExecutable</key><string>SerialTerm</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
