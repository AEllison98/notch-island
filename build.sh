#!/bin/bash
# Builds Notch Island, signs it, and installs it to ~/Applications.
#
#   ./build.sh            build, sign, install (quits a running copy first)
#   ./build.sh --run      the same, then launch it
#   ./build.sh --release  build and sign a zip for the Releases page; installs nothing
#
# Signing: macOS remembers the permissions you grant (Music, Spotify, Calendar, Location) by the
# app's signature. A certificate signature stays the same from one build to the next; an ad-hoc
# one is a hash of the build and changes every time, so macOS would ask again after every
# rebuild. So this uses, in order:
#   1. SIGN_IDENTITY, if you set it (SIGN_IDENTITY=- forces an ad-hoc signature)
#   2. the first "Apple Development" or "Developer ID Application" certificate in your keychain
#      (a free Apple ID in Xcode > Settings > Accounts gives you an Apple Development one)
#   3. an ad-hoc signature, with a warning
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NotchIsland"
BUNDLE_ID="local.NotchIsland"
STAGE="build/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"
MODE="${1:-}"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    IDENTITY="$SIGN_IDENTITY"
elif [ "$MODE" = "--release" ]; then
    # A release is signed ad-hoc: a personal certificate would put its owner's name in every copy.
    IDENTITY="-"
else
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p; s/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
        | head -n 1)"
    if [ -z "$IDENTITY" ]; then
        IDENTITY="-"
        echo "Note: no signing certificate found, so this build is signed ad-hoc. macOS will ask for its" >&2
        echo "permissions again after every rebuild. Add a free Apple ID in Xcode > Settings > Accounts" >&2
        echo "to get an Apple Development certificate, then build again." >&2
    fi
fi

echo "==> Compiling (release, arm64)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

echo "==> Assembling $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp hooks/notch-island-hook "$STAGE/Contents/Resources/"
chmod 755 "$STAGE/Contents/Resources/notch-island-hook"

plist_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGE/Contents/Info.plist")"
if [ "$plist_id" != "$BUNDLE_ID" ]; then
    echo "Info.plist bundle id is '$plist_id', expected '$BUNDLE_ID'. Changing it makes macOS ask for every permission again." >&2
    exit 1
fi

if [ "$IDENTITY" = "-" ]; then echo "==> Signing ad-hoc"; else echo "==> Signing with: $IDENTITY"; fi
# --timestamp=none: no request to Apple's timestamp server. Nothing leaves the Mac.
codesign --force --timestamp=none --sign "$IDENTITY" "$STAGE"
codesign --verify --strict "$STAGE"

if [ "$MODE" = "--release" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/Contents/Info.plist")"
    ZIP="build/$APP_NAME-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$STAGE" "$ZIP"
    echo "==> Release: $ZIP"
    shasum -a 256 "$ZIP"
    exit 0
fi

echo "==> Installing to $DEST"
if pgrep -x "$APP_NAME" >/dev/null; then
    pkill -x "$APP_NAME" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.2; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
codesign --verify --strict "$DEST"

if [ "$MODE" = "--run" ]; then
    echo "==> Launching"
    open "$DEST"
fi
echo "Done."
