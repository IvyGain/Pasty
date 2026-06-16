#!/usr/bin/env python3
"""
CC AGI マネージャー / セールスオプスの定型文 (.md) を Pasty インポート形式
(PastyExportArchive JSON, version 1) に変換する。

使い方:
    python3 scripts/import-sales-ops.py \
        --src ~/CCAGIManager/docs/sales-ops/templates \
        --out ~/Desktop/CC_sales_snippets.pasty.json

出力:
    PastyExportArchive (Codable) と完全互換の JSON 1 ファイル。
    Pasty の 設定 → プライバシー → "JSON からインポート" で読み込める。
"""

from __future__ import annotations
import argparse
import hashlib
import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# サブフォルダ → ピンボード名・色のマッピング
FOLDER_MAP: dict[str, tuple[str, str]] = {
    "A_workshop":     ("セールス: ワークショップ", "#7CF88C"),
    "B_certification":("セールス: 認定",           "#7C8CF8"),
    "C_upgrade":      ("セールス: アップグレード", "#F8AA7C"),
    "D_jutaku":       ("セールス: 受託",           "#F87CE0"),
    "common":         ("セールス: 共通",           "#FFD56B"),
    "partner":        ("セールス: パートナー",     "#7CDFF8"),
}

# 索引ファイルは除外
SKIP_FILES = {"00_index.md", "00_README_運用ガイド.md"}

ISO = "%Y-%m-%dT%H:%M:%S.%fZ"


@dataclass
class Clip:
    id: int
    createdAt: str
    kind: str
    preview: str
    content: str
    byteSize: int
    contentHash: str
    sourceAppName: str
    sourceBundleId: Optional[str] = None
    imageDataBase64: Optional[str] = None


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime(ISO)


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def extract_email_body(md_text: str) -> Optional[str]:
    """
    最初の ```text ... ``` または ```email ... ``` フェンスドコードブロックの中身を返す。
    無ければ None。"""
    pattern = re.compile(r"```(?:text|email|markdown)?\n(.*?)```", re.DOTALL)
    m = pattern.search(md_text)
    if m:
        return m.group(1).strip()
    return None


def title_from_filename(path: Path) -> str:
    """ファイル名から拡張子と先頭の連番を落としたタイトル。"""
    stem = path.stem
    # 先頭の "01_" や "S3_" を削る
    stem = re.sub(r"^([0-9]{1,2}|[A-Z]\d?)[_\-]", "", stem)
    return stem


def preview_for(content: str, fallback: str) -> str:
    """最初の非空行 (件名行優先) を 120 文字以内で返す。"""
    for line in content.splitlines():
        s = line.strip()
        if not s:
            continue
        # "件名:" 行があれば優先
        if s.startswith("件名:") or s.startswith("件名："):
            return s[:120]
        return s[:120]
    return fallback[:120]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, type=Path,
                    help="sales-ops/templates のパス")
    ap.add_argument("--out", required=True, type=Path,
                    help="出力 JSON のパス (.pasty.json)")
    args = ap.parse_args()

    src_root: Path = args.src.expanduser()
    if not src_root.is_dir():
        raise SystemExit(f"src not found: {src_root}")

    pinboards: list[dict] = []
    clips: list[Clip] = []
    pinboard_items: list[dict] = []

    next_clip_id = 1
    next_pin_id = 1
    common_now = now_iso()

    for folder in sorted(src_root.iterdir()):
        if not folder.is_dir():
            continue
        if folder.name not in FOLDER_MAP:
            print(f"  ! skip unknown folder: {folder.name}")
            continue
        folder_label, folder_color = FOLDER_MAP[folder.name]

        # 該当フォルダで md ファイルを順番に処理
        md_files = sorted(folder.glob("*.md"))
        md_files = [p for p in md_files if p.name not in SKIP_FILES]
        if not md_files:
            continue

        pin_id = next_pin_id
        next_pin_id += 1
        pinboards.append({
            "id": pin_id,
            "name": folder_label,
            "colorHex": folder_color,
            "sortOrder": pin_id,
            "createdAt": common_now,
        })

        sort_order = 0
        for md in md_files:
            raw = md.read_text(encoding="utf-8")
            body = extract_email_body(raw) or raw.strip()
            preview = preview_for(body, title_from_filename(md))

            clip = Clip(
                id=next_clip_id,
                createdAt=common_now,
                kind="text",
                preview=preview,
                content=body,
                byteSize=len(body.encode("utf-8")),
                contentHash=sha256(body),
                sourceAppName="CC AGI Sales Ops",
                sourceBundleId="io.cc.sales-ops",
            )
            clips.append(clip)
            # フォルダ内表示名 (`pinboard_items.title`)。ファイル名から拡張子と
            # 連番を取り除いた値を使う。これが Strip カードのバナーに表示される。
            display_title = title_from_filename(md)
            pinboard_items.append({
                "pinboardId": pin_id,
                "clipId": next_clip_id,
                "sortOrder": sort_order,
                "title": display_title,
            })
            sort_order += 1
            next_clip_id += 1
            print(f"  + {folder.name}/{md.name} → '{preview[:40]}…'")

    archive = {
        "version": 1,
        "exportedAt": common_now,
        "appVersion": "import-sales-ops-script",
        "clips": [c.__dict__ for c in clips],
        "pinboards": pinboards,
        "pinboardItems": pinboard_items,
    }

    out_path: Path = args.out.expanduser()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(archive, ensure_ascii=False, indent=2),
                        encoding="utf-8")

    print()
    print(f"✅ Wrote {out_path}")
    print(f"   pinboards: {len(pinboards)}")
    print(f"   clips: {len(clips)}")
    print(f"   pinboard_items: {len(pinboard_items)}")
    print()
    print("Pasty 設定 → プライバシー → 「JSON からインポート」で読み込めます。")


if __name__ == "__main__":
    main()
