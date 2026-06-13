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
VERSION="${PASTY_VERSION:-0.1.0}"

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
