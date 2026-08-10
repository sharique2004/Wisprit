#!/bin/zsh
# make_dmg.sh — build, sign, notarize and staple the shippable Wisprit.dmg.
#
#   ./scripts/make_dmg.sh [--version X.Y.Z] [--skip-notarize]
#
# Pipeline (mirrors MeetingScribe's proven tools/build_dmg_bundle.sh):
#   1. scripts/build_app.sh → dist/stage/Wisprit.app (never /Applications)
#   2. Re-sign for release: nested WispritIM.app first (entitlements
#      preserved), then the outer app — both with hardened runtime and a
#      secure timestamp, which notarization requires and the dev build omits.
#   3. Notarize the app, staple.
#   4. Drag-to-install DMG (UDZO, /Applications symlink), sign, notarize,
#      staple, Gatekeeper-assess.
#   5. dist/Wisprit.dmg + dist/Wisprit.dmg.sha256 (the website publishes both).
#
# Credentials: the keychain profile below was created once with
#   xcrun notarytool store-credentials meetingscribe-notary \
#       --apple-id khatrisharique7@gmail.com --team-id 5VJ8KXLF45
# and is shared with MeetingScribe — same team, same Developer ID cert.
set -e
set -u

REPO_DIR="${0:A:h:h}"
PROFILE="${WISPRIT_NOTARY_PROFILE:-meetingscribe-notary}"
SIGN_ID="${WISPRIT_SIGN_IDENTITY:-Developer ID Application: Sharique Khatri (5VJ8KXLF45)}"
VERSION="${WISPRIT_VERSION:-2.0.0}"
NOTARIZE=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --skip-notarize) NOTARIZE=0; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

STAGE="$REPO_DIR/dist/stage"
APP="$STAGE/Wisprit.app"
DMG="$REPO_DIR/dist/Wisprit.dmg"
IM="$APP/Contents/Library/InputMethods/WispritIM.app"

# --- 1. build the bundle ----------------------------------------------------
rm -rf "$STAGE"; mkdir -p "$STAGE"
WISPRIT_VERSION="$VERSION" "$REPO_DIR/scripts/build_app.sh" --out "$STAGE"

# --- 2. release signing -----------------------------------------------------
# Nested bundle first; never --deep (it would clobber WispritIM's sandbox +
# mach-port entitlements and the IM would silently never receive a client).
echo "Release-signing (hardened runtime + timestamp)…"
if [[ -d "$IM" ]]; then
    codesign --force --options runtime --timestamp \
        --preserve-metadata=entitlements --sign "$SIGN_ID" "$IM"
fi
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "  signed: $SIGN_ID"

submit_and_wait() {
    # $1 = file to submit. notarytool exits non-zero on Invalid, so run it
    # status-blind and decide from the transcript; caffeinate keeps the long
    # poll (and the keychain) alive through display sleep.
    local sub="$1" out id
    out="$(mktemp -t wisprit-notary).txt"
    echo "Submitting $(basename "$sub") to Apple notary service (waits for the verdict)…"
    set +e
    caffeinate -ims xcrun notarytool submit "$sub" \
        --keychain-profile "$PROFILE" --wait 2>&1 | tee "$out"
    set -e
    if ! grep -q "status: Accepted" "$out"; then
        id="$(awk '/^[[:space:]]*id: /{print $2; exit}' "$out")"
        echo "ERROR: notarization not accepted." >&2
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
        exit 1
    fi
}

# --- 3. notarize the app ----------------------------------------------------
# Submit a zip, staple the .app itself (the zip is only a transport).
if [[ $NOTARIZE -eq 1 ]]; then
    ZIP="$(mktemp -d)/Wisprit.app.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    submit_and_wait "$ZIP"
    rm -f "$ZIP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type exec "$APP" || { echo "ERROR: Gatekeeper rejects the app" >&2; exit 1; }
    echo "  Gatekeeper: app accepted"
fi

# --- 4. the disk image ------------------------------------------------------
ln -shf /Applications "$STAGE/Applications"
mkdir -p "$REPO_DIR/dist"; rm -f "$DMG"
echo "Compressing $DMG…"
hdiutil create -volname "Wisprit" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -f "$STAGE/Applications"
codesign --force --sign "$SIGN_ID" "$DMG"

if [[ $NOTARIZE -eq 1 ]]; then
    submit_and_wait "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature "$DMG" \
        || { echo "ERROR: Gatekeeper rejects the DMG" >&2; exit 1; }
    echo "  Gatekeeper: DMG accepted"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Done: $DMG ($(du -h "$DMG" | cut -f1), version $VERSION)"
