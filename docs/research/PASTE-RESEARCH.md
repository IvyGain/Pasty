# Paste 徹底リサーチ & Pasty 上位互換スペック

> 調査日: 2026-06-12 / 出典: 公式pasteapp.io, App Store, MacStories, Macworld, 9to5Mac, Product Hunt, Hacker News, Reddit, Setapp, Maccy GitHub, ユーザー指定3記事ほか 20+ ソース。

---

## 1. Pasteとは何か（事実ベース要約）

**Paste – Limitless Clipboard** (Paste Team / pasteapp.io)
- 対応: macOS 14.0+, iOS/iPadOS 26.0+, visionOS 26.0+
- App Store評価: 4.4 / 281件、Product Hunt 4.9★ / 78件
- 最新: v6.6.1（Liquid Glassデザイン）
- 訴求: "NEVER LOSE A COPY AGAIN. Paste is like a time machine for your clipboard."

### 1.1 料金（日本価格）
| プラン | 価格 | 主要差分 |
|---|---|---|
| 無料 | ¥0 | 履歴制限・Pinboard 3個・iCloud不可・MCP不可・AI不可 |
| 月額 | ¥600/月 | 無制限・iCloud・MCP・AI |
| 年額 | ¥4,500/年 | 月額同等 + 割安 |
| Family | ¥9,000/年 | 最大6人 |
| Lifetime | ¥15,000 | 買い切り（Setapp以外） |
| Legacy | ¥1,080/年 | 旧購入者向け縮小プラン |
| 無料試用 | 7日間 | CC登録不要 |

### 1.2 UI/UX（最重要観察）
- **呼出**: ⇧⌘V → 画面下から**ストリップUIがスライドアップ**（Spotlight中央モーダルではない）
- **占有率**: 大型ディスプレイで下40〜50%。M1 Airで下1/3〜半分
- **形式**: **横スクロールカルーセル + 正方形カード**（リスト形式に切替不可）
- **カード構成**: `[ソースアプリアイコン] タイトル + 日付 / コンテンツプレビュー / URLまたは文字数`
- **リサイズ**: 上端ドラッグで縦サイズ可変（4〜8タイル）
- **デザイン**: v6.0からLiquid Glass半透明
- **アニメ**: スライドアップ + フェード、選択ハイライト
- **メニューバー**: 常駐アイコンからも呼出可

### 1.3 完全ホットキー表
| 操作 | キー |
|---|---|
| 履歴表示/非表示 | ⇧⌘V |
| Paste Stack | ⇧⌘C |
| 閉じる | Esc |
| 左/右移動 | ←/→（⌘+で端へ） |
| 貼付 | Return |
| プレーンテキスト貼付 | ⇧Return |
| クイック貼付 1〜9 | ⌘1〜⌘9 |
| 検索 | ⌘F |
| 編集 | ⌘E |
| タイトル変更 | ⌘R |
| 新規テキスト | ⌘N |
| Quick Look | Space |
| 削除 | Delete |
| ピンボード切替 | ⌘[ / ⌘] |
| 設定 | ⌘, |
| 一時停止 | ⌘T |
| 新規Pinboard | ⇧⌘N |
| 全選択 | ⌘A |

### 1.4 主要機能ブロック
1. **クリップボード履歴**: テキスト/RTF/画像/ファイル/リンク/HTML/PDF/絵文字/カラー
2. **Pinboards**: 色付き複数ボード、無制限、ドラッグ&ドロップ、共有(5.0+)、Family Sharing
3. **Paste Stack**: 浮遊パレットで複数アイテムを順次貼付、2本指スワイプ削除
4. **Power Search (2025/12)**: OCR / `type:` `source:` `date:` `pinboard:` 演算子 / 正規表現
5. **iCloud E2E同期**: Mac↔iPhone↔iPad↔Vision Pro
6. **Paste Keyboard (iOS)** + Share Extension
7. **Siri Shortcuts**: 履歴取得/検索/ピン作成/貼付Action
8. **Paste MCP (2026/6)**: ローカルMCPサーバー、Claude/Cursor/Codex/Windsurf連携、グラニュラー権限
9. **Apple Intelligence (15.1+)**: Writing Tools統合（要約/校正/書換/精錬）
10. **機密フィルタ**: 無視アプリ、パスワード自動除外、画面共有時非可視
11. **保持期間設定**: 1日/週/月/年/無制限
12. **URL Scheme**: `paste://search?query=...` / `paste://create?text=...`

