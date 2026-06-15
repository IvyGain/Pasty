#!/usr/bin/env bash
# Bundle the SPM executable into a real `.app` and a distributable `.dmg`.
#
# Usage:
#   ./scripts/package.sh                  # debug build → .app + .dmg
#   ./scripts/package.sh release          # release build → .app + .dmg
#   ./scripts/package.sh release notarize # also runs notarytool (requires
#                                           DEV_ID & TEAM_ID env vars)
#
# Without notarisation the resulting .dmg is signed ad-hoc; users will see
# Gatekeeper prompt them once. Set `DEV_ID="Developer ID Application: …"`
# and `TEAM_ID=ABCDE12345` and pass `notarize` for full Notary service.

set -euo pipefail

CONFIG="${1:-debug}"
NOTARIZE="${2:-}"

APP_NAME="Pasty"
BUNDLE_ID="io.pasty.app"
VERSION="${PASTY_VERSION:-0.5.0-beta}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export SDKROOT="${DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
SWIFT="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

echo "==> Building ${APP_NAME} (${CONFIG})"
if [ "$CONFIG" = "release" ]; then
  "$SWIFT" build -c release
  BIN="${ROOT}/.build/release/${APP_NAME}"
else
  "$SWIFT" build
  BIN="${ROOT}/.build/debug/${APP_NAME}"
fi

DIST="${ROOT}/dist"
APP="${DIST}/${APP_NAME}.app"
DMG="${DIST}/${APP_NAME}-${VERSION}.dmg"

rm -rf "$DIST" "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
chmod +x "$APP/Contents/MacOS/${APP_NAME}"

# Stamp the Info.plist with the chosen version.
sed -e "s/__VERSION__/${VERSION}/g" \
    -e "s/__BUNDLE_ID__/${BUNDLE_ID}/g" \
    "scripts/Info.plist.template" > "$APP/Contents/Info.plist"

# Bundle the .icns so Finder/Dock pick up the GPT-Image-2 designed icon.
ICNS_SRC="${ROOT}/Sources/Pasty/Resources/Assets/Pasty.icns"
if [ -f "$ICNS_SRC" ]; then
  cp "$ICNS_SRC" "$APP/Contents/Resources/Pasty.icns"
  echo "==> Bundled Pasty.icns ($(du -h "$ICNS_SRC" | cut -f1))"
else
  echo "warn: no Pasty.icns found at $ICNS_SRC — Finder will show the generic app icon"
fi

# Ad-hoc sign (or Developer-ID sign if DEV_ID set).
if [ -n "${DEV_ID:-}" ]; then
  echo "==> Codesigning with Developer ID"
  codesign --force --options runtime --timestamp \
           --sign "$DEV_ID" "$APP"
else
  echo "==> Codesigning ad-hoc (Gatekeeper will warn once on first run)"
  codesign --force --sign - "$APP"
fi

# Build dmg.
echo "==> Creating ${DMG}"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"

# Optional notarisation.
if [ "$NOTARIZE" = "notarize" ]; then
  : "${KEYCHAIN_PROFILE:?KEYCHAIN_PROFILE env var required for notarisation}"
  echo "==> Submitting to Apple notary service"
  xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

du -h "$APP" "$DMG" 2>/dev/null | tail -2
echo "✓ Done: $DMG"

# `install` を末尾に渡すと `/Applications/Pasty.app` を上書き＋アイコン
# キャッシュ refresh ＋ 起動まで一気通貫。`make release-install` から呼ばれる。
if [ "$NOTARIZE" = "install" ] || [ "${3:-}" = "install" ]; then
  echo "==> /Applications/Pasty.app を上書き中…"
  pkill -9 Pasty 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Pasty.app
  ditto "$APP" /Applications/Pasty.app
  touch /Applications/Pasty.app
  # Dock アイコンのキャッシュを強制 refresh
  killall Dock 2>/dev/null || true
  sleep 1
  open /Applications/Pasty.app
  echo "==> 起動完了: $(defaults read /Applications/Pasty.app/Contents/Info.plist CFBundleShortVersionString)"
fi
