# Pasty WebUI アニメーション ノウハウ集

## 出典
- ソース: https://animation-effect.v0.build/templates
- リサーチ日: 2026-06-21
- 調査者: CCAGI ai-product-analyzer + documentation
- 調査範囲: index ページ + 9 件の詳細ページ (全 24 テンプレ列挙)

Pasty の公式 LP (`docs/index.html`) は素の HTML + インライン CSS で構成されており、フレームワーク・ビルドツール非依存である。本ドキュメントはこの制約を前提に、v0 community gallery から得た最新トレンドを「Pasty で今すぐ採用できる純 CSS / SVG / vanilla JS パターン」に翻訳して整理する。

---

## 1. テンプレートカタログ (全件)

| Template | Category | Tech stack | Complexity | Pasty 適用 |
|---|---|---|---|---|
| Apple-Style Scroll Product Explode | Scroll/3D | Canvas 192-frame + spring | High | 低 |
| Animated Border Cards | Card | React + Tailwind + animated gradient stroke | Mid | 中 |
| v0 Loading Components | Loading | React/Next/Tailwind | Low | 中 |
| Infinite Scrolling Images | Carousel | CSS keyframes loop | Low | 高 |
| Shader Gradient Component | Hero/BG | GLSL/Shader | High | 低 |
| Logo Particles | Particles | SVG + particle system | High | 低 |
| Glassmorphic Feature Showcase | Card/Glass | Framer Motion + backdrop-blur | Mid | 中 |
| v0 Orbit Animation | Loading | CSS keyframes + transform | Low | 高 |
| Cash App Navigation Drawer | Drawer | Framer Motion gesture | Mid | 低 |
| Shader SVG (bouncing char) | SVG | SVG + mesh gradient + bounce | Low | 高 |
| Sensory Playground | Experience | (unknown) | — | 低 |
| Art Gallery Slider | Gallery | (unknown) | — | 中 |
| Martian Parallax | Parallax | (unknown) | — | 低 |
| 3D Gallery Photography | Gallery/3D | Three.js 推定 | High | 低 |
| WebGPU Graphene 3D | 3D/WebGPU | WebGPU | High | 低 |
| Immersive 3D Studio | 3D | (unknown) | High | 低 |
| Aura Vibes Pulse | BG/Pulse | (unknown) | Mid | 中 |
| Video to ASCII | Effect | Canvas + video sampling | Mid | 中 |
| 3D Interactive Mac Keyboard | 3D | Three.js 推定 | High | 低 |
| Liquid Distortion Hover | Hover | WebGL shader | High | 低 |
| Text Reveal On Scroll | Type | IntersectionObserver | Low | 高 |
| Bento Grid Layout | Layout | CSS Grid + hover | Low | 高 |
| Cursor Aura | Cursor | mix-blend-mode | Low | 中 |
| Page Transition Stripes | Page TX | View Transitions API | Mid | 中 |

---

## 2. カテゴリ別技術ノウハウ

### 2.1 Hero セクション
- 主流: フルブリードのシェーダーグラデーション or 動画背景
- 軽量代替: CSS `conic-gradient` + `@property` でアニメ可能なグラデ
- Pasty 適用: SVG `<feTurbulence>` + mesh gradient で「シェーダーっぽさ」を 1KB 未満で実現可能

### 2.2 Card / Tile
- グラスモーフィズム (`backdrop-filter: blur(20px)` + 半透明白 5–10%)
- アニメ枠線: `@property --angle` + `conic-gradient` を `rotate`
- 3D tilt: `mousemove` で `transform: rotateX/Y` (依存なし JS 20 行)

### 2.3 Button / CTA
- マグネティック追従 (cursor 距離で `translate(x, y)`)
- リップル (click 位置から `<span>` を `scale` で拡散)
- グラデ流動 (`background-position` を `@keyframes` で平行移動)

