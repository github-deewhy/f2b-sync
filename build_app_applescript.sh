#!/bin/bash
# build_app.sh - builds "F2B Sync.app": a native applet with a live progress
# window, result dialog and icon.  Usage: ./build_app.sh [--install]
set -e
cd "$(dirname "$0")"
APP="F2B Sync.app"
rm -rf "$APP" build_icon.iconset applet_src.applescript

# --- Icon: icon.png -> AppIcon.icns -----------------------------------------
mkdir build_icon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s             icon.png --out "build_icon.iconset/icon_${s}x${s}.png"    >/dev/null
  sips -z $((s*2)) $((s*2)) icon.png --out "build_icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build_icon.iconset -o AppIcon.icns
rm -rf build_icon.iconset

# --- Applet source -----------------------------------------------------------
cat > applet_src.applescript <<'AS'
on run
	set sh to quoted form of (POSIX path of (path to resource "f2b_sync.sh"))
	set outF to "/tmp/f2b_sync_app.out"
	set rcF to "/tmp/f2b_sync_app.rc"

	do shell script "rm -f " & rcF & "; : > " & outF
	do shell script "( " & sh & " > " & outF & " 2>&1 ; echo $? > " & rcF & " ) > /dev/null 2>&1 &"

	set progress total steps to 0 -- indeterminate bar
	set progress description to "Syncing f2b_status.json…"
	set progress additional description to "Connecting to server…"

	set rc to "1"
	repeat
		delay 0.4
		try
			set lastLine to do shell script "tail -n 1 " & outF
			if lastLine is not "" then set progress additional description to lastLine
		end try
		try
			set rc to do shell script "cat " & rcF
			exit repeat
		end try
	end repeat

	set resultText to do shell script "tail -n 3 " & outF & " | cut -c1-200"
	if rc is "0" then
		display notification "Synced successfully" with title "F2B Sync"
		display dialog resultText with title "F2B Sync" buttons {"OK"} default button 1 with icon note giving up after 8
	else
		display dialog resultText & return & return & "Log: ~/Library/Logs/f2b_sync.log" with title "F2B Sync – FAILED" buttons {"OK"} default button 1 with icon stop
	end if
end run
AS

osacompile -o "$APP" applet_src.applescript
cp f2b_sync.sh "$APP/Contents/Resources/f2b_sync.sh"
chmod +x "$APP/Contents/Resources/f2b_sync.sh"

# --- Custom icon -------------------------------------------------------------
cp AppIcon.icns "$APP/Contents/Resources/applet.icns"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
PL="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$PL" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile applet" "$PL" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleName F2B Sync" "$PL" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.davide.f2bsync" "$PL" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.davide.f2bsync" "$PL" 2>/dev/null || true
rm -f AppIcon.icns applet_src.applescript

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
