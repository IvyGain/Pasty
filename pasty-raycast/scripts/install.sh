#!/usr/bin/env bash
# Pasty Raycast Extension — One-shot installer
#
# 実行コマンド (このスクリプトを直接 curl で叩く):
#
#   curl -fsSL https://raw.githubusercontent.com/IvyGain/Pasty/main/pasty-raycast/scripts/install.sh | bash
#
# このスクリプトは:
#   1. ~/.pasty-raycast/ に Pasty リポジトリを shallow clone (更新時は git pull)
#   2. pasty-raycast/ で npm install
#   3. Raycast 開発者モードで `npx ray develop` を起動
#
# Raycast 公式ストアに公開されるまでの暫定セットアップ手順。

set -e

PASTY_HOME="${HOME}/.pasty-raycast"
REPO_DIR="${PASTY_HOME}/Pasty"
EXT_DIR="${REPO_DIR}/pasty-raycast"

cyan()  { printf "\033[36m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }

bold "==> Pasty Raycast 拡張をインストール"
echo "保存先: $PASTY_HOME"
echo ""

# --- 0. 必須コマンドの確認 ---
for cmd in git node npm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    red "✗ $cmd が見つかりません"
    case "$cmd" in
      git)  echo "  → Xcode コマンドラインツールをインストールしてください: xcode-select --install" ;;
      node|npm) echo "  → Node.js を https://nodejs.org または brew install node でインストールしてください" ;;
    esac
    exit 1
  fi
done

# Pasty 本体の存在チェック (warning だけ)
if [ ! -d "/Applications/Pasty.app" ]; then
  cyan "⚠️  Pasty.app が /Applications に見つかりません。"
  echo "    Raycast 拡張は Pasty.app の SQLite データベースを読むだけなので、"
  echo "    まず https://github.com/IvyGain/Pasty/releases から Pasty.dmg を"
  echo "    インストールしてからこのスクリプトを実行することをおすすめします。"
  echo ""
  printf "    続行しますか? [y/N] "
  read -r ans
  case "$ans" in
    [yY]*) ;;
    *)     red "中止しました"; exit 0 ;;
  esac
  echo ""
fi

# --- 1. リポジトリ取得 / 更新 ---
mkdir -p "$PASTY_HOME"

if [ -d "$REPO_DIR/.git" ]; then
  cyan "==> 既存リポジトリを最新化"
  (cd "$REPO_DIR" && git fetch --depth 1 origin main && git reset --hard origin/main)
else
  cyan "==> リポジトリを shallow clone"
  git clone --depth 1 https://github.com/IvyGain/Pasty.git "$REPO_DIR"
fi

# --- 2. 依存をインストール ---
cd "$EXT_DIR"
cyan "==> npm install"
npm install --silent --no-audit --no-fund

# --- 3. Raycast 開発モードで起動 ---
echo ""
green "✅ インストール完了"
echo ""
bold "次のステップ:"
echo "  1. Raycast (https://raycast.com/) を起動しておく"
echo "  2. このスクリプトが続けて 'ray develop' を立ち上げます"
echo "  3. Raycast を開いて「Pasty」と入力すると 4 つのコマンドが見つかります"
echo "     - Search Clips / Paste Snippet / Paste by Folder / Recent Images"
echo ""
bold "重要:"
echo "  • 'ray develop' を実行している間だけ Raycast に拡張が登録されます"
echo "  • ターミナルを閉じる / 開発を停止すると Raycast から消えます"
echo "  • 永続化したい場合は Raycast Store 公開を待つか、自分で publish してください"
echo ""
printf "ray develop を今すぐ起動しますか? [Y/n] "
read -r ans
case "$ans" in
  [nN]*)
    bold "後で起動する場合:"
    echo "  cd $EXT_DIR"
    echo "  npx ray develop"
    ;;
  *)
    cyan "==> npx ray develop を起動"
    exec npx ray develop
    ;;
esac