### 2.4 Scroll-driven
- 旧: IntersectionObserver + class toggle (互換性最優先)
- 新: CSS `scroll-timeline` / `animation-timeline: view()` (Chrome 115+, Safari 26)
- 動画スクラブ: `requestAnimationFrame` + `video.currentTime`

### 2.5 Cursor effect
- カスタムカーソル (`mix-blend-mode: difference` で白黒反転)
- マグネティック (距離減衰 lerp、frame-rate 非依存)
- トレイル (canvas に履歴座標を描画してフェードアウト)

### 2.6 Page transition
- View Transitions API (Chrome 111+, Safari 18)
- crossfade / shared element / slide
- Pasty 用途では `view-transition-name` を hero ロゴに付けるだけで効果大

### 2.7 Loading / skeleton
- shimmer: `linear-gradient` を `background-position` で流す (1 要素で完結)
- orbit: 中心点回転 + `animation-delay` で複数球を時間差配置
- dot pulse: `scale` + `opacity` の 1.4s ループ

### 2.8 SVG / Canvas
- SVG `path` `stroke-dasharray` で描画アニメ (ロゴリビール)
- `<feTurbulence>` + `<feDisplacementMap>` で organic blob 背景
- Canvas particle: 200 粒子 + `requestAnimationFrame` で 60fps 維持

---

## 3. 使用ライブラリカタログ

| ライブラリ | サイズ (min+gz) | License | ブラウザ | 用途 |
|---|---|---|---|---|
| Framer Motion | ~50KB | MIT | Evergreen | React 専用、宣言的トランジション |
| GSAP | ~40KB (core) | 標準無料/商用要 | IE9+ | タイムライン制御、ScrollTrigger |
| Motion One | ~3.8KB | MIT | Evergreen | WAAPI 軽量ラッパー、framer 作者 |
| Lottie-web | ~60KB | MIT | Evergreen | After Effects JSON 再生 |
| Three.js | ~150KB | MIT | WebGL2 | 3D シーン |
| OGL | ~14KB | MIT | WebGL2 | 軽量 3D / シェーダー |
| anime.js | ~8KB | MIT | Evergreen | プロパティ補間 |
| (なし: 純 CSS) | 0KB | — | — | **Pasty 推奨** |

**結論**: Pasty の LP は静的配布されており、ライブラリ追加 = ビルドパイプライン追加。CCAGI のスコープ契約と相反するため、原則「依存ゼロ」で実装する。

---

## 4. Pasty Pages 適用提案

| 技術 | サイズ負荷 | 実装コスト | UX 効果 | 推奨度 |
|---|---|---|---|---|
| CSS `@keyframes` fade-in | 0KB | 5分 | 中 | ★★★★★ |
| IntersectionObserver scroll-reveal | 0KB | 15分 | 大 | ★★★★★ |
| CSS `scroll-timeline` (progressive) | 0KB | 20分 | 大 | ★★★★ |
| `backdrop-filter` glass card | 0KB | 5分 | 中 | ★★★★★ |
| `@property --angle` グラデ枠 | 0KB | 30分 | 大 | ★★★★ |
| Infinite marquee (CSS only) | 0KB | 10分 | 中 | ★★★★★ |
| SVG mesh gradient hero | <2KB | 20分 | 大 | ★★★★ |
| Magnetic button (vanilla JS) | <0.5KB | 30分 | 中 | ★★★ |
| Orbit loader (CSS) | 0KB | 15分 | 中 | ★★★★ |
| View Transitions API | 0KB | 30分 | 大 | ★★★ (Safari 要確認) |
| Shimmer skeleton | 0KB | 10分 | 中 | ★★★★ |
| Click ripple | <0.3KB | 20分 | 小 | ★★★ |
| Mouse-tilt 3D card | <0.5KB | 30分 | 中 | ★★★ |
| Motion One (WAAPI) | 3.8KB | 1時間 | 大 | ★★ |
| GSAP ScrollTrigger | 40KB+ | 2時間 | 大 | ★ (依存重) |

---

## 5. 「すぐ使える」スニペット集

