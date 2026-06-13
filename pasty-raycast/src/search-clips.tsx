import { List, Icon, Color } from "@raycast/api";
import { useState, useEffect, useMemo, useCallback } from "react";
import { ClipActions } from "./lib/actions";
import {
  recentClips,
  searchClips,
  pinboards,
  clipsInFolder,
  clipsByKind,
  dbExists,
  dbFile,
} from "./lib/db";
import {
  kindIcon,
  relativeTime,
  shortBytes,
  detailMarkdown,
  parseCreatedAt,
  GUIDE_LINES,
} from "./lib/format";
import type { ClipRow, PinboardRow } from "./lib/types";

/**
 * Filter value format:
 *   - "all"           = recent / search
 *   - "kind:image"    = filter by clip kind (text/image/link/file)
 *   - "folder:<id>"   = filter by pinboard id
 */
export default function Command() {
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<string>("all");
  const [clips, setClips] = useState<ClipRow[]>([]);
  const [folders, setFolders] = useState<PinboardRow[]>([]);
  const [loading, setLoading] = useState(false);
  // 配列で保持して「選択した順」を保持する。結合貼付もこの順序で連結される。
  const [selectedIds, setSelectedIds] = useState<number[]>([]);

  // Load folders once
  useEffect(() => {
    pinboards()
      .then(setFolders)
      .catch(() => setFolders([]));
  }, []);

  // Reload clips when query or filter changes
  useEffect(() => {
    setLoading(true);
    const run = async () => {
      try {
        if (filter.startsWith("folder:")) {
          setClips(await clipsInFolder(parseInt(filter.slice("folder:".length), 10)));
        } else if (filter.startsWith("kind:")) {
          const k = filter.slice("kind:".length) as "text" | "image" | "link" | "file";
          setClips(await clipsByKind(k, query));
        } else if (query.trim()) {
          setClips(await searchClips(query));
        } else {
          setClips(await recentClips());
        }
      } catch {
        setClips([]);
      } finally {
        setLoading(false);
      }
    };
    run();
  }, [query, filter]);

  const selectedClips = useMemo(
    () => selectedIds.map((id) => clips.find((c) => c.id === id)).filter((c): c is ClipRow => !!c),
    [clips, selectedIds],
  );

  const toggle = useCallback((id: number) => {
    setSelectedIds((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));
  }, []);

  const selectAll = useCallback(() => {
    setSelectedIds(clips.map((c) => c.id));
  }, [clips]);

  const clearSelection = useCallback(() => {
    setSelectedIds([]);
  }, []);

  // Empty state when DB is missing
  if (!dbExists()) {
    return (
      <List>
        <List.EmptyView
          title="Pasty が見つかりません"
          description={`SQLite が見つかりません: ${dbFile()}\nPasty.app をインストールしてから再度お試しください。`}
          icon={{ source: Icon.ExclamationMark, tintColor: Color.Yellow }}
        />
      </List>
    );
  }

  return (
    <List
      isShowingDetail
      isLoading={loading}
      searchBarPlaceholder="検索 — Space 選択 / Enter 貼付 / ⇧Enter 送信 / ⌥Enter 状態維持"
      onSearchTextChange={setQuery}
      throttle
      searchBarAccessory={
        <List.Dropdown tooltip="フィルター (種類 / フォルダ)" value={filter} onChange={setFilter}>
          <List.Dropdown.Item title="すべて (履歴)" value="all" icon={Icon.Clock} />
          <List.Dropdown.Section title="種類">
            <List.Dropdown.Item title="テキスト" value="kind:text" icon={Icon.Text} />
            <List.Dropdown.Item title="画像" value="kind:image" icon={Icon.Image} />
            <List.Dropdown.Item title="リンク" value="kind:link" icon={Icon.Link} />
            <List.Dropdown.Item title="ファイル" value="kind:file" icon={Icon.Document} />
          </List.Dropdown.Section>
          {folders.length > 0 && (
            <List.Dropdown.Section title="フォルダ">
              {folders.map((f) => (
                <List.Dropdown.Item
                  key={f.id}
                  title={f.name}
                  value={`folder:${f.id}`}
                  icon={{ source: Icon.Folder, tintColor: f.colorHex || Color.PrimaryText }}
                />
              ))}
            </List.Dropdown.Section>
          )}
        </List.Dropdown>
      }
      navigationTitle={selectedIds.length > 0 ? `${selectedIds.length} 件を選択中` : "Pasty"}
    >
      <List.EmptyView title="該当するクリップがありません" icon={Icon.MagnifyingGlass} />
      {clips.map((clip) => {
        const selectionOrder = selectedIds.indexOf(clip.id);
        const isSelected = selectionOrder >= 0;
        const accessories: List.Item.Accessory[] = [];
        if (isSelected) {
          // 選択順番号バッジ。順に 1, 2, 3, ... が振られる。
          accessories.push({
            tag: { value: `${selectionOrder + 1}`, color: Color.Green },
          });
        }
        accessories.push({ text: relativeTime(clip.createdAt) });
        if (clip.sourceAppName) accessories.push({ tag: clip.sourceAppName });
        return (
          <List.Item
            key={clip.id}
            id={String(clip.id)}
            icon={{
              source: kindIcon(clip.kind),
              tintColor: isSelected ? Color.Green : Color.PrimaryText,
            }}
            title={clip.preview.split("\n")[0].slice(0, 120) || "(empty)"}
            accessories={accessories}
            detail={
              <List.Item.Detail
                markdown={detailMarkdown(clip)}
                metadata={
                  <List.Item.Detail.Metadata>
                    <List.Item.Detail.Metadata.Label title="種類" text={clip.kind} />
                    <List.Item.Detail.Metadata.Label
                      title="サイズ"
                      text={shortBytes(clip.byteSize)}
                    />
                    {clip.sourceAppName && (
                      <List.Item.Detail.Metadata.Label title="ソース" text={clip.sourceAppName} />
                    )}
                    <List.Item.Detail.Metadata.Label
                      title="コピー時刻"
                      text={parseCreatedAt(clip.createdAt).toLocaleString("ja-JP")}
                    />
                    {selectedIds.length > 0 && (
                      <List.Item.Detail.Metadata.TagList title="選択中">
                        <List.Item.Detail.Metadata.TagList.Item
                          text={`${selectedIds.length} 件`}
                          color={Color.Green}
                        />
                      </List.Item.Detail.Metadata.TagList>
                    )}
                    <List.Item.Detail.Metadata.Separator />
                    <List.Item.Detail.Metadata.Label title="操作ガイド" text="" />
                    {GUIDE_LINES.map((line) => (
                      <List.Item.Detail.Metadata.Label key={line} title="" text={line} />
                    ))}
                  </List.Item.Detail.Metadata>
                }
              />
            }
            actions={
              <ClipActions
                clip={clip}
                selectedClips={selectedClips}
                onToggleSelect={toggle}
                onSelectAll={selectAll}
                onClearSelection={clearSelection}
                folders={folders}
                currentFolderId={filter}
                onChangeFolder={setFilter}
              />
            }
          />
        );
      })}
    </List>
  );
}
