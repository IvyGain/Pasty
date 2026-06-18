#!/usr/bin/env python3
"""
build-pages.py — Generate Pasty release notes pages.

Outputs:
  * docs/index.html — injects a "リリースノート" section between
    <!-- RELEASES:BEGIN --> and <!-- RELEASES:END --> sentinels.
  * docs/whats-new/<version>.html — standalone per-release pages.

Sources (in priority order):
  1. Sources/Pasty/Resources/whats-new/<version>.md  (in-repo markdown)
  2. `gh release view v<version> --json body -q .body`  (GitHub release body)
  3. Placeholder "Coming soon" text.

Usage:
  python3 scripts/build-pages.py
  python3 scripts/build-pages.py --latest-version 0.8.1-beta
"""

from __future__ import annotations

import argparse
import html
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
WHATS_NEW_DIR = ROOT / "Sources" / "Pasty" / "Resources" / "whats-new"
OUT_PER_RELEASE_DIR = DOCS / "whats-new"
INDEX_PATH = DOCS / "index.html"

SENTINEL_BEGIN = "<!-- RELEASES:BEGIN -->"
SENTINEL_END = "<!-- RELEASES:END -->"

# Hero block sentinels — wrap the hero subtitle, eyebrow pill, and download CTA.
HERO_BEGIN = "<!-- HERO:BEGIN -->"
HERO_END = "<!-- HERO:END -->"
# Nav chip sentinel — wraps the top-nav "v0.x.y" link
HERO_NAV_BEGIN = "<!-- HERO_NAV:BEGIN -->"
HERO_NAV_END = "<!-- HERO_NAV:END -->"
# Download card sentinel — wraps the macOS app card version + dmg size
DOWNLOAD_CARD_BEGIN = "<!-- DOWNLOAD_CARD:BEGIN -->"
DOWNLOAD_CARD_END = "<!-- DOWNLOAD_CARD:END -->"
# Raycast recommended-version sentinel — wraps "Pasty vX.Y.Z-beta+ 推奨"
RAYCAST_REC_BEGIN = "<!-- RAYCAST_REC:BEGIN -->"
RAYCAST_REC_END = "<!-- RAYCAST_REC:END -->"

# Minimum version (inclusive) to display in the release-notes section.
MIN_VERSION = (0, 6, 0)


# ---------------------------------------------------------------------------
# Markdown -> HTML (hand-rolled, conservative).
# ---------------------------------------------------------------------------

INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")
BOLD_RE = re.compile(r"\*\*([^*\n]+)\*\*")
ITALIC_RE = re.compile(r"(?<!\*)\*([^*\n]+)\*(?!\*)")
LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
AUTOLINK_RE = re.compile(r"(?<![\"\(>=])(https?://[^\s<>)\]]+)")


def _inline(text: str) -> str:
    """Apply inline markdown transforms after escaping."""
    # Store code spans first to protect them from other inline rules.
    spans: List[str] = []

    def store_code(m: re.Match) -> str:
        spans.append(m.group(1))
        return f"\x00CODE{len(spans) - 1}\x00"

    text = INLINE_CODE_RE.sub(store_code, text)

    text = html.escape(text, quote=False)

    text = LINK_RE.sub(
        lambda m: f'<a href="{html.escape(m.group(2), quote=True)}" target="_blank" rel="noopener">{m.group(1)}</a>',
        text,
    )
    text = AUTOLINK_RE.sub(
        lambda m: f'<a href="{m.group(1)}" target="_blank" rel="noopener">{m.group(1)}</a>',
        text,
    )
    text = BOLD_RE.sub(r"<strong>\1</strong>", text)
    text = ITALIC_RE.sub(r"<em>\1</em>", text)

    # Restore inline code spans.
    def restore_code(m: re.Match) -> str:
        idx = int(m.group(1))
        return f"<code>{html.escape(spans[idx], quote=False)}</code>"

    text = re.sub(r"\x00CODE(\d+)\x00", restore_code, text)
    return text


def markdown_to_html(md: str) -> str:
    """Convert a small subset of Markdown into HTML."""
    lines = md.replace("\r\n", "\n").split("\n")
    out: List[str] = []
    i = 0
    in_list = False
    list_buf: List[str] = []

    def flush_list() -> None:
        nonlocal in_list, list_buf
        if in_list:
            out.append("<ul>")
            out.extend(list_buf)
            out.append("</ul>")
            in_list = False
            list_buf = []

    para_buf: List[str] = []

    def flush_para() -> None:
        nonlocal para_buf
        if para_buf:
            text = " ".join(s.strip() for s in para_buf).strip()
            if text:
                out.append(f"<p>{_inline(text)}</p>")
            para_buf = []

    while i < len(lines):
        line = lines[i]

        # Fenced code block.
        if line.startswith("```"):
            flush_list()
            flush_para()
            lang = line[3:].strip()
            i += 1
            code_lines: List[str] = []
            while i < len(lines) and not lines[i].startswith("```"):
                code_lines.append(lines[i])
                i += 1
            if i < len(lines):
                i += 1  # consume closing ```
            cls = f' class="lang-{html.escape(lang, quote=True)}"' if lang else ""
            esc = html.escape("\n".join(code_lines), quote=False)
            out.append(f"<pre><code{cls}>{esc}</code></pre>")
            continue

        # Horizontal rule.
        if re.match(r"^\s*---+\s*$", line):
            flush_list()
            flush_para()
            out.append("<hr />")
            i += 1
            continue

        # Headings.
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            flush_list()
            flush_para()
            level = len(m.group(1))
            out.append(f"<h{level}>{_inline(m.group(2).strip())}</h{level}>")
            i += 1
            continue

        # List item.
        m = re.match(r"^\s*[-*]\s+(.*)$", line)
        if m:
            flush_para()
            in_list = True
            list_buf.append(f"<li>{_inline(m.group(1).strip())}</li>")
            i += 1
            continue

        # Blank line.
        if line.strip() == "":
            flush_list()
            flush_para()
            i += 1
            continue

        # Paragraph line.
        flush_list()
        para_buf.append(line)
        i += 1

    flush_list()
    flush_para()
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Tag / source discovery.
# ---------------------------------------------------------------------------