---

## 2. Paste の不満・離脱要因（TOP 10）

| # | 不満 | ソース | 重要度 |
|---|---|---|---|
| 1 | **買切→サブスク移行への怒り**「既存ユーザー見捨て」 | Product Hunt, 日本ブログ | ★★★★★ |
| 2 | **メモリ4〜5GBに膨張**（数千件履歴+検索時） | Paste Feedback nolt | ★★★★★ |
| 3 | **画面下40〜50%占有**で大型モニタ困る、リスト切替不可 | Product Hunt複数 | ★★★★ |
| 4 | **検索が2〜3秒遅延**、UI出現も1〜2秒遅延 | Product Hunt | ★★★★ |
| 5 | **iCloud同期5〜10分遅延・データ消失**事例 | Help Center "Reset iCloud Data" | ★★★★ |
| 6 | **Markdown/Code構文ハイライトなし** | 開発者層離脱 | ★★★★ |
| 7 | **スニペット変数展開なし**（日付/ユーザー名等） | TextExpander代替不可 | ★★★ |
| 8 | **同期はiCloudのみ**（Dropbox/Syncthing/自前不可） | プライバシー懸念層 | ★★★ |
| 9 | **Plain Text貼付が時々無視される** | UI不具合 | ★★★ |
| 10 | **古いアイテム整理UIが貧弱**（ルールベース削除なし） | Power User層 | ★★ |

加えて: Lifetime ¥15,000 の高さ、Maccy（無料OSS）への流出加速、Feedback対応の遅さ。

---

## 3. 競合ランドスケープ

| アプリ | 価格 | 同期 | AI | 強み | 弱み |
|---|---|---|---|---|---|
| **Maccy** | 無料(OSS) | ✗ | ✗ | 軽量30-50MB、起動最速、Swift製、7.2k★ | 同期なし・AIなし・UIシンプル |
| **Paste** | ¥4,500/年 | iCloud | ✓ Apple Intelligence + MCP | 美UI、iOS同期、Pinboard共有 | 価格、メモリ、画面占有 |
| **Pastebot** | $4.99買切 | iCloud | ✗ | 古参信頼、ペーストルール | 開発停滞、UI古い |
| **Raycast Clip** | 無料(本体) | ✗ | ✓ Pro | Raycast生態系、検索最速、AI | Launcher依存 |
| **Alfred Clip** | £34+ | ✗ | ✗ | ワークフロー最強 | 学習曲線、UI古い |
| **PastePal** | $19.99/年 | ✓ 自前 | ✗ | 同期、iOS | サブスク不評、規模小 |
| **Clipy** | 無料(OSS) | ✗ | ✗ | 日本由来、Swift | 開発停滞 |
| **CopyClip 2** | $9.99 | ✗ | ✗ | 安価 | 差別化弱い |

**市場の核心**: 「Maccy(無料OSS)」 vs 「Paste(美UI有料)」の二極化。**Maccyに同期+AIが付くと完全に終わる**。先んじて Maccy の弱点（同期/AI/Pinboard共有）を奪取するのが勝ち筋。

---

## 4. 技術スタック確定推奨