すべて単一の `.html` ファイルにそのまま貼り付け可能。外部依存ゼロ、IE は非対応 (Pasty は macOS アプリのため Safari/Chrome/Firefox の最新版のみ想定)。

### 5.1 Scroll Reveal (IntersectionObserver, 依存ゼロ)

配置先: `docs/index.html` の特徴セクション。要素が viewport に 20% 入った瞬間に下からふわっと出現。

```html
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Scroll Reveal Demo</title>
<style>
  /* 初期状態: 下に 24px ずらして透明 */
  .reveal {
    opacity: 0;
    transform: translateY(24px);
    /* 600ms の cubic-bezier はマテリアルの "standard" カーブ */
    transition: opacity 600ms cubic-bezier(.2,.7,.2,1),
                transform 600ms cubic-bezier(.2,.7,.2,1);
    will-change: opacity, transform;
  }
  /* .is-visible が付与された瞬間にフェードイン */
  .reveal.is-visible {
    opacity: 1;
    transform: translateY(0);
  }
  /* アクセシビリティ: 動きを減らす設定なら即表示 */
  @media (prefers-reduced-motion: reduce) {
    .reveal { transition: none; opacity: 1; transform: none; }
  }
  /* デモ用スタイル */
  body { margin: 0; font-family: -apple-system, sans-serif; background: #0a0a0a; color: #fff; }
  section { min-height: 80vh; display: grid; place-items: center; padding: 4rem; }
  .card { background: #1a1a1a; padding: 2rem; border-radius: 16px; max-width: 480px; }
</style>
</head>
<body>
  <section><h1>スクロールしてください ↓</h1></section>
  <section><div class="card reveal"><h2>Feature 1</h2><p>下からふわっと出現します</p></div></section>
  <section><div class="card reveal"><h2>Feature 2</h2><p>2 枚目も同様に出現</p></div></section>
  <section><div class="card reveal"><h2>Feature 3</h2><p>依存ゼロ・60fps 維持</p></div></section>

<script>
  // 一度だけ表示したい要素を集める
  const targets = document.querySelectorAll('.reveal');
  // IntersectionObserver: viewport との交差を監視
  const io = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        // 一度表示したら監視解除でパフォーマンス節約
        io.unobserve(entry.target);
      }
    });
  }, { threshold: 0.2 }); // 20% 見えたら発火
  targets.forEach(el => io.observe(el));
</script>
</body>
</html>
```

### 5.2 Glassmorphic Card

配置先: 特徴セクションのカード。背景画像/グラデの上でないと効果が見えないので、親に背景を敷くこと。

```html
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Glass Card Demo</title>
<style>
  body {
    margin: 0; min-height: 100vh;
    font-family: -apple-system, sans-serif;
    /* グラスを際立たせるカラフルな背景 */
    background: linear-gradient(135deg, #667eea 0%, #764ba2 50%, #f093fb 100%);
    display: grid; place-items: center;
    padding: 2rem;
  }
  .glass-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
    gap: 1.5rem; max-width: 960px;
  }
  /* グラスモーフィズム本体 */
  .glass {
    /* 半透明白でガラス感を演出 */
    background: rgba(255, 255, 255, 0.12);
    /* 背景をぼかすのが肝。Safari 用に -webkit- を併記 */
    backdrop-filter: blur(20px) saturate(180%);
    -webkit-backdrop-filter: blur(20px) saturate(180%);
    /* 内側ハイライトで立体感 */
    border: 1px solid rgba(255, 255, 255, 0.2);
    border-radius: 20px;
    padding: 2rem;
    color: white;
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2);
    transition: transform 300ms ease, box-shadow 300ms ease;
  }
  .glass:hover {
    transform: translateY(-4px);
    box-shadow: 0 16px 48px rgba(0, 0, 0, 0.3);
  }
  .glass h3 { margin: 0 0 0.5rem; font-size: 1.25rem; }
  .glass p { margin: 0; opacity: 0.85; line-height: 1.6; }
</style>
</head>
<body>
  <div class="glass-grid">
    <div class="glass"><h3>瞬時にペースト</h3><p>クリップボードを瞬時に呼び出し</p></div>
    <div class="glass"><h3>フォルダ整理</h3><p>ドラッグ&ドロップで簡単整理</p></div>
    <div class="glass"><h3>iCloud 同期</h3><p>全デバイスで履歴を共有</p></div>
  </div>
</body>
</html>
```

