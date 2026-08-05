#!/bin/zsh
# build_app.sh — release-build the native Wisprit and assemble Wisprit.app.
#
# Unlike the Python era's packaging/make_app.sh, the bundle is NOT a shell
# wrapper around an interpreter: Contents/MacOS/Wisprit is the real compiled
# executable, so the TCC grants attach to the bundle itself and survive.
#
#   ./scripts/build_app.sh              → ./dist/Wisprit.app   (default)
#   ./scripts/build_app.sh --install    → also copy to /Applications
#   ./scripts/build_app.sh --out DIR    → assemble into DIR instead of ./dist
#   ./scripts/build_app.sh --debug      → skip the release build, use debug
#
# Signing is ad-hoc for development. Developer ID signing + notarization is
# Phase 4; see docs/SWIFT-INTERFACES.md.

set -e
set -u

REPO_DIR="${0:A:h:h}"
VERSION="2.0.0-dev"
BUNDLE_ID="com.wisprit.app"
CONFIGURATION="release"
OUT_DIR="$REPO_DIR/dist"
INSTALL=0
SCRATCH="${WISPRIT_SCRATCH_PATH:-/tmp/wisprit-build-WispritMac}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) INSTALL=1; shift ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --debug) CONFIGURATION="debug"; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

APP="$OUT_DIR/Wisprit.app"
CONTENTS="$APP/Contents"

# --- build ------------------------------------------------------------------
echo "Building WispritMac ($CONFIGURATION)…"
swift build --product WispritMac --configuration "$CONFIGURATION" \
    --package-path "$REPO_DIR" --scratch-path "$SCRATCH"
BINARY="$(swift build --product WispritMac --configuration "$CONFIGURATION" \
    --package-path "$REPO_DIR" --scratch-path "$SCRATCH" --show-bin-path)/WispritMac"
[[ -x "$BINARY" ]] || { echo "build produced no executable at $BINARY" >&2; exit 1 }

# --- assemble ---------------------------------------------------------------
echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/Wisprit"
chmod +x "$CONTENTS/MacOS/Wisprit"

# --- icon (optional) --------------------------------------------------------
ICONSET="$(mktemp -d)/Wisprit.iconset"
if swift "$REPO_DIR/packaging/make_icon.swift" "$ICONSET" >/dev/null 2>&1 && \
   iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/Wisprit.icns" 2>/dev/null; then
    ICON_KEY='<key>CFBundleIconFile</key><string>Wisprit</string>'
    echo "  icon: built Wisprit.icns"
else
    ICON_KEY=''
    echo "  icon: skipped (swift/iconutil unavailable)"
fi

# --- Info.plist -------------------------------------------------------------
# The usage strings are what macOS shows in the permission prompts, so they say
# exactly what happens and nothing more: audio never leaves the machine and is
# never written to disk.
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Wisprit</string>
    <key>CFBundleDisplayName</key><string>Wisprit</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Wisprit</string>
    $ICON_KEY
    <!-- Menu-bar agent: no Dock icon, no main window. -->
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Wisprit records only while you hold the dictation key. The audio is transcribed on this Mac and is never uploaded or saved to disk.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Wisprit uses Apple's on-device speech recognition to turn what you say into text. Nothing is sent to a server.</string>
</dict>
</plist>
PLIST

# --- sign -------------------------------------------------------------------
# Ad-hoc signing gives the bundle a STABLE identity. Without it, TCC can treat
# each rebuild as a new app and silently drop the Accessibility / Input
# Monitoring grants. Re-running this script re-signs with the same identity.
if codesign --force --deep --sign - "$APP" 2>/dev/null; then
    echo "  signed: ad-hoc"
else
    echo "  sign: SKIPPED (codesign unavailable) — grants may not stick" >&2
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

# --- install (opt-in) -------------------------------------------------------
if [[ $INSTALL -eq 1 ]]; then
    echo "Installing to /Applications/Wisprit.app"
    rm -rf /Applications/Wisprit.app
    cp -R "$APP" /Applications/Wisprit.app
    codesign --force --deep --sign - /Applications/Wisprit.app 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f /Applications/Wisprit.app 2>/dev/null || true
    APP=/Applications/Wisprit.app
fi

cat <<DONE

Built $APP

  Check it:   $APP/Contents/MacOS/Wisprit doctor
  Run it:     open $APP

First launch needs three grants, each to THIS bundle (System Settings ▸
Privacy & Security): Microphone, Accessibility, Input Monitoring. Rebuilding
into a different path creates a different identity — re-grant, or use
--install so the path stays /Applications/Wisprit.app.
DONE
