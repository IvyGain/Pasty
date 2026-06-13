# Pasty for Raycast

Pasty（macOS 向けクリップボードマネージャー）の Raycast 拡張版です。Pasty 本体が記録したクリップ履歴を Raycast から検索・貼付・連続貼付できます。

## 概要

- Pasty 本体は macOS のクリップボード履歴・スニペット・フォルダ管理を担う常駐アプリです。
- この Raycast 拡張は、Pasty が保存している SQLite データベース (`clips.sqlite`) を直接読み取り、Raycast の高速ランチャー UI から履歴を検索・操作できるようにします。
- テキスト・画像・スニペット・フォルダ別ブラウズに対応し、連続貼付や複数結合貼付などのワークフロー強化機能を提供します。

## 前提条件

- macOS に Pasty 本体（`Pasty.app`）がインストールされ、少なくとも一度起動済みであること。
- `~/Library/Application Support/Pasty/clips.sqlite` が存在すること（Pasty 本体が自動生成します）。
- Raycast 1.86 以降。

## インストール

### Raycast Store からインストール（公開後）

1. Raycast を開く。
2. Store コマンドから "Pasty" を検索。
3. Install を押す。

### サイドロード（開発・先行利用）

```bash
cd pasty-raycast
npm install
npx ray develop
```

`ray develop` 起動中は Raycast 内に "Pasty" コマンドが表示されます。停止すると外れます。`npx ray build` でビルド、`npm run publish` で Raycast Store への申請が可能です。

## コマンド一覧

| コマンド | 説明 |
| --- | --- |
| **Search Clips** | Pasty が記録した全クリップ履歴を全文検索します。テキスト・URL・コードなどを横断的に絞り込めます。 |
| **Paste Snippet** | Pasty に登録したスニペットをフォルダごとにブラウズし、即座に貼付できます。 |
| **Paste by Folder** | クリップをフォルダ別に表示し、用途別に整理されたクリップへ素早くアクセスできます。 |
| **Recent Images** | 最近キャプチャした画像クリップを一覧表示します。プレビュー付きで選択し、貼付やコピーが可能です。 |

## キーボードショートカット

| キー | 動作 |
| --- | --- |
| `Enter` | 選択中のクリップを貼付して Raycast を閉じる |
| `⌥ Enter` | 貼付して **閉じない**（連続貼付モード） |
| `⌘ Enter` | 選択中の複数クリップを **結合** して貼付 |
| `⌘ ⌥ Enter` | 選択中の複数クリップを **順次** 貼付 + 閉じない |
| `Space` | 複数選択モードのトグル |
| `⌘ A` | 表示中のクリップを全選択 |
| `⌘ D` | 選択を全解除 |
| `⌘ C` | クリップボードに置くだけ（貼付しない） |

連続貼付は、複数のフィールドへ続けて値を入力する作業や、同じスニペットを複数回挿入する場面で特に有効です。

## 設定（Preferences）

Raycast の Extension Preferences から以下を設定できます。

| 設定 | デフォルト | 説明 |
| --- | --- | --- |
| **Pasty Database Path** (`dbPath`) | `~/Library/Application Support/Pasty/clips.sqlite` | Pasty が保存している SQLite データベースのパス。Pasty 本体を別の場所に移している場合に上書きします。 |
| **Close after pasting** (`closeOnPaste`) | ON | `Enter` で貼付した後 Raycast を閉じるかどうか。OFF にすると常駐モードのように扱えます。 |
| **Page Size** (`pageSize`) | `200` | 一度に取得するクリップ件数。`50` / `100` / `200` / `500` から選択。大きくすると検索範囲が広がる代わりに初回ロードが遅くなります。 |

## トラブルシューティング

- **「データベースが見つかりません」と表示される**: Pasty 本体を一度起動して `clips.sqlite` を作成してください。それでも解決しない場合は `Pasty Database Path` 設定にフルパスを指定します。
- **検索結果が古い**: Pasty 本体は新規クリップを随時 SQLite に書き込みます。Raycast 側はコマンド起動ごとに最新を再読込しますが、表示中の場合は一度コマンドを閉じて再度開いてください。
- **画像が表示されない**: 画像クリップは Pasty 本体のキャッシュディレクトリを参照します。Pasty 本体がアンインストール／キャッシュクリアされていないか確認してください。

## ライセンス

MIT License — 詳細は [LICENSE](../LICENSE) を参照してください。