def git_tags() -> List[str]:
    try:
        out = subprocess.check_output(
            ["git", "tag", "--sort=-creatordate"],
            cwd=ROOT,
            text=True,
        )
    except subprocess.CalledProcessError:
        return []
    return [t.strip() for t in out.splitlines() if t.strip().startswith("v")]


def parse_version(v: str) -> Optional[tuple]:
    """Parse 'v0.8.0-beta' or '0.8.0-beta' into a sortable tuple."""
    s = v.lstrip("v")
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$", s)
    if not m:
        return None
    major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
    pre = m.group(4) or ""
    # Sort: stable > pre-release of same x.y.z, so use a tuple where empty pre
    # sorts after any non-empty. We only use this to filter >= MIN_VERSION
    # which is (0, 6, 0), and for ordering within same x.y.z (rare).
    return (major, minor, patch, pre)


def version_in_scope(v: str) -> bool:
    parsed = parse_version(v)
    if not parsed:
        return False
    return parsed[:3] >= MIN_VERSION


def read_markdown(version: str) -> Optional[str]:
    md_path = WHATS_NEW_DIR / f"{version}.md"
    if md_path.exists():
        return md_path.read_text(encoding="utf-8")
    return None


def fetch_github_body(tag: str) -> Optional[str]:
    try:
        out = subprocess.check_output(
            ["gh", "release", "view", tag, "--json", "body", "-q", ".body"],
            cwd=ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        )
        body = out.strip()
        return body if body else None
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def fetch_release_date(tag: str) -> Optional[str]:
    try:
        out = subprocess.check_output(
            ["gh", "release", "view", tag, "--json", "publishedAt", "-q", ".publishedAt"],
            cwd=ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        )
        date = out.strip()
        if date:
            # publishedAt looks like "2026-06-15T10:23:45Z" — slice the date.
            return date[:10]
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    # Fallback: ask git for tag date.
    try:
        out = subprocess.check_output(
            ["git", "log", "-1", "--format=%cs", tag],
            cwd=ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        )
        return out.strip() or None
    except subprocess.CalledProcessError:
        return None


# ---------------------------------------------------------------------------
# HTML emitters.
# ---------------------------------------------------------------------------


STANDALONE_CSS = """
:root {
  --bg: #fbfbfd;
  --bg-soft: #f5f5f7;
  --bg-card: rgba(255,255,255,0.7);
  --text: #1d1d1f;
  --text-soft: #6e6e73;
  --line: rgba(0,0,0,0.08);
  --line-strong: rgba(0,0,0,0.18);
  --accent: #6366f1;
  --accent-2: #a855f7;
  --radius: 18px;
  --font: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text",
          "Helvetica Neue", "Hiragino Kaku Gothic ProN", system-ui, sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #000;
    --bg-soft: #0a0a0a;
    --bg-card: rgba(28,28,30,0.65);
    --text: #f5f5f7;
    --text-soft: #c7c7cc;
    --line: rgba(255,255,255,0.10);
    --line-strong: rgba(255,255,255,0.22);
  }
}
* { box-sizing: border-box; margin: 0; padding: 0; }
html { scroll-behavior: smooth; -webkit-font-smoothing: antialiased; }
body {
  font-family: var(--font);
  background: var(--bg);
  color: var(--text);
  line-height: 1.65;
  letter-spacing: -0.011em;
  padding: 48px 24px 80px;
}
body::before {
  content: ""; position: fixed; inset: 0; z-index: -1; pointer-events: none;
  background:
    radial-gradient(60vw 50vh at 80% -20%, rgba(99,102,241,0.15), transparent 60%),
    radial-gradient(50vw 50vh at -10% 30%, rgba(168,85,247,0.12), transparent 60%);
}
.wrap { max-width: 760px; margin: 0 auto; }
.back {
  display: inline-flex; align-items: center; gap: 6px;
  color: var(--text-soft); font-size: 14px; text-decoration: none;
  margin-bottom: 28px;
}
.back:hover { color: var(--text); }
.eyebrow {
  display: inline-block;
  font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase;
  color: var(--accent);
  padding: 5px 12px; border-radius: 999px;
  background: color-mix(in srgb, var(--accent) 14%, transparent);
  margin-bottom: 18px;
}
.card {
  background: var(--bg-card);
  backdrop-filter: blur(20px);
  -webkit-backdrop-filter: blur(20px);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 36px 36px 44px;
  box-shadow: 0 30px 80px -20px rgba(0,0,0,0.18);
}
@media (max-width: 600px) { .card { padding: 28px 22px 36px; } }
.card h1 {
  font-size: clamp(28px, 5vw, 40px);
  letter-spacing: -0.02em; line-height: 1.15;
  margin-bottom: 8px;
}
.card .meta {
  color: var(--text-soft); font-size: 13px; margin-bottom: 28px;
}
.card h2 {
  font-size: 22px; letter-spacing: -0.015em;
  margin: 32px 0 12px;
  padding-bottom: 8px; border-bottom: 1px solid var(--line);
}
.card h3 { font-size: 17px; margin: 22px 0 8px; }
.card h4 { font-size: 15px; margin: 18px 0 6px; }
.card p { margin: 10px 0; color: var(--text); }
.card ul { margin: 10px 0 10px 22px; }
.card li { margin: 4px 0; }
.card a { color: var(--accent); text-decoration: none; border-bottom: 1px dotted currentColor; }
.card a:hover { border-bottom-style: solid; }
.card code {
  font-family: var(--mono); font-size: 0.9em;
  background: var(--bg-soft);
  padding: 1px 6px; border-radius: 5px;
}
.card pre {
  background: var(--bg-soft);
  border: 1px solid var(--line);
  border-radius: 10px;
  padding: 14px 18px; overflow-x: auto;
  margin: 14px 0;
}
.card pre code { background: transparent; padding: 0; font-size: 13px; }
.card hr { border: none; border-top: 1px solid var(--line); margin: 28px 0; }
.dl {
  display: inline-flex; gap: 8px; align-items: center;
  margin-top: 28px;
  padding: 12px 22px; border-radius: 999px;
  background: linear-gradient(135deg, var(--accent), var(--accent-2));
  color: white; font-weight: 600; text-decoration: none;
  box-shadow: 0 12px 30px -8px rgba(99,102,241,0.5);
}
.dl:hover { transform: translateY(-1px); }
"""