### 5.3 Animated Gradient Border (`@property`)

配置先: CTA カード枠線。Chrome 85+, Safari 16.4+ で動作。未対応ブラウザは静止グラデにフォールバック。

```html
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Animated Border Demo</title>
<style>
  /* @property でカスタムプロパティを「アニメート可能な型」として登録 */
  @property --angle {
    syntax: '<angle>';
    initial-value: 0deg;
    inherits: false;
  }
  body {
    margin: 0; min-height: 100vh;
    background: #0a0a0a; color: #fff;
    font-family: -apple-system, sans-serif;
    display: grid; place-items: center;
  }
  .border-card {
    position: relative;
    width: 320px; padding: 2rem;
    background: #1a1a1a;
    border-radius: 16px;
    /* 疑似要素で枠を作るので overflow は visible */
  }
  /* 枠線の正体: 親より大きい疑似要素に conic-gradient */
  .border-card::before {
    content: '';
    position: absolute;
    inset: -2px; /* 2px だけ外側にはみ出す = 枠線の太さ */
    border-radius: inherit;
    /* --angle を起点に虹色 conic gradient */
    background: conic-gradient(
      from var(--angle),
      #ff006e, #8338ec, #3a86ff, #06ffa5, #ffbe0b, #ff006e
    );
    z-index: -1;
    /* 8 秒で 360 度回転 */
    animation: spin 8s linear infinite;
  }
  @keyframes spin {
    to { --angle: 360deg; }
  }
  .border-card h2 { margin: 0 0 0.5rem; }
  .border-card p { margin: 0; opacity: 0.7; line-height: 1.6; }
</style>
</head>
<body>
  <div class="border-card">
    <h2>Pasty Pro</h2>
    <p>クリップボード履歴を無制限保存。virtual ペースト・iCloud 同期・カスタムショートカット対応。</p>
  </div>
</body>
</html>
```

### 5.4 Infinite Marquee

配置先: 「対応プラットフォーム」ロゴ羅列など。CSS のみで無限スクロール、JS ゼロ。

```html
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Marquee Demo</title>
<style>
  body { margin: 0; background: #0a0a0a; color: #fff; font-family: -apple-system, sans-serif; padding: 4rem 0; }
  /* marquee コンテナ: 横スクロールを隠す */
  .marquee {
    overflow: hidden;
    /* 両端をぼかして「無限感」を演出 (mask-image) */
    mask-image: linear-gradient(90deg, transparent, #000 10%, #000 90%, transparent);
    -webkit-mask-image: linear-gradient(90deg, transparent, #000 10%, #000 90%, transparent);
  }
  /* track: 中身を 2 セット並べて平行移動 */
  .marquee__track {
    display: flex;
    gap: 3rem;
    width: max-content;
    /* 20 秒で 1 セット分 (-50%) スライド */
    animation: scroll 20s linear infinite;
  }
  /* hover で停止 (UX 配慮) */
  .marquee:hover .marquee__track { animation-play-state: paused; }
  @keyframes scroll {
    from { transform: translateX(0); }
    to   { transform: translateX(-50%); } /* 2 セットあるので -50% でループ */
  }
  .marquee__item {
    flex-shrink: 0;
    padding: 1rem 2rem;
    background: #1a1a1a;
    border-radius: 12px;
    white-space: nowrap;
    font-size: 1.1rem;
  }
  @media (prefers-reduced-motion: reduce) {
    .marquee__track { animation: none; }
  }
</style>
</head>
<body>
  <div class="marquee">
    <div class="marquee__track">
      <!-- 1 セット目 -->
      <div class="marquee__item">macOS 13 Ventura</div>
      <div class="marquee__item">macOS 14 Sonoma</div>
      <div class="marquee__item">macOS 15 Sequoia</div>
      <div class="marquee__item">iCloud Drive</div>
      <div class="marquee__item">日本語 / English</div>
      <!-- 2 セット目 (完全に同じ内容を複製) -->
      <div class="marquee__item">macOS 13 Ventura</div>
      <div class="marquee__item">macOS 14 Sonoma</div>
      <div class="marquee__item">macOS 15 Sequoia</div>
      <div class="marquee__item">iCloud Drive</div>
      <div class="marquee__item">日本語 / English</div>
    </div>
  </div>
</body>
</html>
```