| レイヤ | 選定 | 理由 |
|---|---|---|
| 言語 | **Swift 5.10+** | NSPasteboardネイティブ、Apple Intelligence/MCP、メモリ効率 |
| UI | **SwiftUI + AppKit** (MenuBarExtra macOS 13+) | モダン、Liquid Glass対応、Spotlight風モーダル容易 |
| DB | **GRDB (SQLite + FTS5)** | 全文検索高速、CloudKit同期との結合制御性 |
| 同期 | **CloudKit Private DB** | Apple ID自動認証、E2E、無料 |
| クリップ監視 | **NSPasteboard polling 250ms** | macOSに通知APIなし。Maccyが6年証明 |
| 自動貼付 | **CGEvent + Accessibility権限** | <50ms 95%信頼性 |
| ホットキー | **HotKey library** (Carbon RegisterEventHotKey) | グローバルキー捕捉の業界標準 |
| OCR | **Vision (VNRecognizeTextRequest)** | オンデバイス多言語 |
| AI | **Foundation Models framework (15.1+)** | オンデバイス、無料、プライバシー |
| MCP | **swift-mcp-sdk** + stdio/HTTP | Claude/Cursor連携 |
| 自動更新 | **Sparkle 2.x** | GitHub Releasesのappcast.xml連携 |
| 課金 | **なし** | 完全OSS無料配布のため不要 |
| 配布 | **Developer ID + 公証 + GitHub Releases (.dmg)** | URL共有でGatekeeper通過、MAS非対応 |
| ライセンス | **MIT** | OSS、コア & UI 全公開、フォーク歓迎 |

**開発見積**: コア機能MVP **6〜8週間**。同期+AI+MCPまで含めて **3〜4ヶ月**。

---

## 5. Pasty 上位互換スペック（差別化7軸）

### 軸1: **デュアルUI** — ストリップ + Spotlight中央モーダル切替
- Pasteの最大不満「画面占有率」を1秒で解決。`Tab`で表示形式トグル
- リスト/カード/グリッドの3形式切替（Paste はカード固定）
- 設定で**ホットキー別に表示形式を割当可**（⇧⌘V=ストリップ / ⌥⇧V=中央モーダル）

### 軸2: **真のローカルファースト + 選択的同期**
- デフォルト100%ローカルSQLite、iCloud同期はオプトイン
- **複数同期バックエンド**: iCloud / Syncthing / WebDAV / Git / 自前S3
- E2E暗号化（PastyKey: macOS Keychain派生鍵 + AES-GCM）
- 「機密モード」: 一時停止トグル + アプリブラックリスト + 自動マスク

### 軸3: **メモリ徹底最適化**（常時 <100MB）
- 仮想スクロール、画像はサムネイル+遅延ロード、FTS5インデックス分離
- 履歴件数自動上限+ストレージ予算設定
- Pasteの致命的不満「4〜5GB膨張」を完全排除

### 軸4: **開発者ファースト機能**
- **Markdown / Code構文ハイライト**（Tree-sitter）
- **スニペット変数展開**: `{{date}}` `{{cursor}}` `{{clipboard}}` `{{user}}` `{{uuid}}` カスタム関数
- **JSON/YAML プリティプリント + 折りたたみ**
- **Diff View**: 2つの履歴を選択して差分表示
- **正規表現+SQL風DSL検索**: `type:code lang:python source:vscode date:>2026-06-01`

### 軸5: **AI ネイティブ（無料層含む）**
- オンデバイス Foundation Models で **無料**: 要約・タグ自動付与・自動Pinboard振分・類似検索・翻訳
- 有料層: クラウドLLM経由の「変換ワークフロー」（例: 議事録→TODO抽出）
- **MCPサーバー組込** + Pastyを **MCPクライアント**にもする（外部AIにペースト履歴を渡し+受取）

### 軸6: **完全無料 OSS (MIT)・全機能解放**
- 販売しない / サブスクなし / 課金UIなし。GitHub Releases から `.dmg` を URL でダウンロード配布。
- 全機能を全ユーザーへ開放（同期もAIもMCPもPaste Stackも全部無料）。
- 収益化なしのため、**Sparkle + GitHub Releases + Developer ID 公証** のみで配布。
- StoreKit / Paddle / Stripe など課金ライブラリ一切不要 → コードが軽くなる。
- **戦略**: Paste(有料)の上位互換を無料で提供 + MIT で公開 → Maccy層も Paste層も両方の流入受け皿。