def standalone_page(version: str, date: Optional[str], body_html: str) -> str:
    date_html = (
        f'<div class="meta">{html.escape(date)} リリース</div>' if date else ""
    )
    title = f"Pasty v{version} — リリースノート"
    return f"""<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="color-scheme" content="light dark" />
<title>{html.escape(title)}</title>
<meta name="description" content="Pasty v{html.escape(version)} のリリースノート — 新機能・改善・修正の詳細。" />
<link rel="icon" type="image/png" sizes="64x64" href="../assets/icon-64.png" />
<style>{STANDALONE_CSS}</style>
</head>
<body>
<div class="wrap">
  <a class="back" href="../index.html">← Pasty トップへ</a>
  <article class="card">
    <span class="eyebrow">v{html.escape(version)}</span>
    <h1>Pasty v{html.escape(version)}</h1>
    {date_html}
    {body_html}
    <a class="dl"
       href="https://github.com/IvyGain/Pasty/releases/tag/v{html.escape(version)}"
       target="_blank" rel="noopener">
      GitHub Releases で詳細を見る ↗
    </a>
  </article>
</div>
</body>
</html>
"""


RELEASES_SECTION_CSS = """
  #releases { padding: 80px 0 40px; }
  #releases .container { max-width: 1180px; margin: 0 auto; padding: 0 28px; }
  #releases .head { text-align: center; margin-bottom: 44px; }
  #releases h2.title {
    font-size: clamp(32px, 4.6vw, 48px);
    font-weight: 700; letter-spacing: -0.03em; line-height: 1.1;
    margin-bottom: 14px;
  }
  #releases p.lede {
    color: var(--text-soft);
    max-width: 620px; margin: 0 auto;
    font-size: 17px;
  }
  #releases .latest-card {
    background: var(--bg-card);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid var(--line);
    border-radius: var(--radius-md, 18px);
    padding: 28px 32px;
    margin-bottom: 28px;
    display: flex; align-items: center; gap: 22px; flex-wrap: wrap;
    box-shadow: var(--shadow);
  }
  #releases .latest-card .latest-meta { flex: 1; min-width: 240px; }
  #releases .latest-card .pill {
    display: inline-block;
    font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase;
    color: var(--accent); font-weight: 600;
    padding: 4px 10px; border-radius: 999px;
    background: color-mix(in srgb, var(--accent) 14%, transparent);
    margin-bottom: 10px;
  }
  #releases .latest-card .ver {
    font-size: 26px; font-weight: 700; letter-spacing: -0.015em;
    font-family: var(--mono);
  }
  #releases .latest-card .sys { color: var(--text-soft); font-size: 13px; margin-top: 4px; }
  #releases .release-list { display: flex; flex-direction: column; gap: 14px; }
  #releases details.release {
    background: var(--bg-card);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid var(--line);
    border-radius: var(--radius-md, 18px);
    overflow: hidden;
    transition: border-color .2s, transform .2s;
  }
  #releases details.release[open] { border-color: var(--line-strong); }
  #releases details.release summary {
    cursor: pointer;
    padding: 20px 26px;
    display: flex; align-items: center; gap: 18px;
    list-style: none;
    user-select: none;
  }
  #releases details.release summary::-webkit-details-marker { display: none; }
  #releases details.release summary::after {
    content: "▾";
    margin-left: auto;
    color: var(--text-soft);
    transition: transform .2s;
  }
  #releases details.release[open] summary::after { transform: rotate(180deg); }
  #releases details.release summary .v {
    font-family: var(--mono);
    font-size: 16px; font-weight: 700;
    color: var(--text);
  }
  #releases details.release summary .badge {
    font-size: 10px; letter-spacing: 0.08em; text-transform: uppercase;
    color: var(--accent); font-weight: 600;
    padding: 3px 8px; border-radius: 999px;
    background: color-mix(in srgb, var(--accent) 14%, transparent);
  }
  #releases details.release summary .date {
    color: var(--text-dim); font-size: 13px;
  }
  #releases details.release .body {
    padding: 4px 32px 28px;
    color: var(--text);
    line-height: 1.7;
    border-top: 1px solid var(--line);
  }
  #releases details.release .body h1,
  #releases details.release .body h2 {
    font-size: 18px; font-weight: 600; letter-spacing: -0.01em;
    margin: 22px 0 8px;
    padding-bottom: 6px; border-bottom: 1px solid var(--line);
  }
  #releases details.release .body h3 { font-size: 15px; margin: 18px 0 6px; }
  #releases details.release .body h4 { font-size: 14px; margin: 14px 0 4px; }
  #releases details.release .body p { margin: 8px 0; color: var(--text-soft); }
  #releases details.release .body ul { margin: 8px 0 8px 22px; color: var(--text-soft); }
  #releases details.release .body li { margin: 3px 0; }
  #releases details.release .body code {
    font-family: var(--mono); font-size: 0.88em;
    background: var(--bg-soft);
    padding: 1px 6px; border-radius: 5px;
  }
  #releases details.release .body pre {
    background: var(--bg-soft);
    border: 1px solid var(--line);
    border-radius: 10px;
    padding: 14px 18px; overflow-x: auto;
    margin: 12px 0;
  }
  #releases details.release .body pre code { background: transparent; padding: 0; font-size: 13px; }
  #releases details.release .body a { color: var(--accent); border-bottom: 1px dotted currentColor; }
  #releases details.release .body a:hover { border-bottom-style: solid; }
  #releases details.release .body hr { border: none; border-top: 1px solid var(--line); margin: 18px 0; }
  #releases .permalink {
    display: inline-flex; align-items: center; gap: 6px;
    margin-top: 14px;
    font-size: 13px; color: var(--text-soft);
    border-bottom: 1px dotted currentColor;
  }
  #releases .permalink:hover { color: var(--text); }
  @media (max-width: 600px) {
    #releases details.release summary { padding: 16px 20px; gap: 12px; flex-wrap: wrap; }
    #releases details.release .body { padding: 4px 20px 22px; }
    #releases .latest-card { padding: 22px 22px; }
  }
"""


