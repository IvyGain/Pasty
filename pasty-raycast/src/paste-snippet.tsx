import { List, Icon, Color } from "@raycast/api";
import { useState, useEffect, useMemo, useCallback } from "react";
import { ClipActions } from "./lib/actions";
import { pinboards, clipsInFolder, dbExists, dbFile } from "./lib/db";
import { kindIcon, relativeTime, shortBytes, detailMarkdown, GUIDE_LINES } from "./lib/format";
import type { ClipRow, PinboardRow } from "./lib/types";

function isSnippetFolder(name: string): boolean {
  const k = name.toLowerCase();
  return name.includes("定型文") || k.includes("snippet") || k.includes("template");
}

export default function Command() {
  const [folders, setFolders] = useState<PinboardRow[]>([]);
  const [folderId, setFolderId] = useState<string>("");
  const [clips, setClips] = useState<ClipRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [selectedIds, setSelectedIds] = useState<number[]>([]);
  const [query, setQuery] = useState("");

  useEffect(() => {
    pinboards().then((all) => {
      const snippet = all.filter((b) => isSnippetFolder(b.name));
      const list = snippet.length > 0 ? snippet : all;
      setFolders(list);
      if (list[0]) setFolderId(String(list[0].id));
    });
  }, []);

  useEffect(() => {
    if (!folderId) return;
    setLoading(true);
    clipsInFolder(parseInt(folderId, 10))
      .then(setClips)
      .catch(() => setClips([]))
      .finally(() => setLoading(false));
  }, [folderId]);

  const filtered = useMemo(() => {
    if (!query.trim()) return clips;
    const q = query.toLowerCase();
    return clips.filter(
      (c) => c.preview.toLowerCase().includes(q) || (c.content ?? "").toLowerCase().includes(q),
    );
  }, [clips, query]);

  const selectedClips = useMemo(
    () =>
      selectedIds.map((id) => filtered.find((c) => c.id === id)).filter((c): c is ClipRow => !!c),
    [filtered, selectedIds],
  );

  const toggle = useCallback((id: number) => {
    setSelectedIds((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));
  }, []);

  const selectAll = useCallback(() => setSelectedIds(filtered.map((c) => c.id)), [filtered]);
  const clearSelection = useCallback(() => setSelectedIds([]), []);

  if (!dbExists()) {
    return (
      <List>
        <List.EmptyView
          title="Pasty が見つかりません"
          description={`DB が見つかりません: ${dbFile()}`}
          icon={Icon.ExclamationMark}
        />
      </List>
    );
  }

  return (
    <List
      isShowingDetail
      isLoading={loading}
      searchBarPlaceholder="定型文を検索 — Space で複数選択 / Enter で結合貼付"
      onSearchTextChange={setQuery}
      throttle
      searchBarAccessory={
        folders.length > 0 ? (
          <List.Dropdown tooltip="フォルダ" value={folderId} onChange={setFolderId}>
            {folders.map((f) => (
              <List.Dropdown.Item
                key={f.id}
                title={f.name}
                value={String(f.id)}
                icon={{ source: Icon.Folder, tintColor: f.colorHex || Color.PrimaryText }}
              />
            ))}
          </List.Dropdown>
        ) : undefined
      }
    >
      <List.EmptyView
        title="定型文が見つかりません"
        description="Pasty で定型文フォルダを作成すると、ここから直接呼び出せます。"
        icon={Icon.Document}
      />
      {filtered.map((clip) => {
        const selectionOrder = selectedIds.indexOf(clip.id);
        const isSelected = selectionOrder >= 0;
        const accessories: List.Item.Accessory[] = [];
        if (isSelected) {
          accessories.push({
            tag: { value: `${selectionOrder + 1}`, color: Color.Green },
          });
        }
        accessories.push({ text: relativeTime(clip.createdAt) });
        return (
          <List.Item
            key={clip.id}
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
                currentFolderId={folderId}
                onChangeFolder={setFolderId}
              />
            }
          />
        );
      })}
    </List>
  );
}