### 軸7極: **ノッチ・ホバー召喚UI**（Pasty 独自の決定打 / 2026-06-12 提案）
MacBook Pro M1 Pro/Max 以降の **ノッチは普段デッドスペース**。ここをホットゾーン化し、マウスをノッチに乗せた瞬間 **画面上端から Liquid Glass のストリップが下方向にスライドダウン** → ドラッグ&ドロップで貼付完了、できる。

```
 ┌───────[●●●]──────────┐    ← マウスホバー
 │ ノッチ                │
 ▼
┌──────────────────────────────────────────────────────────┐
│ 🔍 ⌘F  📌 Inbox | Work | Code           [カード][リスト] │ ← 上端から滑り降りる
├──────────────────────────────────────────────────────────┤
│ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ →│ ← 横スクロール
│ │ 1│ │ 2│ │ 3│ │ 4│ │ 5│ │ 6│ │ 7│ │ 8│ │ 9│ │10│ │11│   │
│ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘   │
└──────────────────────────────────────────────────────────┘
        │
        ▼ ドラッグ
   ┌────────────────────┐
   │ アクティブなテキスト  │ ← ドロップで貼付完了
   │ エディタ            │
   └────────────────────┘
```

**実装ポイント:**
- ノッチ検出: `NSScreen.main?.safeAreaInsets.top > 0` でノッチ機検出。`screen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` を取得し中央が「ノッチ領域」
- ホバー検出: 画面最上端に高さ4pxの透明`NSPanel`を `nonactivatingPanel` + `.canJoinAllSpaces` + `.fullScreenAuxiliary` で常駐配置。`NSTrackingArea` でカーソル進入を検知（150〜250ms滞留でtrigger、誤起動防止）
- スライドダウン: トリガー後 `NSPanel` を画面上端から下に **CABasicAnimation** でフレーム拡大、`backgroundColor = .clear` + NSVisualEffectView（`.fullScreenUI` + `.hudWindow`）でLiquid Glass質感
- ドラッグ&ドロップ: 各カードに `NSItemProvider` を `NSDraggingSource` 経由で提供。テキスト/画像/ファイルを `.string` / `.tiff` / `.fileURL` でドロップ先へ渡す
- 自動撤収: マウスが上端外＋200ms or Esc で逆アニメーションで上端に吸収
- フォールバック: ノッチがないMac (iMac/Mac mini/MacBook Air M1)では「画面上端中央20%」を疑似ノッチ領域として動作

**UX上の優位性:**
- Spotlight風中央モーダルは「呼ぶ→検索」の能動操作だが、ノッチホバーは **マウスを少し上に動かす** だけで召喚可能 (手の移動コスト最小)
- Paste の「下からスライド」は画面占有率高いが、ノッチホバーは **必要な時だけ降りてくる** → 視界クリーン
- ドラッグ&ドロップは「貼付先を間違える」「⌘V してから検索する」の操作不一致を解消
- ノッチを「触れる UI」にした最初のクリップボードアプリになる可能性（MarTechハック化）

**ホットキー併存:** ⇧⌘V (中央モーダル) / ⌥⇧V (下ストリップ) / ノッチホバー (上ドロップダウン) の **3トリガー併存**。利用シーンで使い分け。

### 軸8: **クロスプラットフォーム拡張**
- **Phase1**: macOSのみ（Apple品質を確立）
- **Phase2**: iOS/iPadOS（Paste Keyboard + Share Sheet）
- **Phase3**: visionOS（Pasteが薄い領域を取る）
- **Phase4**: Web Viewer（履歴ブラウザのみ、貼付不可）+ CLI (`pasty paste --search ...`)

---

## 6. UI/UX設計（核心）