def render_release_card(version: str, date: Optional[str], body_html: str, *, is_latest: bool) -> str:
    badge = '<span class="badge">最新</span>' if is_latest else ""
    date_html = f'<span class="date">{html.escape(date)}</span>' if date else ""
    return f"""    <details class="release"{' open' if is_latest else ''}>
      <summary>
        <span class="v">v{html.escape(version)}</span>
        {badge}
        {date_html}
      </summary>
      <div class="body">
{body_html}
        <a class="permalink" href="whats-new/{html.escape(version)}.html">
          このリリースの専用ページを開く →
        </a>
      </div>
    </details>"""


def render_releases_section(entries: List[dict], latest_version: str) -> str:
    cards = "\n".join(
        render_release_card(
            e["version"], e.get("date"), e["body_html"], is_latest=e["version"] == latest_version
        )
        for e in entries
    )
    download_url = (
        f"https://github.com/IvyGain/Pasty/releases/latest/download/Pasty-{html.escape(latest_version)}.dmg"
    )
    return f"""<!-- ====================================================================
     RELEASE NOTES (auto-generated by scripts/build-pages.py — do not edit)
     ==================================================================== -->
<style>{RELEASES_SECTION_CSS}</style>
<section id="releases">
  <div class="container">
    <div class="head reveal">
      <h2 class="title">リリース<span class="accent" style="background: linear-gradient(120deg, var(--accent), var(--accent-2) 50%, var(--accent-3)); -webkit-background-clip: text; background-clip: text; color: transparent;">ノート</span></h2>
      <p class="lede">過去のリリースは、すべてここから辿れます。各バージョンの専用ページは検索エンジンからも直接開けるよう、固有 URL を発行しています。</p>
    </div>

    <div class="latest-card reveal">
      <div class="latest-meta">
        <span class="pill">最新版</span>
        <div class="ver">v{html.escape(latest_version)}</div>
        <div class="sys">macOS 14+ · Apple Silicon &amp; Intel · MIT</div>
      </div>
      <a class="btn primary" href="{download_url}"
         style="padding: 14px 24px; border-radius: 999px; font-size: 16px; font-weight: 600;
                background: linear-gradient(135deg, var(--accent), var(--accent-2));
                color: white; box-shadow: 0 12px 30px -8px rgba(99,102,241,0.55);
                display: inline-flex; align-items: center; gap: 10px; text-decoration: none;">
        macOS 14+ 用にダウンロード
        <small style="font-weight: 400; opacity: 0.8; font-size: 13px;">.dmg</small>
      </a>
    </div>

    <div class="release-list reveal">
{cards}
    </div>
  </div>
</section>
"""


