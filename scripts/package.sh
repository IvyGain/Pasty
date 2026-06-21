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
VERSION="${PASTY_VERSION:-0.9.5-beta}"

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

# Sparkle 用 EdDSA 公開鍵を Info.plist に埋め込む。
# 鍵は ~/.config/pasty/sparkle_public_ed_key.txt にプレーンテキスト 1 行で保存しておく
# (リポジトリには絶対コミットしない)。無い場合はテンプレの placeholder
# `__SU_PUBLIC_ED_KEY__` がそのまま残り、Sparkle は起動時に検証失敗で no-op になる。
ED_KEY_FILE="${HOME}/.config/pasty/sparkle_public_ed_key.txt"
if [ -f "$ED_KEY_FILE" ]; then
  SU_PUBLIC_ED_KEY="$(tr -d '[:space:]' < "$ED_KEY_FILE")"
  echo "==> Embedded SUPublicEDKey (length ${#SU_PUBLIC_ED_KEY})"
else
  SU_PUBLIC_ED_KEY="__SU_PUBLIC_ED_KEY__"
  echo "warn: $ED_KEY_FILE が見つかりません。Sparkle の自動アップデートは無効になります。"
  echo "      './Sparkle/bin/generate_keys' で鍵を作成後、Public Key を上記ファイルに保存してください。"
fi

# Stamp the Info.plist with the chosen version.
sed -e "s/__VERSION__/${VERSION}/g" \
    -e "s/__BUNDLE_ID__/${BUNDLE_ID}/g" \
    -e "s|__SU_PUBLIC_ED_KEY__|${SU_PUBLIC_ED_KEY}|g" \
    "scripts/Info.plist.template" > "$APP/Contents/Info.plist"

# Sparkle.framework を bundle に同梱 (SwiftPM で取得済みの .build/checkouts から)
# Sparkle は AutoUpdate.app / Updater.app などの helper を Frameworks/Sparkle.framework
# 配下に持つので、ディレクトリごとコピーする必要がある。
SPARKLE_FRAMEWORK_SRC="$(find "${ROOT}/.build" -type d -name "Sparkle.framework" -print -quit 2>/dev/null || true)"
if [ -n "$SPARKLE_FRAMEWORK_SRC" ] && [ -d "$SPARKLE_FRAMEWORK_SRC" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$SPARKLE_FRAMEWORK_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
  echo "==> Bundled Sparkle.framework from $SPARKLE_FRAMEWORK_SRC"

  # SPM が出力した実行バイナリは @rpath が @executable_path/ しか持っていない
  # (Sparkle のような同梱フレームワークを探せない)。標準 macOS アプリの慣習に
  # 合わせて @executable_path/../Frameworks を rpath に追加。
  # 既に同じ rpath があれば install_name_tool は error を吐くので grep で確認。
  if ! otool -l "$APP/Contents/MacOS/${APP_NAME}" \
       | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
                       "$APP/Contents/MacOS/${APP_NAME}"
    echo "==> Added @executable_path/../Frameworks to rpath"
  fi
else
  echo "warn: Sparkle.framework が .build に見つかりません。swift build が走っていない?"
fi

# Bundle the .icns so Finder/Dock pick up the GPT-Image-2 designed icon.
ICNS_SRC="${ROOT}/Sources/Pasty/Resources/Assets/Pasty.icns"
if [ -f "$ICNS_SRC" ]; then
  cp "$ICNS_SRC" "$APP/Contents/Resources/Pasty.icns"
  echo "==> Bundled Pasty.icns ($(du -h "$ICNS_SRC" | cut -f1))"
else
  echo "warn: no Pasty.icns found at $ICNS_SRC — Finder will show the generic app icon"
fi

# 署名方針 (優先順):
#   1. PASTY_SIGN_IDENTITY (環境変数で明示)
#   2. Apple Developer ID ($DEV_ID 設定時、Notarize 経路)
#   3. 自前 Self-signed cert (Keychain Access で作成、デフォルト名 "Pasty Self-Signed")
#   4. ad-hoc 署名 (最終フォールバック、TCC 権限が毎回失効する点に注意)
#
# Self-signed cert を使うと code signing identity が安定するため、再ビルド時にも
# アクセシビリティ権限が維持されやすい。Sparkle 経由の自動アップデートでも
# 同じ identity で署名された dmg であれば TCC が継続できる。
SIGN_IDENTITY="${PASTY_SIGN_IDENTITY:-Pasty Self-Signed}"
if [ -n "${DEV_ID:-}" ]; then
  USE_IDENTITY="$DEV_ID"
  echo "==> Codesigning with Developer ID"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
  USE_IDENTITY="$SIGN_IDENTITY"
  echo "==> Codesigning with self-signed identity: $SIGN_IDENTITY"
else
  USE_IDENTITY="-"
  echo "==> Codesigning ad-hoc (TCC permissions will reset on each build)"
  echo "    self-signed cert を Keychain Access で作ると権限が維持されます。"
fi

# Sparkle.framework は内部に XPCServices / Autoupdate / Updater.app を持つので、
# 最も奥から順に署名する必要がある (Apple の Hardened Runtime 検証は再帰的)。
# --deep フラグは notarization では deprecated だが、self-signed では実用上問題ない。
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  # ネスト署名を一度に処理。--deep は内部のサブ bundle まで識別子付きで署名する。
  codesign --force --deep --options runtime \
           --sign "$USE_IDENTITY" \
           "$APP/Contents/Frameworks/Sparkle.framework"
fi

# アプリ本体を最後に署名。framework は既に署名済み。
# entitlements.plist で disable-library-validation を付けて、self-signed で
# Team ID が一致しない Sparkle.framework を load できるようにする。
ENTITLEMENTS="${ROOT}/scripts/entitlements.plist"
if [ "$USE_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
elif [ -f "$ENTITLEMENTS" ]; then
  codesign --force --options runtime \
           --entitlements "$ENTITLEMENTS" \
           --sign "$USE_IDENTITY" "$APP"
else
  codesign --force --options runtime \
           --sign "$USE_IDENTITY" "$APP"
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