### 6.1 ストリップモード（Paste互換、最適化版）
```
画面下から80px幅のストリップ。高さは最大画面の25%（Pasteの40%超→25%固定）
┌──────────────────────────────────────────────────────────────────────┐
│ [⌘F 検索...] [📌 Inbox] [Work] [Code] [+] [⚙]    [全]全 画 文 リ    │ ← フィルタタブ
├──────────────────────────────────────────────────────────────────────┤
│ ┌─[1]─┐ ┌─[2]─┐ ┌─[3]─┐ ┌─[4]─┐ ┌─[5]─┐ ┌─[6]─┐ ┌─[7]─┐ ┌─[8]─┐ → │
│ │aicon│ │aicon│ │aicon│ │aicon│ │aicon│ │aicon│ │aicon│ │aicon│   │
│ │preview│ │imag│ │link│ │code│ │text│ │file│ │html│ │colr│        │
│ │ 1.2k字│ │PNG │ │GH  │ │py  │ │メモ│ │csv │ │tbl │ │#FF │        │
│ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

### 6.2 Spotlight中央モーダル（独自・Raycast風）
```
画面中央に幅720px、最大高540pxの中央モーダル
              ┌───────────────────────────────────────────────┐
              │ 🔍 type:code lang:python from:VSCode           │
              ├───────────────────────────────────────────────┤
              │ 📌 main.py - imports     VSCode    6/12 10:23 │  ← 選択中
              │    def main():                                │  ← インラインプレビュー
              │        ...                                    │
              ├───────────────────────────────────────────────┤
              │ 📌 utils.py - helper     VSCode    6/12 09:01 │
              │ 🔗 GitHub Issue #42      Safari    6/11 18:55 │
              │ 🖼  screenshot.png        Slack     6/11 17:30 │
              ├───────────────────────────────────────────────┤
              │ ↩ Paste  ⇧↩ Plain  Space Quick Look  ⌘E Edit │
              └───────────────────────────────────────────────┘
```

### 6.3 Paste Stack 強化版
- Pasteは「下→上」順固定不満 → Pasty は **順序を視覚的にドラッグ並替可能**
- スタック中もMarkdown整形 / 変数展開 / 区切り文字挿入を選択可
- 「Stack as Document」: スタック内容をMarkdown/CSVとして1アイテム化

### 6.4 機密モード（Pasteにない）
- メニューバー右クリックで「⏸ 60秒一時停止 / 終日 / アプリ別」
- **シークレットPinboard**（要Touch ID / パスフレーズ）
- パスワードマネージャ自動検出（1Password, Bitwarden, KeePassXC, iCloud Keychain）

---

## 7. ホットキー設計（Paste互換 + 拡張）

Paste互換のキー（⇧⌘V / ⇧⌘C / ⌘1-9 / Space / ⌘F / ⇧Return…）は**全部踏襲**。乗換摩擦ゼロ。  
**Pasty追加キー**:
| 操作 | キー |
|---|---|
| Spotlightモード起動 | ⌥⇧V |
| 表示形式切替（カード/リスト/グリッド） | Tab長押し or ⌘L |
| 機密モード即停止 | ⌃⇧P |
| シークレットPinboard | ⌃⇧S |
| Diff選択 | ⌘D (2件選択時) |
| AI変換メニュー | ⌘I |
| MCPで現在のClaude/Cursorへ送信 | ⌘M |
| 変数展開プレビュー | ⌘P |
| 履歴を新規Pinboardへ移動 | ⌘⇧M |

---

## 8. アーキテクチャ図

```
┌──────────────────────────── Pasty (macOS) ────────────────────────────┐
│                                                                        │
│  ┌────────── UI Layer (SwiftUI + AppKit) ──────────┐                  │
│  │  MenuBarExtra │ StripPanel │ SpotlightPanel │ Settings │           │
│  └────┬─────────────────┬────────────────┬───────────────┘           │
│       │                 │                │                            │
│  ┌────▼─────────────────▼────────────────▼──────────┐                │
│  │           HotKey & Accessibility Service           │                │
│  │  • Global Hotkeys (HotKey lib)                    │                │
│  │  • CGEvent Cmd+V poster                           │                │
│  │  • AXIsProcessTrusted gate                        │                │
│  └────┬─────────────────────────────────────────────┘                 │
│       │                                                                │
│  ┌────▼────────── Core Service ──────────┐  ┌─────── AI Service ──┐   │
│  │ PasteboardObserver (poll 250ms)        │  │ Foundation Models   │   │
│  │ → ClipItem builder                     │  │ (15.1+) Summarize / │   │
│  │ → Sensitive filter (transient/password)│  │ Categorize / Tag    │   │
│  │ → Source app resolver                  │  │ Vision (OCR)        │   │
│  └────┬─────────────────────┬─────────────┘  └──────┬──────────────┘   │
│       │                     │                       │                  │
│  ┌────▼────── Persistence ──▼──────────┐  ┌────────▼────── MCP ──┐    │
│  │ GRDB (SQLite + FTS5)                 │  │ MCP Server (stdio)   │    │
│  │ • clips / pinboards / tags / labels  │  │   tools: search,     │    │
│  │ • blobs in FS (images/files)         │  │     get, create      │    │
│  │ • Migration system                   │  │ MCP Client → AI tool │    │
│  └────┬────────────┬────────────────────┘  └──────────────────────┘    │
│       │            │                                                   │
│  ┌────▼─────┐  ┌───▼────────── Sync Adapters ──────────┐               │
│  │ Local    │  │ CloudKit │ Syncthing │ WebDAV │ S3   │               │
│  │ Encrypt  │  │ E2E      │ E2E       │ E2E    │ E2E  │               │
│  │ (Keychn) │  └────────────────────────────────────────┘               │
│  └──────────┘                                                          │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 9. MVP → v1.0 ロードマップ（Mac専用シンプルMVP / 6〜8週間）