# ---------------------------------------------------------------------------
# Hero auto-update — keeps docs/index.html top-of-page content fresh.
# ---------------------------------------------------------------------------

# Emoji prefix matcher for stripping ## headings into clean pill labels.
_EMOJI_PREFIX_RE = re.compile(
    r"^[\U0001F300-\U0001FAFF☀-➿⬀-⯿〰〽㊗㊙️‍]+\s*"
)

# Headings we never want to surface as marketing pills (internal/known-issue noise).
_PILL_EXCLUDE_KEYWORDS = (
    "内部改善",
    "既知の制約",
    "既知の不具合",
    "既知の問題",
    "Known issues",
)


def extract_hero_summary(md: str, *, max_sentences: int = 2) -> str:
    """Return the first 1-2 plain-text sentences after the H1 heading.

    Strips markdown formatting (links, code, emphasis) and keeps it short
    enough to fit the hero subtitle paragraph.
    """
    lines = md.replace("\r\n", "\n").split("\n")
    body: List[str] = []
    seen_h1 = False
    for line in lines:
        stripped = line.strip()
        if not seen_h1:
            if stripped.startswith("# "):
                seen_h1 = True
            continue
        if not stripped:
            if body:
                # End of first paragraph block — but accept a tagline ("...") line
                # plus the next paragraph if we only have one short line so far.
                joined = " ".join(body).strip()
                if len(joined) > 24:
                    break
                continue
        if stripped.startswith("#"):
            if body:
                break
            continue
        body.append(stripped)
    text = " ".join(body).strip()
    # Strip markdown emphasis/links/code.
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    # Split into sentences (Japanese 。 + Western .)
    sentences = re.split(r"(?<=[。.!?！？])\s*", text)
    sentences = [s.strip() for s in sentences if s.strip()]
    return "".join(sentences[:max_sentences]).strip()


def extract_hero_pills(md: str, *, max_pills: int = 4) -> List[str]:
    """Return the first N ## headings as plain-text pill labels (emoji stripped)."""
    pills: List[str] = []
    for line in md.replace("\r\n", "\n").split("\n"):
        m = re.match(r"^##\s+(.*\S)\s*$", line)
        if not m:
            continue
        label = m.group(1).strip()
        label = _EMOJI_PREFIX_RE.sub("", label).strip()
        # Many headings read "X を改善" / "X の刷新" — strip a trailing verb-y tail
        # to keep the pill snappy. Heuristic: cut at the first 「を」/「の」 followed
        # by 4+ chars; conservative — falls back to full label.
        if len(label) > 14:
            short = re.split(r"(?<=を)|(?<=の)", label, maxsplit=1)
            if short and len(short[0]) <= 14:
                label = short[0].rstrip("をの")
        if any(kw in label for kw in _PILL_EXCLUDE_KEYWORDS):
            continue
        if label and label not in pills:
            pills.append(label)
        if len(pills) >= max_pills:
            break
    return pills


def detect_dmg_size_mb(version: str) -> Optional[str]:
    """Return human-readable dmg size like '5.6 MB' for the latest release.

    Sources in priority order:
      1. dist/Pasty-<version>.dmg (local build)
      2. gh release view v<version> --json assets
      Returns None if neither is available; caller picks a fallback.
    """
    dmg_path = ROOT / "dist" / f"Pasty-{version}.dmg"
    if dmg_path.exists():
        size_bytes = dmg_path.stat().st_size
        return _human_size(size_bytes)
    # gh fallback
    try:
        out = subprocess.check_output(
            [
                "gh",
                "release",
                "view",
                f"v{version}",
                "--json",
                "assets",
                "-q",
                ".assets[] | select(.name | endswith(\".dmg\")) | .size",
            ],
            cwd=ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        )
        line = out.strip().splitlines()[0] if out.strip() else ""
        if line.isdigit():
            return _human_size(int(line))
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return None


def _human_size(n: int) -> str:
    mb = n / (1024 * 1024)
    if mb < 10:
        return f"{mb:.1f} MB"
    return f"{round(mb)} MB"


def build_hero_block(version: str, summary: str, pills: List[str], dmg_size: str) -> str:
    """Render the hero block (eyebrow + headline + subtitle + CTAs) HTML."""
    pill_segments = [f"v{version}"] + pills + ["MIT"]
    eyebrow = " · ".join(html.escape(p) for p in pill_segments)
    safe_summary = html.escape(summary)
    safe_size = html.escape(dmg_size)
    return (
        f'    <div class="reveal">\n'
        f'      <span class="eyebrow">{eyebrow}</span>\n'
        f'      <h1 class="headline">クリップボードを、<br/><span class="accent">倉庫に。</span></h1>\n'
        f'      <p class="subtitle">\n'
        f'        macOS のための、超軽量でローカルファーストなクリップボードマネージャ。下から出るカルーセルがメイン、ノッチが副メイン、Raycast 拡張がサード。{safe_summary}\n'
        f'      </p>\n'
        f'      <div class="ctas">\n'
        f'        <a class="btn primary" href="https://github.com/IvyGain/Pasty/releases/latest/download/Pasty.dmg">\n'
        f'          Pasty.dmg をダウンロード\n'
        f'          <small>· {safe_size} · macOS 14 以降</small>\n'
        f'        </a>\n'
        f'        <a class="btn ghost" href="#download">\n'
        f'          Raycast 拡張をインストール\n'
        f'          <small>· ワンライナーで簡単セットアップ</small>\n'
        f'        </a>\n'
        f'      </div>\n'
        f'\n'
        f'      <div class="hero-icon" aria-hidden="true">\n'
        f'        <img src="assets/icon-512.png" alt="Pasty のアプリアイコン" width="220" height="220" />\n'
        f'      </div>\n'
        f'    </div>'
    )


