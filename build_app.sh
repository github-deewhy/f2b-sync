#!/bin/bash
# build_app.sh - builds "F2B Sync.app": a native single-window app with a real
# progress bar and final message.  Usage: ./build_app.sh [--install]
# Needs Xcode Command Line Tools (swiftc). Without them: ./build_app_applescript.sh
set -e
cd "$(dirname "$0")"
APP="F2B Sync.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "❌ swiftc not found. Install the tools with:  xcode-select --install"
  echo "   (or use the simpler fallback: ./build_app_applescript.sh)"
  exit 1
fi

rm -rf "$APP" build_icon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- Icon --------------------------------------------------------------------
mkdir build_icon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s             icon.png --out "build_icon.iconset/icon_${s}x${s}.png"    >/dev/null
  sips -z $((s*2)) $((s*2)) icon.png --out "build_icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build_icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build_icon.iconset

# --- Compile -----------------------------------------------------------------
echo "⚙️  Compiling…"
swiftc -O -o "$APP/Contents/MacOS/F2BSync" main.swift

cp f2b_sync.sh "$APP/Contents/Resources/f2b_sync.sh"
chmod +x "$APP/Contents/Resources/f2b_sync.sh"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>F2B Sync</string>
  <key>CFBundleDisplayName</key><string>F2B Sync</string>
  <key>CFBundleIdentifier</key><string>com.davide.f2bsync</string>
  <key>CFBundleExecutable</key><string>F2BSync</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>F2B Sync saves f2b_status.json into your Desktop project folder.</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
xattr -cr "$APP" 2>/dev/null || true
touch "$APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP"
  cp -R "$APP" "$HOME/Applications/"
  echo "✅ Installed: ~/Applications/$APP"
else
  echo "✅ Built: $(pwd)/$APP"
fi
echo "Run:  open \"$APP\"   (or drag it to the Dock)"
