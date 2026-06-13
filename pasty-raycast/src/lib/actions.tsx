import { Action, ActionPanel, Icon, Keyboard } from "@raycast/api";
import type { ClipRow, PinboardRow } from "./types";
import { pasteAndClose, pasteAndStay, copyAndClose, pasteJoined } from "./multipaste";

interface Props {
  clip: ClipRow;
  selectedClips: ClipRow[];
  onToggleSelect: (id: number) => void;
  onSelectAll: () => void;
  onClearSelection: () => void;
  /** Optional folder cycling — only render if both supplied. */
  folders?: PinboardRow[];
  currentFolderId?: string;
  onChangeFolder?: (folderId: string) => void;
}

/**
 * Shared action panel.
 *
 * Behavior summary:
 * - Enter: 選択が 2 件以上なら全て改行で繋いで貼付、それ以外は単一クリップを貼付
 * - ⌥Enter: 単一クリップを貼付して **画面を閉じない** (連続貼付モード)
 * - Space: 現在の項目を複数選択トグル (検索バーが空の時のみ反応)
 * - ⌘A / ⌘D: 全選択 / 解除
 * - ⌘C: クリップボードに置くだけ (貼付しない)
 * - ⌘[ / ⌘]: フォルダを前後に切替 (folders 引数がある場合のみ)
 */
export function ClipActions({
  clip,
  selectedClips,
  onToggleSelect,
  onSelectAll,
  onClearSelection,
  folders,
  currentFolderId,
  onChangeFolder,
}: Props) {
  const count = selectedClips.length;
  const multiMode = count >= 2;

  const defaultTitle = multiMode ? `Paste ${count} Clips (joined)` : "Paste";

  return (
    <ActionPanel>
      <ActionPanel.Section title="Paste">
        <Action
          title={defaultTitle}
          icon={multiMode ? Icon.Stack : Icon.ArrowDownCircle}
          onAction={() => (multiMode ? pasteJoined(selectedClips) : pasteAndClose(clip))}
        />
        <Action
          title="Paste & Stay (continuous)"
          icon={Icon.Repeat}
          shortcut={{ modifiers: ["opt"], key: "return" } as Keyboard.Shortcut}
          onAction={() => pasteAndStay(clip)}
        />
        {multiMode && (
          <Action
            title={`Paste ${count} in Sequence`}
            icon={Icon.List}
            shortcut={{ modifiers: ["cmd", "opt"], key: "return" } as Keyboard.Shortcut}
            onAction={() => pasteJoined(selectedClips)}
          />
        )}
      </ActionPanel.Section>

      <ActionPanel.Section title="Selection">
        <Action
          title="Toggle Selection"
          icon={Icon.CheckCircle}
          shortcut={{ modifiers: [], key: "space" } as Keyboard.Shortcut}
          onAction={() => onToggleSelect(clip.id)}
        />
        <Action
          title="Select All"
          icon={Icon.CircleFilled}
          shortcut={{ modifiers: ["cmd"], key: "a" } as Keyboard.Shortcut}
          onAction={onSelectAll}
        />
        <Action
          title="Clear Selection"
          icon={Icon.Circle}
          shortcut={{ modifiers: ["cmd"], key: "d" } as Keyboard.Shortcut}
          onAction={onClearSelection}
        />
      </ActionPanel.Section>

      <ActionPanel.Section title="Clipboard">
        <Action
          title="Copy to Clipboard"
          icon={Icon.Clipboard}
          shortcut={{ modifiers: ["cmd"], key: "c" } as Keyboard.Shortcut}
          onAction={() => copyAndClose(clip)}
        />
      </ActionPanel.Section>

      {folders && folders.length > 1 && onChangeFolder && currentFolderId !== undefined && (
        <ActionPanel.Section title="Folder">
          <Action
            title="Previous Folder"
            icon={Icon.ArrowLeft}
            shortcut={{ modifiers: ["cmd"], key: "[" } as Keyboard.Shortcut}
            onAction={() => onChangeFolder(prevFolderId(folders, currentFolderId))}
          />
          <Action
            title="Next Folder"
            icon={Icon.ArrowRight}
            shortcut={{ modifiers: ["cmd"], key: "]" } as Keyboard.Shortcut}
            onAction={() => onChangeFolder(nextFolderId(folders, currentFolderId))}
          />
        </ActionPanel.Section>
      )}
    </ActionPanel>
  );
}

function nextFolderId(folders: PinboardRow[], current: string): string {
  const ids = ["all", ...folders.map((f) => String(f.id))];
  const idx = ids.indexOf(current);
  return ids[(idx + 1 + ids.length) % ids.length];
}

function prevFolderId(folders: PinboardRow[], current: string): string {
  const ids = ["all", ...folders.map((f) => String(f.id))];
  const idx = ids.indexOf(current);
  return ids[(idx - 1 + ids.length) % ids.length];
}