def build_hero_nav_block(version: str) -> str:
    """Render the top-nav "v0.x.y" chip link pointing at the releases section."""
    short = ".".join(version.lstrip("v").split("-")[0].split(".")[:2])
    return f'      <li><a href="#releases">v{html.escape(short)}</a></li>'


def build_download_card_block(version: str, dmg_size: str) -> str:
    """Render the macOS download card version + dmg-size lines."""
    return (
        f'            <h3>macOS アプリ</h3>\n'
        f'            <div style="color:var(--text-dim);font-size:13px;font-family:var(--mono)">v{html.escape(version)}</div>\n'
        f'          </div>\n'
        f'        </div>\n'
        f'        <p class="lede">dmg をダウンロード。<code style="font-family:var(--mono);font-size:0.9em">/Applications</code> にドラッグ。<code style="font-family:var(--mono);font-size:0.9em">⇧⌘V</code>。インストールは、それで全部です。</p>\n'
        f'        <div class="ctas">\n'
        f'          <a class="btn primary" href="https://github.com/IvyGain/Pasty/releases/latest/download/Pasty.dmg">\n'
        f'            Pasty.dmg をダウンロード\n'
        f'            <small>· {html.escape(dmg_size)}</small>\n'
        f'          </a>\n'
        f'        </div>'
    )


def build_raycast_rec_block(version: str) -> str:
    """Render the Raycast recommended-version badge line."""
    return f'          <span>Pasty v{html.escape(version)}+ 推奨</span>'


def _wrap_or_replace_block(
    text: str,
    begin: str,
    end: str,
    new_block: str,
    *,
    seed_pattern: str,
    label: str,
) -> tuple:
    """Replace the content between sentinels with new_block.

    If sentinels don't yet exist, auto-insert them by matching seed_pattern
    (a regex that captures the existing block in the file). Returns
    (new_text, changed).
    """
    if begin in text and end in text:
        pattern = re.compile(
            re.escape(begin) + r".*?" + re.escape(end),
            re.DOTALL,
        )
        replacement = f"{begin}\n{new_block}\n{end}"
        new_text, n = pattern.subn(replacement, text, count=1)
        if n != 1:
            sys.stderr.write(f"[build-pages] warn: failed to substitute {label} block\n")
            return text, False
        return new_text, new_text != text

    # First-run path: locate seed pattern and wrap.
    m = re.search(seed_pattern, text, re.DOTALL)
    if not m:
        sys.stderr.write(
            f"[build-pages] error: {label}: sentinels missing and seed pattern not matched\n"
        )
        return text, False
    seed = m.group(0)
    wrapped = f"{begin}\n{new_block}\n{end}"
    new_text = text.replace(seed, wrapped, 1)
    return new_text, True


_DEMO_CARD_VERSION_RE = re.compile(r"v0\.5\.0-beta(?= 出荷)")
_DEMO_CARD_VERSION_RE_2 = re.compile(r"Pasty v0\.5\.0-beta — クリップ編集 & 動画プレビュー")
_DEMO_CARD_VERSION_RE_3 = re.compile(r"今日 v0\.5\.0-beta 出荷")
_LEGACY_EYEBROW_RE = re.compile(r"v0\.5\.0-beta — 最新リリース")


