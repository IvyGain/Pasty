import { List, Icon, Color } from "@raycast/api";
import { useState, useEffect, useMemo, useCallback } from "react";
import { ClipActions } from "./lib/actions";
import { recentClips, searchClips, pinboards, clipsInFolder, dbExists, dbFile } from "./lib/db";
import { kindIcon, relativeTime, shortBytes, detailMarkdown } from "./lib/format";
import type { ClipRow, PinboardRow } from "./lib/types";

export default function Command() {
  const [query, setQuery] = useState("");
  const [folderId, setFolderId] = useState<string>("all"); // "all" or string of pinboard id
  const [clips, setClips] = useState<ClipRow[]>([]);
  const [folders, setFolders] = useState<PinboardRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set());

  // Load folders once
  useEffect(() => {
    pinboards()
      .then(setFolders)
      .catch(() => setFolders([]));
  }, []);

  // Reload clips when query or folder changes
  useEffect(() => {
    setLoading(true);
    const run = async () => {
      try {
        if (folderId !== "all") {
          setClips(await clipsInFolder(parseInt(folderId, 10)));
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
  }, [query, folderId]);

  const selectedClips = useMemo(
    () => clips.filter((c) => selectedIds.has(c.id)),
    [clips, selectedIds],
  );

  const toggle = useCallback((id: number) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  const selectAll = useCallback(() => {
    setSelectedIds(new Set(clips.map((c) => c.id)));
  }, [clips]);

  const clearSelection = useCallback(() => {
    setSelectedIds(new Set());
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
      searchBarPlaceholder="クリップを検索…"
      onSearchTextChange={setQuery}
      throttle
      searchBarAccessory={
        <List.Dropdown tooltip="フォルダ" value={folderId} onChange={setFolderId}>
          <List.Dropdown.Item title="すべて (履歴)" value="all" icon={Icon.Clock} />
          {folders.map((f) => (
            <List.Dropdown.Item
              key={f.id}
              title={f.name}
              value={String(f.id)}
              icon={{ source: Icon.Circle, tintColor: f.colorHex || Color.PrimaryText }}
            />
          ))}
        </List.Dropdown>
      }
      navigationTitle={selectedIds.size > 0 ? `${selectedIds.size} 件を選択中` : "Pasty"}
    >
      <List.EmptyView title="該当するクリップがありません" icon={Icon.MagnifyingGlass} />
      {clips.map((clip) => {
        const isSelected = selectedIds.has(clip.id);
        const accessories: List.Item.Accessory[] = [];
        if (isSelected)
          accessories.push({ icon: { source: Icon.CheckCircle, tintColor: Color.Green } });
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
                      text={new Date(clip.createdAt * 1000).toLocaleString("ja-JP")}
                    />
                    {selectedIds.size > 0 && (
                      <List.Item.Detail.Metadata.TagList title="選択中">
                        <List.Item.Detail.Metadata.TagList.Item
                          text={`${selectedIds.size} 件`}
                          color={Color.Green}
                        />
                      </List.Item.Detail.Metadata.TagList>
                    )}
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
              />
            }
          />
        );
      })}
    </List>
  );
}