### 5.5 CSS Orbit Loader

配置先: Sparkle 中ローディング。CSS だけで 3 球が中心を周回。

```html
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Orbit Loader</title>
<style>
  body { margin: 0; min-height: 100vh; background: #0a0a0a; display: grid; place-items: center; }
  /* loader 全体: 80x80 の正方形 */
  .orbit {
    position: relative;
    width: 80px; height: 80px;
  }
  /* 各球は絶対配置で中心に置き、回転原点をずらして円軌道に */
  .orbit__dot {
    position: absolute;
    inset: 0;
    margin: auto;
    width: 14px; height: 14px;
    border-radius: 50%;
    background: #ff006e;
    /* 軌道半径: transform-origin で中心からのオフセット */
    transform-origin: 50% 36px; /* 半径 36px の軌道 */
    /* 1.4 秒で 1 周 */
    animation: orbit 1.4s linear infinite;
  }
  /* 3 つの球に異なる色と animation-delay で時間差 */
  .orbit__dot:nth-child(1) { background: #ff006e; animation-delay: 0s; }
  .orbit__dot:nth-child(2) { background: #3a86ff; animation-delay: -0.46s; } /* 1/3 周遅らせる */
  .orbit__dot:nth-child(3) { background: #06ffa5; animation-delay: -0.93s; } /* 2/3 周遅らせる */
  @keyframes orbit {
    to { transform: rotate(360deg); }
  }
  @media (prefers-reduced-motion: reduce) {
    .orbit__dot { animation: none; }
  }
</style>
</head>
<body>
  <div class="orbit" role="status" aria-label="読み込み中">
    <div class="orbit__dot"></div>
    <div class="orbit__dot"></div>
    <div class="orbit__dot"></div>
  </div>
</body>
</html>
```

### 5.6 Shimmer Skeleton

配置先: 履歴一覧の初期表示。1 要素で完結、layout shift ゼロ。

```html
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Shimmer Skeleton</title>
<style>
  body { margin: 0; padding: 2rem; background: #0a0a0a; font-family: -apple-system, sans-serif; }
  .skeleton-list {
    max-width: 480px; margin: 0 auto;
    display: flex; flex-direction: column; gap: 0.75rem;
  }
  /* skeleton 1 行 */
  .skeleton {
    height: 56px;
    border-radius: 8px;
    /* 暗いベース + ハイライトの 3 段グラデを横に流す */
    background:
      linear-gradient(
        90deg,
        #1a1a1a 0%,
        #2a2a2a 50%,   /* ← ハイライト位置 */
        #1a1a1a 100%
      );
    /* 背景を 2 倍幅にして position だけ動かす = GPU 加速 */
    background-size: 200% 100%;
    background-position: 200% 0;
    animation: shimmer 1.6s ease-in-out infinite;
  }
  /* 幅違いで「内容のばらつき」を再現 */
  .skeleton--short { width: 60%; }
  .skeleton--mid   { width: 85%; }
  @keyframes shimmer {
    to { background-position: -200% 0; }
  }
  @media (prefers-reduced-motion: reduce) {
    .skeleton { animation: none; background: #1a1a1a; }
  }
</style>
</head>
<body>
  <div class="skeleton-list" aria-busy="true" aria-label="履歴読み込み中">
    <div class="skeleton"></div>
    <div class="skeleton skeleton--mid"></div>
    <div class="skeleton skeleton--short"></div>
    <div class="skeleton"></div>
    <div class="skeleton skeleton--mid"></div>
    <div class="skeleton skeleton--short"></div>
  </div>
</body>
</html>
```

