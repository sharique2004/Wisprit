#!/bin/zsh
# build_im.sh — build WispritIM.app, the palette input method that puts your
# words in the field while you speak.
#
# The bundle is assembled from ONE source of truth: the binary prints its own
# Info.plist and entitlements (--emit-info-plist / --emit-entitlements), so the
# connection-name rule that a sandboxed input method lives or dies by cannot
# drift between the plist and the code that opens the Mach service.
#
#   ./scripts/build_im.sh                → ./dist/WispritIM.app   (shipping shape)
#   ./scripts/build_im.sh --visible      → also appears in the Input menu, so you
#                                          can select it by hand for the spike
#   ./scripts/build_im.sh --out DIR      → assemble into DIR instead of ./dist
#   ./scripts/build_im.sh --debug        → debug build
#   ./scripts/build_im.sh --no-sandbox   → sign without App Sandbox (spike only)
#
# This script never installs or enables anything. Putting the bundle into
# ~/Library/Input Methods and calling TISEnableInputSource is a change to your
# system's input configuration: Wisprit.app does it during onboarding, with your
# permission, exactly once.
#
# Signing is ad-hoc for development. Developer ID + notarization is Phase 4 —
# and note that this bundle is *why* the streaming SKU cannot ship through the
# Mac App Store (Guideline 2.4.5 forbids installing into shared locations, and
# TISRegisterInputSource accepts no other location).

set -e
set -u

REPO_DIR="${0:A:h:h}"
VERSION="2.0.0-dev"
BUNDLE_ID="com.wisprit.im"
CONFIGURATION="release"
OUT_DIR="$REPO_DIR/dist"
SANDBOX_FLAG=""
VISIBLE=0
SCRATCH="${WISPRIT_SCRATCH_PATH:-/tmp/wisprit-build-WispritIM}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT_DIR="$2"; shift 2 ;;
        --debug) CONFIGURATION="debug"; shift ;;
        --no-sandbox) SANDBOX_FLAG="--no-sandbox"; shift ;;
        --visible) VISIBLE=1; shift ;;
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

APP="$OUT_DIR/WispritIM.app"
CONTENTS="$APP/Contents"

# --- build ------------------------------------------------------------------
echo "Building WispritIM ($CONFIGURATION)…"
swift build --product WispritIM --configuration "$CONFIGURATION" \
    --package-path "$REPO_DIR" --scratch-path "$SCRATCH"
BIN_PATH="$(swift build --product WispritIM --configuration "$CONFIGURATION" \
    --package-path "$REPO_DIR" --scratch-path "$SCRATCH" --show-bin-path)"
BINARY="$BIN_PATH/WispritIM"
[[ -x "$BINARY" ]] || { echo "build produced no executable at $BINARY" >&2; exit 1 }

# --- assemble ---------------------------------------------------------------
echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/WispritIM"
chmod +x "$CONTENTS/MacOS/WispritIM"

# --- Info.plist + entitlements, straight from the binary --------------------
"$BINARY" --emit-info-plist --bundle-id "$BUNDLE_ID" --version-string "$VERSION" \
    > "$CONTENTS/Info.plist"

if [[ $VISIBLE -eq 1 ]]; then
    # Spike / manual-test build: drop ComponentInvisibleInSystemUI so the source
    # shows up in the Input menu and you can select it by hand. The shipping
    # bundle stays invisible, exactly like Apple's own DictationIM.
    /usr/libexec/PlistBuddy -c "Delete :ComponentInvisibleInSystemUI" \
        "$CONTENTS/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :ComponentInputModeDict:tsInputModeListKey:${BUNDLE_ID}.dictation:tsInputModeIsVisibleKey true" \
        "$CONTENTS/Info.plist" 2>/dev/null || true
    echo "  visibility: SELECTABLE from the Input menu (spike build)"
else
    echo "  visibility: invisible in system UI (shipping shape)"
fi

mkdir -p "$CONTENTS/Resources"
cp "$REPO_DIR/packaging/PrivacyInfo.xcprivacy" "$CONTENTS/Resources/PrivacyInfo.xcprivacy"

plutil -lint "$CONTENTS/Info.plist" >/dev/null || {
    echo "generated Info.plist is not a valid property list" >&2; exit 1
}

CONNECTION="$(/usr/libexec/PlistBuddy -c 'Print :InputMethodConnectionName' "$CONTENTS/Info.plist")"
if [[ "$CONNECTION" != "${BUNDLE_ID}_Connection" ]]; then
    echo "FATAL: InputMethodConnectionName is \"$CONNECTION\", must be \"${BUNDLE_ID}_Connection\"" >&2
    echo "       (a sandboxed input method registers no connection otherwise, and" >&2
    echo "        then silently never receives a client)" >&2
    exit 1
fi

ENTITLEMENTS="$(mktemp -t wisprit-im-entitlements).plist"
"$BINARY" --emit-entitlements --bundle-id "$BUNDLE_ID" ${SANDBOX_FLAG:+$SANDBOX_FLAG} \
    > "$ENTITLEMENTS"

# --- icon (optional, shares the app's) --------------------------------------
if [[ -f "$REPO_DIR/dist/Wisprit.app/Contents/Resources/Wisprit.icns" ]]; then
    cp "$REPO_DIR/dist/Wisprit.app/Contents/Resources/Wisprit.icns" \
       "$CONTENTS/Resources/WispritIM.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string WispritIM" \
        "$CONTENTS/Info.plist" 2>/dev/null || true
fi

# --- sign -------------------------------------------------------------------
# Ad-hoc signing gives the bundle a stable identity so the input source keeps
# working across rebuilds instead of looking like a new, unknown input method.
if codesign --force --sign - --entitlements "$ENTITLEMENTS" \
        --timestamp=none "$APP" 2>/dev/null; then
    echo "  signed: ad-hoc${SANDBOX_FLAG:+ (sandbox disabled)}"
else
    echo "  sign: FAILED — a sandboxed input method will not run unsigned" >&2
    exit 1
fi
rm -f "$ENTITLEMENTS"

cat <<DONE

Built $APP

  Inspect it:   $CONTENTS/MacOS/WispritIM --status
  Wire version: $("$CONTENTS/MacOS/WispritIM" --version)

Nothing has been installed or enabled. To try it by hand:

  1. Install + register (writes to ~/Library/Input Methods):
       WISPRIT_MANUAL_IM=1 WISPRIT_MANUAL_IM_REGISTER=1 \\
         swift test --filter WispritIMTests.ManualIMTests/testInstallAndRegister \\
         --scratch-path $SCRATCH

  2. Enable it yourself: System Settings ▸ Keyboard ▸ Input Sources ▸ Edit… ▸ +
     (or approve the "wants to activate the third-party input method" dialog).

  3. Open TextEdit, click in the document, pick "Wisprit Dictation" from the
     Input menu, then:
       WISPRIT_MANUAL_IM=1 swift test \\
         --filter WispritIMTests.ManualIMTests/testLoopback \\
         --scratch-path $SCRATCH

Built with --visible? The source appears in the Input menu. The shipping bundle
is invisible there and Wisprit selects it for you.
DONE
