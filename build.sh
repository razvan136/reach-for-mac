#!/bin/bash
# Build the developer app, install it locally, or build both Mac architectures.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
if [ "$#" -gt 1 ] || { [ -n "$MODE" ] && [ "$MODE" != "--install" ] && [ "$MODE" != "--universal" ]; }; then
    echo "Usage: ./build.sh [--install | --universal]" >&2
    exit 2
fi

BUILD_DIR="${REACH_BUILD_DIR:-${AIRWAVE_BUILD_DIR:-build}}"
BUILT_APP="$BUILD_DIR/Reach.app"
DESTINATION="/Applications/Reach.app"
mkdir -p "$BUILD_DIR"
STAGE="$(mktemp -d "$BUILD_DIR/.reach-build.XXXXXX")"
INSTALL_STAGE=""
clean_stage() {
    local directory="$1" target="$2"
    local backup="$directory/previous.app"
    if [ ! -e "$target" ] && [ ! -L "$target" ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
        if ! mv "$backup" "$target"; then
            printf 'Previous bundle is at %s\n' "$backup" >&2
            return
        fi
    fi
    rm -rf "$directory"
}
cleanup() {
    clean_stage "$STAGE" "$BUILT_APP"
    if [ -n "$INSTALL_STAGE" ]; then clean_stage "$INSTALL_STAGE" "$DESTINATION"; fi
}
trap cleanup EXIT

APP="$STAGE/Reach.app"
SDK="$(xcrun --show-sdk-path)"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find Sources -name '*.swift' | sort)

compile() {
    local architecture="$1"
    local output="$2"
    local compiler=(swiftc)
    if [ "$MODE" = "--universal" ]; then
        compiler+=(-module-cache-path "$PWD/build/.modules")
    fi
    echo "▸ compiling $architecture"
    "${compiler[@]}" -O -whole-module-optimization \
        -target "$architecture-apple-macosx14.0" \
        -sdk "$SDK" \
        -framework AppKit -framework AVFoundation -framework Vision \
        -framework CoreImage -framework ApplicationServices \
        "${SOURCES[@]}" -o "$output"
}

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "$MODE" = "--universal" ]; then
    compile arm64 "$STAGE/Reach-arm64"
    compile x86_64 "$STAGE/Reach-x86_64"
    xcrun lipo -create "$STAGE/Reach-arm64" "$STAGE/Reach-x86_64" \
        -output "$APP/Contents/MacOS/Reach"
    ARCHITECTURES=" $(xcrun lipo -archs "$APP/Contents/MacOS/Reach") "
    if [[ "$ARCHITECTURES" != *" arm64 "* || "$ARCHITECTURES" != *" x86_64 "* ]]; then
        echo "Expected both arm64 and x86_64 in the app executable." >&2
        exit 1
    fi
else
    compile "$(uname -m)" "$APP/Contents/MacOS/Reach"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | sed -n '1p')}"
IDENTITY="${IDENTITY:--}"
if [[ "$IDENTITY" == "Developer ID Application: "* ]]; then
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
else
    if [ "$IDENTITY" = "-" ]; then echo "▸ ad-hoc signing"; fi
    codesign --force --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

replace_app() {
    local source="$1" target="$2" backup="$3"
    if [ -e "$target" ] || [ -L "$target" ]; then mv "$target" "$backup"; fi
    mv "$source" "$target"
}

replace_app "$APP" "$BUILT_APP" "$STAGE/previous.app"
echo "✓ Built $BUILT_APP"
if [ "$MODE" = "--install" ]; then
    if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
        if [ -L "$DESTINATION" ] || [ "$(plutil -extract CFBundleIdentifier raw "$DESTINATION/Contents/Info.plist" 2>/dev/null)" != "com.razgogo.airwave" ]; then
            echo "An unrelated item is already at $DESTINATION." >&2
            exit 1
        fi
    fi
    INSTALL_STAGE="$(mktemp -d /Applications/.reach-install.XXXXXX)"
    ditto "$BUILT_APP" "$INSTALL_STAGE/Reach.app"
    codesign --verify --strict "$INSTALL_STAGE/Reach.app"
    replace_app "$INSTALL_STAGE/Reach.app" "$DESTINATION" "$INSTALL_STAGE/previous.app"
    echo "✓ Installed $DESTINATION"
fi
