#!/bin/bash
# Extract Audiveris.app (the second recognition engine) for embedding.
#
#   ./Tools/fetch_audiveris.sh [arm64|x86_64]     (defaults to this machine)
#
# Audiveris ships official macOS builds with a bundled JRE, so nothing is needed
# from the recipient's machine. Its .dmg carries a click-through of the AGPL,
# which blocks a scripted mount, so the image is converted to a plain one first
# and the app is copied out of that.
set -euo pipefail

AUDIVERIS_VERSION="5.11.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/build/cache"

ARCH="${1:-$(uname -m)}"
case "$ARCH" in
    arm64)  SUFFIX="macosx-arm64" ;;
    x86_64) SUFFIX="macosx-x86_64" ;;
    *) echo "error: unknown architecture '$ARCH' (expected arm64 or x86_64)" >&2; exit 1 ;;
esac

TARGET="$ROOT/build/audiveris-$ARCH"
DMG="Audiveris-${AUDIVERIS_VERSION}-${SUFFIX}.dmg"
URL="https://github.com/Audiveris/audiveris/releases/download/${AUDIVERIS_VERSION}/${DMG}"

mkdir -p "$CACHE"
if [ ! -f "$CACHE/$DMG" ]; then
    echo "==> downloading $DMG"
    curl -fL --progress-bar "$URL" -o "$CACHE/$DMG.part"
    mv "$CACHE/$DMG.part" "$CACHE/$DMG"
else
    echo "==> using cached $DMG"
fi

WORK="$(mktemp -d)"
trap 'hdiutil detach "$WORK/mnt" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "==> extracting Audiveris.app"
# The published image has a licence agreement attached; converting sidesteps the
# interactive prompt that would otherwise block a scripted build.
hdiutil convert "$CACHE/$DMG" -format UDTO -o "$WORK/plain" -quiet
mkdir -p "$WORK/mnt"
hdiutil attach "$WORK/plain.cdr" -mountpoint "$WORK/mnt" -nobrowse -quiet

rm -rf "$TARGET"
mkdir -p "$TARGET"
cp -R "$WORK/mnt/Audiveris.app" "$TARGET/Audiveris.app"
hdiutil detach "$WORK/mnt" -quiet

# Downloaded code carries a quarantine flag that would follow it into our bundle.
xattr -dr com.apple.quarantine "$TARGET/Audiveris.app" 2>/dev/null || true

echo "==> verifying it runs"
"$TARGET/Audiveris.app/Contents/MacOS/Audiveris" -version

echo "==> done ($ARCH)"
du -sh "$TARGET/Audiveris.app"