def refresh_hero(version: str, summary: str, pills: List[str], dmg_size: str) -> bool:
    """Refresh the hero block, nav chip, download card, and raycast badge in
    docs/index.html. Idempotent: returns True on success, False on hard error.
    """
    if not INDEX_PATH.exists():
        sys.stderr.write(f"[build-pages] error: {INDEX_PATH} not found\n")
        return False
    text = INDEX_PATH.read_text(encoding="utf-8")
    original = text

    hero_block = build_hero_block(version, summary, pills, dmg_size)
    nav_block = build_hero_nav_block(version)
    download_block = build_download_card_block(version, dmg_size)
    raycast_block = build_raycast_rec_block(version)

    # ---- Demo-card literal refresh (decorative cards inside marketing copy) ----
    # These show example clip content with the current shipping version.
    text = _DEMO_CARD_VERSION_RE_3.sub(f"今日 v{version} 出荷", text)
    text = _DEMO_CARD_VERSION_RE_2.sub(
        f"Pasty v{version} — クリップ編集 & 動画プレビュー", text
    )
    # JS-side demo arrays (line ~2168, 2171)
    text = re.sub(
        r"'Pasty v0\.5\.0-beta — 出荷'",
        f"'Pasty v{version} — 出荷'",
        text,
    )
    text = re.sub(
        r'\{"version":"0\.5\.0-beta","license":"MIT"\}',
        f'{{"version":"{version}","license":"MIT"}}',
        text,
    )

    # ---- Legacy v0.5.0 "What's New" section -> generic feature showcase ----
    # The section's content (clip editing, URL auto-detect, video preview, Stack)
    # describes current product features and is still accurate; we just strip
    # the now-stale "v0.5.0-beta" version prefix so the section reads as a
    # timeless feature highlight rather than a release-specific callout.
    text = re.sub(
        r"<!-- WHAT'S NEW v0\.5\.0-beta =+\s*-->",
        "<!-- FEATURE HIGHLIGHTS — clip editing & previews ============================================ -->",
        text,
    )
    text = re.sub(
        r'<section id="whatsnew-v50">',
        '<section id="feature-highlights">',
        text,
    )
    text = re.sub(
        r'<span class="eyebrow">v0\.5\.0-beta — [^<]+</span>',
        '<span class="eyebrow">機能ハイライト</span>',
        text,
    )
    text = re.sub(
        r'<h2 class="section-title">v0\.5\.0-beta の新機能 — ',
        '<h2 class="section-title">編集できる倉庫 — ',
        text,
    )
    text = re.sub(
        r"v0\.5\.0-beta は「倉庫の中で完結する」ためのアップデートです。",
        "Pasty は「倉庫の中で完結する」ことを大事にしています。",
        text,
    )
    # Nav anchor — repoint legacy #whatsnew-v50 to the renamed section.
    text = re.sub(
        r'<li><a href="#whatsnew-v50">v0\.5\.0 の新機能</a></li>',
        '<li><a href="#feature-highlights">機能ハイライト</a></li>',
        text,
    )

    # Seed patterns: match the v0.5.0-baked-in markup as a one-time anchor.
    # On subsequent runs the sentinels exist and seed patterns are unused.
    HERO_SEED = (
        r'    <div class="reveal">\s*\n'
        r'      <span class="eyebrow">v[^<]+</span>\s*\n'
        r'      <h1 class="headline">クリップボードを、<br/><span class="accent">倉庫に。</span></h1>\s*\n'
        r'      <p class="subtitle">.*?</p>\s*\n'
        r'      <div class="ctas">.*?</div>\s*\n'
        r'\s*\n'
        r'      <div class="hero-icon"[^>]*>\s*\n'
        r'        <img src="assets/icon-512\.png"[^/]*/>\s*\n'
        r'      </div>\s*\n'
        r'    </div>'
    )
    NAV_SEED = r'      <li><a href="#whatsnew-v\d+">v\d+\.\d+(?:\.\d+)?</a></li>'
    DOWNLOAD_SEED = (
        r'            <h3>macOS アプリ</h3>\s*\n'
        r'            <div style="color:var\(--text-dim\);font-size:13px;font-family:var\(--mono\)">v[^<]+</div>\s*\n'
        r'          </div>\s*\n'
        r'        </div>\s*\n'
        r'        <p class="lede">dmg をダウンロード。.*?</p>\s*\n'
        r'        <div class="ctas">\s*\n'
        r'          <a class="btn primary" href="https://github\.com/IvyGain/Pasty/releases/latest/download/Pasty\.dmg">\s*\n'
        r'            Pasty\.dmg をダウンロード\s*\n'
        r'            <small>· [^<]+</small>\s*\n'
        r'          </a>\s*\n'
        r'        </div>'
    )
    RAYCAST_SEED = r'          <span>Pasty v[^<]+\+ 推奨</span>'

    text, _ = _wrap_or_replace_block(
        text, HERO_BEGIN, HERO_END, hero_block,
        seed_pattern=HERO_SEED, label="HERO",
    )
    text, _ = _wrap_or_replace_block(
        text, HERO_NAV_BEGIN, HERO_NAV_END, nav_block,
        seed_pattern=NAV_SEED, label="HERO_NAV",
    )
    text, _ = _wrap_or_replace_block(
        text, DOWNLOAD_CARD_BEGIN, DOWNLOAD_CARD_END, download_block,
        seed_pattern=DOWNLOAD_SEED, label="DOWNLOAD_CARD",
    )
    text, _ = _wrap_or_replace_block(
        text, RAYCAST_REC_BEGIN, RAYCAST_REC_END, raycast_block,
        seed_pattern=RAYCAST_SEED, label="RAYCAST_REC",
    )

    if text == original:
        sys.stderr.write("[build-pages] hero already up-to-date (no changes)\n")
        return True
    INDEX_PATH.write_text(text, encoding="utf-8")
    return True


# ---------------------------------------------------------------------------
# Main pipeline.
# ---------------------------------------------------------------------------