| フェーズ | 期間 | 内容 | 完了条件 |
|---|---|---|---|
| **P0 基盤** | W1 | Xcode project / SwiftPM依存 / GRDB schema / PasteboardObserver | コピー→履歴SQLite保存 |
| **P1 メイン動線** | W2 | MenuBarExtra / SpotlightPanel(中央モーダル) / HotKey / CGEvent貼付 / FTS5検索 | ⇧⌘V→検索→Return貼付 |
| **P2 ストリップUI + Pinboard + Stack** | W3 | StripPanel(下スライド) / Pinboards CRUD / Paste Stack / 機密モード | Paste互換UX |
| **P2.5 ノッチホバー召喚** | W3末 | NotchHoverPanel(上ドロップダウン) / TrackingArea / NSItemProvider D&D | ノッチ→ホバー→ドラッグで貼付完了 |
| **P3 開発者機能** | W4 | Markdown/Tree-sitter構文ハイライト / スニペット変数 / 正規表現+DSL検索 / Diff | 差別化機能投入 |
| **P4 AI (オンデバイス)** | W5 | Foundation Models(15.1+) / Vision OCR / 自動タグ / 要約 / 翻訳 | 無料AI差別化 |
| **P5 仕上げ + 配布** | W6-W7 | Settings / アクセシビリティ / JP/EN i18n / Sparkle / Developer ID公証 / GitHub Releases | `.dmg` URL配布開始 |
| **P6 v1.x 拡張** | W8+ | MCPサーバー / URL Scheme / CLI / Syncthing連携(オプション) | コミュニティ要望次第 |

**配布フロー**: `make release` → notarize → GitHub Releases に `.dmg` + `appcast.xml` → README/サイトに URL 掲載 → ユーザーは URL からダウンロード/ダブルクリックでインストール。

---

## 10. リスク・撤退ライン

| リスク | 対策 |
|---|---|
| **Maccyが同期+AI実装** | 速度勝負: P0-P5を10週間で完了。AIと開発者機能で差別化維持 |
| **Apple Intelligence API不安定** | ローカル別実装フォールバック（llama.cpp埋め込み） |
| **Accessibility権限拒否ユーザー** | クリップボード履歴のみは動作する設計（貼付はクリック動線提供） |
| **MAS Sandbox制約** | Accessibility必須機能は直接配布版で、MAS版は閲覧+クリック貼付に限定 |
| **iCloud同期トラブル** | 複数バックエンドで分散、Syncthing/Gitを推奨パスに |
| **メモリ膨張** | 仮想スクロール + サムネ別保存 + 自動圧縮、開発初期から計測必須 |

