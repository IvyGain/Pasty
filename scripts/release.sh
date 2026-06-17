#!/usr/bin/env bash
# Pasty One-shot release pipeline
#
# Usage:
#   ./scripts/release.sh           # build release dmg + sign + appcast + git tag + GitHub Release
#   ./scripts/release.sh --skip-tag # 同上だが git tag + gh release は省略
#
# 前提:
#   1. PASTY_VERSION = scripts/package.sh のデフォルトを上書きしたい場合は env で
#   2. Sparkle EdDSA 秘密鍵が Keychain に
#      "Private key for signing Sparkle updates" として保存されている
#   3. `brew install --cask sparkle` で sign_update / generate_appcast が利用可能
#   4. `gh auth login` 済み
#
# このスクリプトは Sparkle の generate_appcast を使って
#   1. dmg ビルド (package.sh release)
#   2. dmg を dist/releases/ に集約 (過去 5 件保持)
#   3. docs/appcast.xml を再生成 (EdDSA 署名付き)
#   4. git commit + tag + push
#   5. gh release create で GitHub Release 公開
# の流れで 1 コマンド完結する。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SKIP_TAG="${1:-}"

VERSION="${PASTY_VERSION:-$(awk '/CFBundleShortVersionString/{getline; gsub(/.*<string>|<\/string>.*/,""); print; exit}' scripts/Info.plist.template)}"
TAG="v${VERSION}"
DMG_NAME="Pasty-${VERSION}.dmg"

echo "==> Releasing Pasty ${TAG}"

# --- 1. ビルド + 署名 ---
echo "==> Building release dmg"
PASTY_VERSION="$VERSION" ./scripts/package.sh release

DMG="${ROOT}/dist/${DMG_NAME}"
if [ ! -f "$DMG" ]; then
  echo "✗ Expected dmg not found: $DMG"
  exit 1
fi

# --- 2. appcast 用ディレクトリに dmg を集める ---
RELEASE_DIR="${ROOT}/dist/releases"
mkdir -p "$RELEASE_DIR"
cp "$DMG" "$RELEASE_DIR/$DMG_NAME"
echo "==> Staged dmg in $RELEASE_DIR"

# 古い dmg は最新 5 個だけ残す
ls -t "$RELEASE_DIR"/*.dmg 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

# --- 3. appcast.xml 生成 ---
GENERATE_APPCAST="$(command -v generate_appcast || true)"
if [ -z "$GENERATE_APPCAST" ]; then
  for CANDIDATE in \
    /opt/homebrew/Caskroom/sparkle/*/bin/generate_appcast \
    /usr/local/Caskroom/sparkle/*/bin/generate_appcast \
    /Applications/Sparkle.app/Contents/Resources/generate_appcast; do
    if [ -x "$CANDIDATE" ]; then
      GENERATE_APPCAST="$CANDIDATE"
      break
    fi
  done
fi
if [ -z "$GENERATE_APPCAST" ] || [ ! -x "$GENERATE_APPCAST" ]; then
  echo "✗ generate_appcast が見つかりません。"
  echo "  brew install --cask sparkle を実行してください。"
  exit 1
fi

DOWNLOAD_URL_PREFIX="https://github.com/IvyGain/Pasty/releases/download/${TAG}/"
echo "==> Generating appcast.xml"
"$GENERATE_APPCAST" "$RELEASE_DIR" \
  --maximum-versions 5 \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  -o "${ROOT}/docs/appcast.xml"

# --- 3b. GitHub Pages refresh ---
echo "==> Refreshing GitHub Pages (docs/index.html + docs/whats-new/)"
if ! command -v python3 >/dev/null 2>&1; then
  echo "✗ python3 not found — required for docs/index.html regeneration"
  exit 1
fi
if ! python3 "${ROOT}/scripts/build-pages.py" --latest-version "${VERSION}"; then
  echo "✗ scripts/build-pages.py failed — Pages would be out of sync. Aborting release."
  exit 1
fi
echo "==> Pages rebuilt"

# --- 4. git commit + tag + push ---
if [ "$SKIP_TAG" = "--skip-tag" ]; then
  echo "==> --skip-tag 指定のため git tag / gh release はスキップ"
  exit 0
fi

echo "==> Committing appcast.xml"
git add docs/appcast.xml docs/index.html docs/whats-new/
if git diff --cached --quiet; then
  echo "    (no appcast change to commit)"
else
  git commit -m "release: ${TAG} — refresh appcast + pages"
fi

# 既に tag がある場合は再作成しない
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "==> Tag $TAG already exists, skipping creation"
else
  git tag -a "$TAG" -m "Pasty ${TAG}"
fi

git push origin main
git push origin "$TAG"

# --- 5. GitHub Release ---
echo "==> Creating GitHub Release"
PRERELEASE_FLAG=""
case "$VERSION" in
  *beta*|*alpha*|*rc*) PRERELEASE_FLAG="--prerelease" ;;
esac

# 既存リリースがあれば dmg を差し替え、無ければ新規作成
if gh release view "$TAG" -R IvyGain/Pasty >/dev/null 2>&1; then
  echo "    (existing release, uploading dmg)"
  gh release upload "$TAG" "$DMG" --clobber -R IvyGain/Pasty
else
  gh release create "$TAG" "$DMG" \
    -R IvyGain/Pasty \
    $PRERELEASE_FLAG \
    --title "Pasty ${TAG}" \
    --notes "リリースノートは docs/appcast.xml もしくは https://ivygain.github.io/Pasty/ を参照。"
fi

echo ""
echo "✅ Pasty ${TAG} released"
echo "   - dmg: $DMG"
echo "   - appcast: ${ROOT}/docs/appcast.xml"
echo "   - GitHub: https://github.com/IvyGain/Pasty/releases/tag/${TAG}"
