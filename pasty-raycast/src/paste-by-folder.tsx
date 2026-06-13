import { List, Icon, Color, Action, ActionPanel, useNavigation } from "@raycast/api";
import { useState, useEffect, useMemo, useCallback } from "react";
import { ClipActions } from "./lib/actions";
import { pinboards, clipsInFolder, dbExists, dbFile } from "./lib/db";
import { kindIcon, relativeTime, shortBytes, detailMarkdown, GUIDE_LINES } from "./lib/format";
import type { ClipRow, PinboardRow } from "./lib/types";

export default function Command() {
  const [folders, setFolders] = useState<PinboardRow[]>([]);
  const [loading, setLoading] = useState(true);
  const { push } = useNavigation();

  useEffect(() => {
    pinboards()
      .then(setFolders)
      .catch(() => setFolders([]))
      .finally(() => setLoading(false));
  }, []);

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
    <List isLoading={loading} searchBarPlaceholder="フォルダを検索…">
      <List.EmptyView
        title="フォルダがありません"
        description="Pasty でフォルダを作成すると、ここに表示されます。"
        icon={Icon.Folder}
      />
      {folders.map((f) => (
        <List.Item
          key={f.id}
          icon={{ source: Icon.Folder, tintColor: f.colorHex || Color.PrimaryText }}
          title={f.name}
          actions={
            <ActionPanel>
              <Action
                title={`${f.name} を開く`}
                icon={Icon.ArrowRightCircle}
                onAction={() => push(<FolderClips folder={f} />)}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}

function FolderClips({ folder }: { folder: PinboardRow }) {
  const [clips, setClips] = useState<ClipRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set());
  const [query, setQuery] = useState("");

  useEffect(() => {
    clipsInFolder(folder.id)
      .then(setClips)
      .catch(() => setClips([]))
      .finally(() => setLoading(false));
  }, [folder.id]);

  const filtered = useMemo(() => {
    if (!query.trim()) return clips;
    const q = query.toLowerCase();
    return clips.filter(
      (c) => c.preview.toLowerCase().includes(q) || (c.content ?? "").toLowerCase().includes(q),
    );
  }, [clips, query]);

  const selectedClips = useMemo(
    () => filtered.filter((c) => selectedIds.has(c.id)),
    [filtered, selectedIds],
  );

  const toggle = useCallback((id: number) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);
  const selectAll = useCallback(
    () => setSelectedIds(new Set(filtered.map((c) => c.id))),
    [filtered],
  );
  const clearSelection = useCallback(() => setSelectedIds(new Set()), []);

  return (
    <List
      isShowingDetail
      isLoading={loading}
      searchBarPlaceholder={`${folder.name} を検索…`}
      onSearchTextChange={setQuery}
      throttle
      navigationTitle={folder.name}
    >
      <List.EmptyView title="このフォルダは空です" icon={Icon.Folder} />
      {filtered.map((clip) => {
        const isSelected = selectedIds.has(clip.id);
        const accessories: List.Item.Accessory[] = [];
        if (isSelected)
          accessories.push({ icon: { source: Icon.CheckCircle, tintColor: Color.Green } });
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
              />
            }
          />
        );
      })}
    </List>
  );
}
