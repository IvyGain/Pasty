import { Grid, Icon, Color, Action, ActionPanel } from "@raycast/api";
import { useState, useEffect } from "react";
import { recentImages, dbExists, dbFile } from "./lib/db";
import { imageFilePath, relativeTime, shortBytes } from "./lib/format";
import { pasteAndClose, pasteAndStay, copyAndClose } from "./lib/multipaste";
import type { ClipRow } from "./lib/types";

export default function Command() {
  const [images, setImages] = useState<ClipRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState("");

  useEffect(() => {
    recentImages()
      .then(setImages)
      .catch(() => setImages([]))
      .finally(() => setLoading(false));
  }, []);

  if (!dbExists()) {
    return (
      <Grid>
        <Grid.EmptyView
          title="Pasty が見つかりません"
          description={`DB が見つかりません: ${dbFile()}`}
          icon={Icon.ExclamationMark}
        />
      </Grid>
    );
  }

  const filtered = query.trim()
    ? images.filter((c) =>
        (c.preview + " " + (c.sourceAppName ?? "")).toLowerCase().includes(query.toLowerCase()),
      )
    : images;

  return (
    <Grid
      isLoading={loading}
      columns={4}
      aspectRatio="4/3"
      fit={Grid.Fit.Fill}
      searchBarPlaceholder="画像を検索 — Enter で貼付 / ⌥Enter で連続貼付 / ⌘K で全アクション"
      onSearchTextChange={setQuery}
      throttle
    >
      <Grid.EmptyView title="画像クリップがありません" icon={Icon.Image} />
      {filtered.map((clip) => {
        const path = imageFilePath(clip);
        return (
          <Grid.Item
            key={clip.id}
            content={
              path ? { source: path } : { source: Icon.Image, tintColor: Color.SecondaryText }
            }
            title={clip.preview.split("\n")[0].slice(0, 60) || "(empty)"}
            subtitle={`${relativeTime(clip.createdAt)} · ${shortBytes(clip.byteSize)}`}
            actions={
              <ActionPanel>
                <Action
                  title="Paste & Close"
                  icon={Icon.ArrowDownCircle}
                  onAction={() => pasteAndClose(clip)}
                />
                <Action
                  title="Paste & Stay"
                  icon={Icon.Repeat}
                  shortcut={{ modifiers: ["opt"], key: "return" }}
                  onAction={() => pasteAndStay(clip)}
                />
                <Action
                  title="Copy & Close"
                  icon={Icon.Clipboard}
                  shortcut={{ modifiers: ["cmd"], key: "c" }}
                  onAction={() => copyAndClose(clip)}
                />
              </ActionPanel>
            }
          />
        );
      })}
    </Grid>
  );
}
