#!/bin/bash
# Sign, notarize, and package a public download using a local Keychain profile.
set -euo pipefail
cd "$(dirname "$0")"

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "Usage: ./release.sh NOTARY_KEYCHAIN_PROFILE" >&2
    exit 2
fi
PROFILE="$1"
IDENTITIES="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')"
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    if [ -z "$IDENTITIES" ]; then
        echo "A Developer ID Application certificate and its private key are required in your Keychain." >&2
        exit 1
    fi
    if [ "$(printf '%s\n' "$IDENTITIES" | wc -l | tr -d ' ')" -ne 1 ]; then
        echo "Set CODESIGN_IDENTITY to the full name of the Developer ID Application certificate to use." >&2
        exit 1
    fi
    IDENTITY="$IDENTITIES"
fi
if ! printf '%s\n' "$IDENTITIES" | grep -Fxq -- "$IDENTITY"; then
    echo "CODESIGN_IDENTITY must match an available Developer ID Application signing identity." >&2
    exit 1
fi

xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
RELEASE_DIR="$PWD/build/release"
mkdir -p "$RELEASE_DIR"
ARCHIVE="$RELEASE_DIR/Reach-for-Mac-$VERSION.zip"
if [ -e "$ARCHIVE" ]; then
    echo "A download already exists for this version. Bump the version before publishing another build." >&2
    exit 1
fi
STAGE="$(mktemp -d "$RELEASE_DIR/.reach-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Reach.app"

REACH_BUILD_DIR="$STAGE" CODESIGN_IDENTITY="$IDENTITY" ./build.sh --universal
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/submission.zip"
RESPONSE="$RELEASE_DIR/Reach-$VERSION-notary-response.json"
LOG="$RELEASE_DIR/Reach-$VERSION-notary-log.json"
if ! xcrun notarytool submit "$STAGE/submission.zip" --keychain-profile "$PROFILE" \
    --wait --output-format json > "$RESPONSE"; then
    if SUBMISSION="$(plutil -extract id raw "$RESPONSE" 2>/dev/null)"; then
        xcrun notarytool log "$SUBMISSION" "$LOG" --keychain-profile "$PROFILE" || true
    fi
    echo "Notarization submission stopped. See $RESPONSE and any error above." >&2
    exit 1
fi
SUBMISSION="$(plutil -extract id raw "$RESPONSE")"
STATUS="$(plutil -extract status raw "$RESPONSE")"
xcrun notarytool log "$SUBMISSION" "$LOG" --keychain-profile "$PROFILE"
if [ "$STATUS" != "Accepted" ]; then
    echo "Apple returned $STATUS. See $LOG." >&2
    exit 1
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/download.zip"
ditto -x -k "$STAGE/download.zip" "$STAGE/check"
CHECK_APP="$STAGE/check/Reach.app"
codesign --verify --strict "$CHECK_APP"
xcrun stapler validate "$CHECK_APP"
if command -v syspolicy_check >/dev/null; then
    syspolicy_check distribution "$CHECK_APP"
else
    spctl --assess --type execute --verbose "$CHECK_APP"
fi
mv "$STAGE/download.zip" "$ARCHIVE"
echo "✓ Notarized download: $ARCHIVE"
echo "Notarization log: $LOG"