### 5.7 Magnetic Button (vanilla JS)

配置先: ヒーロー直下の「ダウンロード」CTA。マウスが近づくと吸い寄せられる。

```html
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Magnetic Button</title>
<style>
  body {
    margin: 0; min-height: 100vh;
    background: #0a0a0a; color: #fff;
    font-family: -apple-system, sans-serif;
    display: grid; place-items: center;
  }
  .magnetic {
    /* 当たり判定を広げるためのラッパ */
    display: inline-block;
    padding: 40px; /* この余白の中でカーソルを追従 */
  }
  .magnetic__btn {
    /* JS が transform を上書きするので transition は短めに */
    transition: transform 200ms cubic-bezier(.2,.7,.2,1);
    padding: 1rem 2.5rem;
    background: linear-gradient(135deg, #ff006e, #8338ec);
    color: white; border: none; border-radius: 999px;
    font-size: 1.1rem; font-weight: 600;
    cursor: pointer;
    box-shadow: 0 8px 24px rgba(255, 0, 110, 0.4);
  }
  @media (prefers-reduced-motion: reduce) {
    .magnetic__btn { transition: none; }
  }
</style>
</head>
<body>
  <div class="magnetic">
    <button class="magnetic__btn">Download for macOS</button>
  </div>

<script>
  // 動きを減らす設定なら何もしない
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) { /* no-op */ }
  else {
    document.querySelectorAll('.magnetic').forEach(wrapper => {
      const btn = wrapper.querySelector('.magnetic__btn');
      // マウス位置に応じてボタンを translate
      wrapper.addEventListener('mousemove', (e) => {
        const rect = wrapper.getBoundingClientRect();
        // ラッパ中心からの相対座標
        const x = e.clientX - rect.left - rect.width  / 2;
        const y = e.clientY - rect.top  - rect.height / 2;
        // 0.3 倍に減衰して引き寄せ感を出す (1.0 だと張り付きすぎ)
        btn.style.transform = `translate(${x * 0.3}px, ${y * 0.3}px)`;
      });
      // 離れたら元位置に戻す
      wrapper.addEventListener('mouseleave', () => {
        btn.style.transform = 'translate(0, 0)';
      });
    });
  }
</script>
</body>
</html>
```

---

## 6. 今後のアクション提案

1. **Hero 強化**: 現状の静的ヒーローに SVG mesh gradient + 5.1 の scroll-reveal を導入 (実装コスト 30 分、UX 改善大)
2. **特徴セクション**: 5.2 のグラスモーフィズム + 5.3 の animated border を 3 カード並べ、ホバーで lift
3. **CTA 強化**: 5.7 のマグネティック追従でダウンロードボタンを差別化、click 時に ripple を追加
4. **Footer 直前**: 5.4 の infinite marquee で「対応 macOS / 言語 / クラウド」をスクロール表示
5. **ローディング統一**: Sparkle 中の 5.5 Orbit loader を全ページで一貫させブランド感を強化
6. **履歴一覧の体感速度**: 5.6 shimmer skeleton で initial paint 後の「待ち」を視覚化、layout shift をゼロに

いずれもビルドツール不要・ライブラリ追加ゼロで `docs/*.html` に直接貼り付け可能。CCAGI スコープ契約 (依存最小化) を守りつつ、v0 community で観察された最新 UX トレンドを Pasty LP に反映できる。

---

*本ドキュメントは CCAGI ai-product-analyzer (Step 1) + documentation (Step 2) の連携出力。改訂時は出典 URL のテンプレ追加分を反映すること。*