---

## 11. 確定事項（2026-06-12 → 2026-06-13 更新）

- ✅ **対象**: macOS 14.0+ シングルプラットフォーム
- ✅ **ライセンス**: MIT（完全OSS、GitHub公開）
- ✅ **配布**: GitHub Releases (`.dmg` 約 4.0 MB) を URL 共有、Developer ID公証済み
- ✅ **価格**: 完全無料、全機能解放
- ✅ **スコープ**: P0-P5 完了 → P6 (v0.4.0) / P7 (v0.4.1) 出荷済み
- 🚧 **次フェーズ**: P8 (同期 / MCP / iOS / visionOS) を v0.5.x 以降で展開

## 12. 次のアクション（v0.4.1 出荷後）

1. **v0.5.x P8 準備**: CloudKit Private DB スキーマ設計、Syncthing 連携PoC、MCP server scaffolding
2. **iOS/iPadOS 展開**: Paste Keyboard + Share Extension 仕様の確定、CloudKit 経由の履歴共有
3. **コミュニティ運用**: GitHub Discussions / Issue triage、Smart folder ルール拡張要望の収集
4. **品質**: Insights dashboard の実利用ログから FTS5 / 仮想スクロールの追加最適化指標を取得
5. **マーケ**: Product Hunt / Hacker News 出稿、ランディングページの多言語化 (現状 JP)

---

## 13. 実績（リリース時系列）

| Date | Version | 主要機能 |
|---|---|---|
| 2026-06-12 | **v0.1.0** | 基盤 (P0/P1): MenuBarExtra, Spotlight中央モーダル, HotKey, CGEvent貼付, GRDB + FTS5 検索 |
| 2026-06-12 | **v0.2.0** | ストリップ UI + Pinboard CRUD + Paste Stack + 機密モード + ノッチホバー召喚 (P2/P2.5) |
| 2026-06-12 | **v0.2.x** | ノッチドロップダウンの離脱時クローズ修正、ランディングページ日本語化 |
| 2026-06-12 | **v0.3.0** | strip-first 方針、shared carousel、folder warehouse、snippet authoring (P3 開発者機能 + P4 AI 基盤) |
| 2026-06-13 | **v0.4.0** | Preview Revolution: Quick Look (Space), Explorer split-pane (⌘P), inline edit (⌘E), Hover Pill, Paste toast, Snippet variable live preview |
| 2026-06-13 | **v0.4.1** | Intelligence & Templates: mail-merge `[[name]]`, `{{var\|uppercase}}` modifiers, Foundation Models AI actions (⌘I + ⌃⇧R/T/S/J/E), Smart folders (7 builtin), Auto-categorize, Stack pill, Onboarding, Help overlay, Hotkey customization, Insights dashboard, JSON Import/Export, Undo Paste (⌃⇧Z) |

---

## 14. 主要出典

- pasteapp.io / pasteapp.io/help / pasteapp.io/updates / feedback.pasteapp.io
- apps.apple.com/jp/app/paste-limitless-clipboard/id967805235
- 9to5mac.com/2026/06/02/paste-launches-mcp-support
- macstories.net (Paste 4.0 review)
- macworld.com/article/804417/paste-review.html
- producthunt.com/products/paste/reviews
- news.ycombinator.com (Maccy & Paste discussions)
- github.com/p0deje/Maccy / github.com/Clipy/Clipy
- izuka-effects.com/paste-app-setapp / yossense.com/mac-paste / note.com/keirosso0415
- alternativeto.net / setapp.com/apps/paste / quietclip.app/blog
- Apple Developer: NSPasteboard, MenuBarExtra, CloudKit, Vision, Foundation Models, Accessibility, Notarization
