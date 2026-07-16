#!/bin/zsh
# make_app.sh — build Wisprit.app, a double-clickable launcher for the app.
#
# The bundle is a thin wrapper: its executable just runs the MeetingScribe venv
# python on `wisprit`, so it reuses the interpreter that already holds the TCC
# grants. Produces /Applications/Wisprit.app by default (override with $1).
#
#   ./packaging/make_app.sh [/path/to/install/dir]

set -e
set -u

REPO_DIR="${0:A:h:h}"                 # repo root (this script lives in packaging/)
PY="$HOME/.meetingscribe/venv/bin/python"
INSTALL_DIR="${1:-/Applications}"
APP="$INSTALL_DIR/Wisprit.app"
CONTENTS="$APP/Contents"

echo "Building $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# --- icon -------------------------------------------------------------------
ICONSET="$(mktemp -d)/Wisprit.iconset"
if swift "$REPO_DIR/packaging/make_icon.swift" "$ICONSET" >/dev/null 2>&1 && \
   iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/Wisprit.icns" 2>/dev/null; then
    ICON_KEY='<key>CFBundleIconFile</key><string>Wisprit</string>'
    echo "  icon: built Wisprit.icns"
else
    ICON_KEY=''
    echo "  icon: skipped (using default) — swift/iconutil unavailable"
fi

# --- launcher executable ----------------------------------------------------
cat > "$CONTENTS/MacOS/Wisprit" <<LAUNCH
#!/bin/zsh
# Launches Wisprit under the venv python that holds the TCC grants.
cd "$REPO_DIR"
exec "$PY" -m wisprit
LAUNCH
chmod +x "$CONTENTS/MacOS/Wisprit"

# --- Info.plist -------------------------------------------------------------
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Wisprit</string>
    <key>CFBundleDisplayName</key><string>Wisprit</string>
    <key>CFBundleIdentifier</key><string>com.wisprit.app</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Wisprit</string>
    $ICON_KEY
    <!-- Menu-bar agent: no persistent Dock icon while running. -->
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Wisprit transcribes your speech on-device.</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict>
</plist>
PLIST

# Ad-hoc code-sign so the bundle has a STABLE identity — otherwise every launch
# can look like a new app to TCC and silently drop the Accessibility / Input
# Monitoring grants. (Re-running this script re-signs with the same identity.)
codesign --force --deep --sign - "$APP" 2>/dev/null \
    && echo "  signed: ad-hoc" || echo "  sign: skipped (codesign unavailable)"

# Nudge LaunchServices to pick up the new bundle + icon.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

echo "Done. Double-click $APP (or drag it to your Dock)."