def collect_entries(latest_version: Optional[str]) -> tuple:
    """Return (entries, latest_version) where entries are newest-first dicts."""
    tags = git_tags()
    versions = []
    seen = set()

    # Always include latest_version (even if not tagged yet).
    if latest_version:
        if version_in_scope(latest_version) and latest_version not in seen:
            versions.append(latest_version)
            seen.add(latest_version)

    for tag in tags:
        v = tag.lstrip("v")
        if v in seen:
            continue
        if not version_in_scope(v):
            continue
        versions.append(v)
        seen.add(v)

    # Sort newest first by parsed tuple.
    versions.sort(key=lambda v: parse_version(v) or (0, 0, 0, ""), reverse=True)

    resolved_latest = latest_version or (versions[0] if versions else "0.0.0")

    entries = []
    fallbacks_used = []
    for v in versions:
        md = read_markdown(v)
        source = "markdown"
        if md is None:
            body = fetch_github_body(f"v{v}")
            if body:
                md = body
                source = "github"
                fallbacks_used.append((v, "github"))
            else:
                md = (
                    f"# Pasty v{v}\n\n"
                    "このバージョンのリリースノートはまだ公開されていません。"
                    f"詳細は [GitHub Releases](https://github.com/IvyGain/Pasty/releases/tag/v{v}) を参照してください。\n"
                )
                source = "placeholder"
                fallbacks_used.append((v, "placeholder"))

        body_html = markdown_to_html(md)
        date = fetch_release_date(f"v{v}")
        entries.append(
            {
                "version": v,
                "date": date,
                "body_html": body_html,
                "source": source,
            }
        )

    return entries, resolved_latest, fallbacks_used


def write_per_release_pages(entries: List[dict]) -> List[Path]:
    OUT_PER_RELEASE_DIR.mkdir(parents=True, exist_ok=True)
    written = []
    for e in entries:
        path = OUT_PER_RELEASE_DIR / f"{e['version']}.html"
        path.write_text(
            standalone_page(e["version"], e.get("date"), e["body_html"]),
            encoding="utf-8",
        )
        written.append(path)
    return written


def inject_index(section_html: str) -> bool:
    """Replace content between the sentinels in docs/index.html."""
    text = INDEX_PATH.read_text(encoding="utf-8")
    if SENTINEL_BEGIN not in text or SENTINEL_END not in text:
        sys.stderr.write(
            f"error: sentinels {SENTINEL_BEGIN} / {SENTINEL_END} not found in {INDEX_PATH}\n"
            "       Insert them manually around the desired location and re-run.\n"
        )
        return False

    pattern = re.compile(
        re.escape(SENTINEL_BEGIN) + r".*?" + re.escape(SENTINEL_END),
        re.DOTALL,
    )
    replacement = f"{SENTINEL_BEGIN}\n{section_html}\n{SENTINEL_END}"
    new_text = pattern.sub(replacement, text, count=1)
    if new_text == text:
        # Idempotent: rendered output identical to current file. Not an error —
        # release.sh may legitimately re-run with the same version and we don't
        # want to abort. Warn and succeed.
        sys.stderr.write("[build-pages] index.html already up-to-date (no changes)\n")
        return True
    INDEX_PATH.write_text(new_text, encoding="utf-8")
    return True


def detect_latest_from_info_plist() -> Optional[str]:
    tpl = ROOT / "scripts" / "Info.plist.template"
    if not tpl.exists():
        return None
    text = tpl.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>", text)
    if m:
        return m.group(1).strip()
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--latest-version",
        help="Latest version string (e.g. 0.8.1-beta). Defaults to Info.plist value.",
        default=None,
    )
    args = ap.parse_args()

    latest = args.latest_version or detect_latest_from_info_plist()
    if not latest:
        # Fall back to newest tag.
        tags = git_tags()
        if tags:
            latest = tags[0].lstrip("v")

    entries, latest, fallbacks = collect_entries(latest)
    print(f"[build-pages] latest = {latest}")
    print(f"[build-pages] entries = {[e['version'] for e in entries]}")
    if fallbacks:
        for v, kind in fallbacks:
            print(f"[build-pages]   fallback: {v} -> {kind}")

    written = write_per_release_pages(entries)
    print(f"[build-pages] wrote {len(written)} per-release pages under {OUT_PER_RELEASE_DIR}")

    section_html = render_releases_section(entries, latest)
    if not inject_index(section_html):
        return 1
    print(f"[build-pages] injected release section into {INDEX_PATH}")

    # Refresh the top-of-page hero block with content sourced from the latest md.
    latest_md = read_markdown(latest) or ""
    summary = extract_hero_summary(latest_md) if latest_md else ""
    pills = extract_hero_pills(latest_md) if latest_md else []
    if not summary:
        summary = f"v{latest} の最新アップデートはリリースノートをご覧ください。"
    if not pills:
        pills = ["クリップ編集", "URL 自動認識", "動画プレビュー", "Stack"]
    dmg_size = detect_dmg_size_mb(latest) or "5 MB"
    if not refresh_hero(latest, summary, pills, dmg_size):
        return 1
    print(f"[build-pages] refreshed hero block in {INDEX_PATH} (v{latest}, {dmg_size}, pills={pills})")

    # Sanity check: per the v0.8.2-beta hotfix spec, the page must contain
    # zero stale v0.5.0 references. (Authors of future release notes should
    # avoid the literal "v0.5.0" string in their markdown if it would land
    # here only as historical color — refer to "初期リリース" instead.)
    final = INDEX_PATH.read_text(encoding="utf-8")
    stale = final.count("v0.5.0")
    if stale and not latest.startswith("0.5.0"):
        # Show the offending lines for fast diagnosis.
        for i, line in enumerate(final.splitlines(), start=1):
            if "v0.5.0" in line:
                sys.stderr.write(f"  {i}: {line.strip()[:160]}\n")
        sys.stderr.write(
            f"[build-pages] error: {stale} stale 'v0.5.0' reference(s) remain in {INDEX_PATH}\n"
        )
        return 1
    print(f"[build-pages] hero freshness OK (no stale v0.5.0 references)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
