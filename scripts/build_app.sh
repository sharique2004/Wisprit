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
#   ./scripts/build_app.sh --no-im      → skip the embedded input method
#
# The palette input method ships INSIDE the app, at
# Contents/Library/InputMethods/WispritIM.app. App Store Guideline 2.4.5(ii)
# wants a self-contained bundle, and this is also the only sane update story:
# one download, one signature, one version. It is NOT installed or enabled here.
# Wisprit copies it to ~/Library/Input Methods and registers it during
# onboarding, from the "Enable Live Typing…" menu item, with the user watching —
# `TISRegisterInputSource` accepts no other location, which is precisely why the
# streaming SKU cannot ship through the Mac App Store.
#
# Signing is ad-hoc for development. Developer ID signing + notarization is
# Phase 4; see docs/SWIFT-INTERFACES.md.

set -e
set -u

REPO_DIR="${0:A:h:h}"
VERSION="${WISPRIT_VERSION:-2.0.0-dev}"
BUNDLE_ID="com.wisprit.app"
CONFIGURATION="release"
OUT_DIR="$REPO_DIR/dist"
INSTALL=0
EMBED_IM=1
SCRATCH="${WISPRIT_SCRATCH_PATH:-/tmp/wisprit-build-WispritMac}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) INSTALL=1; shift ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --debug) CONFIGURATION="debug"; shift ;;
        --no-im) EMBED_IM=0; shift ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
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
# Preferred path: compile packaging/Wisprit.icon (the Icon Composer source)
# with actool. Assets.car is the live Liquid Glass icon macOS 26 renders with
# the manifest's materials; Wisprit.icns is Apple's flattened fallback
# rendition. CFBundleIconName is what makes the system read Assets.car — the
# icns alone would draw flat. make_icon.swift stays as the no-Xcode fallback.
ICON_TMP="$(mktemp -d)"
ICONSET="$(mktemp -d)/Wisprit.iconset"
if xcrun actool "$REPO_DIR/packaging/Wisprit.icon" --compile "$ICON_TMP" \
       --app-icon Wisprit --include-all-app-icons \
       --output-partial-info-plist "$ICON_TMP/partial.plist" \
       --platform macosx --minimum-deployment-target 26.0 \
       --output-format human-readable-text >/dev/null 2>&1 && \
   [[ -f "$ICON_TMP/Assets.car" && -f "$ICON_TMP/Wisprit.icns" ]]; then
    cp "$ICON_TMP/Assets.car" "$CONTENTS/Resources/Assets.car"
    cp "$ICON_TMP/Wisprit.icns" "$CONTENTS/Resources/Wisprit.icns"
    ICON_KEY='<key>CFBundleIconFile</key><string>Wisprit</string><key>CFBundleIconName</key><string>Wisprit</string>'
    echo "  icon: compiled Wisprit.icon (Liquid Glass + icns fallback)"
elif swift "$REPO_DIR/packaging/make_icon.swift" "$ICONSET" >/dev/null 2>&1 && \
   iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/Wisprit.icns" 2>/dev/null; then
    ICON_KEY='<key>CFBundleIconFile</key><string>Wisprit</string>'
    echo "  icon: built Wisprit.icns (flat fallback — actool unavailable)"
else
    ICON_KEY=''
    echo "  icon: skipped (actool/swift/iconutil unavailable)"
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
    <!-- Bundled display face (SIL OFL) — Theme.resolveSerif() falls back to the
         system serif when the family is missing, so this key is additive. -->
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict>
</plist>
PLIST

# --- fonts ------------------------------------------------------------------
# Instrument Serif (SIL OFL 1.1) — the design's display face for numerals.
mkdir -p "$CONTENTS/Resources/Fonts"
cp "$REPO_DIR"/packaging/fonts/InstrumentSerif-*.ttf "$CONTENTS/Resources/Fonts/" 2>/dev/null \
    && cp "$REPO_DIR/packaging/fonts/OFL.txt" "$CONTENTS/Resources/Fonts/" \
    && echo "  fonts: embedded Instrument Serif (OFL)" \
    || echo "  fonts: skipped (packaging/fonts missing) — system serif fallback"

# --- embed the palette input method -----------------------------------------
# Built and signed FIRST, with its own sandbox entitlements, because a nested
# bundle has to be sealed before the bundle that contains it. (This is also why
# the outer signature below is not --deep: a deep re-sign would overwrite
# WispritIM's entitlements with the app's, and a sandboxed input method with no
# mach-register exception silently never receives a client.)
if [[ $EMBED_IM -eq 1 ]]; then
    # --- Privacy manifest --------------------------------------------------------
mkdir -p "$CONTENTS/Resources"
cp "$REPO_DIR/packaging/PrivacyInfo.xcprivacy" "$CONTENTS/Resources/PrivacyInfo.xcprivacy"

IM_DIR="$CONTENTS/Library/InputMethods"
    mkdir -p "$IM_DIR"
    IM_FLAGS=()
    [[ "$CONFIGURATION" == "debug" ]] && IM_FLAGS+=(--debug)
    if WISPRIT_SCRATCH_PATH="$SCRATCH" "$REPO_DIR/scripts/build_im.sh" \
            --out "$IM_DIR" --version "$VERSION" "${IM_FLAGS[@]}" >/dev/null; then
        echo "  input method: embedded at Contents/Library/InputMethods/WispritIM.app"
    else
        echo "  input method: BUILD FAILED — live typing will be unavailable" >&2
        rm -rf "$IM_DIR"
    fi
fi

# --- sign -------------------------------------------------------------------
# Developer ID when available: a REAL certificate keys TCC to team+bundle id,
# so grants survive every rebuild. Ad-hoc (cdhash-keyed) proved NOT to: each
# rebuild silently voided Input Monitoring and the user relived onboarding
# ("quit and reopen spam", 2026-08-05). Override with WISPRIT_SIGN_IDENTITY.
SIGN_ID="${WISPRIT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' | sed 's/.*"\(.*\)".*/\1/')}"
if [[ -n "$SIGN_ID" ]]; then
    if [[ -d "$IM_DIR/WispritIM.app" ]]; then
        # Nested bundle first, keeping its sandbox/mach-port entitlements.
        codesign --force --preserve-metadata=entitlements --sign "$SIGN_ID" \
            "$IM_DIR/WispritIM.app"
    fi
    codesign --force --sign "$SIGN_ID" "$APP"
    echo "  signed: $SIGN_ID"
elif codesign --force --sign - "$APP" 2>/dev/null; then
    echo "  signed: ad-hoc (no Developer ID found — grants reset on every rebuild)"
else
    echo "  sign: SKIPPED (codesign unavailable) — grants may not stick" >&2
fi
codesign --verify --deep --strict "$APP" 2>/dev/null \
    || echo "  verify: signature is not deep-valid (nested bundle?)" >&2

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

# --- install (opt-in) -------------------------------------------------------
if [[ $INSTALL -eq 1 ]]; then
    echo "Installing to /Applications/Wisprit.app"
    rm -rf /Applications/Wisprit.app
    # ditto preserves the signature; never re-sign after the copy.
    ditto "$APP" /Applications/Wisprit.app
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

Live in-field streaming ships inside the bundle but is NOT installed: choose
"Enable Live Typing…" from the Wisprit menu to copy the input method into
~/Library/Input Methods, register it, and approve the one activation dialog.
DONE
