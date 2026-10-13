#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_ROOT="$PWD"
# SwiftPM embeds its resource fallback location. Build in an anonymous path so
# this generated literal cannot expose the builder's account or clone location.
BUILD_ROOT="$(mktemp -d /tmp/samsung-menubar-build.XXXXXX)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
cp "$PROJECT_ROOT/Package.swift" "$BUILD_ROOT/Package.swift"
cp -R "$PROJECT_ROOT/Sources" "$BUILD_ROOT/Sources"
swift build --package-path "$BUILD_ROOT" --scratch-path "$BUILD_ROOT/.build" -c release \
  -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_ROOT=." \
  -Xswiftc -file-prefix-map -Xswiftc "$BUILD_ROOT=." \
  -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_ROOT=." \
  -Xswiftc -debug-prefix-map -Xswiftc "$BUILD_ROOT=." \
  -Xcc "-ffile-prefix-map=$PROJECT_ROOT=." \
  -Xcc "-ffile-prefix-map=$BUILD_ROOT=."
APP="$PROJECT_ROOT/dist/Samsung-menubar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_ROOT/.build/release/SamsungMenubar" "$APP/Contents/MacOS/SamsungMenubar"
cp -R "$BUILD_ROOT/.build/release/SamsungMenubar_SamsungMenubar.bundle" "$APP/Contents/Resources/"
strip -S "$APP/Contents/MacOS/SamsungMenubar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SamsungMenubar</string>
<key>CFBundleIdentifier</key><string>br.local.SamsungRemote</string>
<key>CFBundleName</key><string>Samsung-menubar</string>
<key>CFBundleDisplayName</key><string>Samsung-menubar</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Find and control your Samsung TV on the same Wi-Fi network.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep --sign - --identifier br.local.SamsungRemote "$APP"
printf 'App created at %s\n' "$APP"
# A rebuilt bundle gets a new signature, and macOS then cuts a running copy off the
# local network. Restart it so the new build asks for permission once.
if pgrep -x SamsungMenubar >/dev/null; then
  pkill -x SamsungMenubar; sleep 1; open "$APP"
  printf 'Restarted the running app with the new build.\n'
fi
