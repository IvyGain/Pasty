import { Action, ActionPanel, Icon, Keyboard } from "@raycast/api";
import type { ClipRow, PinboardRow } from "./types";
import {
  pasteAndClose,
  pasteAndKeepState,
  pasteAndSubmit,
  pasteSubmitAndKeepState,
  pasteJoined,
  pasteJoinedAndKeepState,
  copyAndClose,
} from "./multipaste";

interface Props {
  clip: ClipRow;
  selectedClips: ClipRow[];
  onToggleSelect: (id: number) => void;
  onSelectAll: () => void;
  onClearSelection: () => void;
  folders?: PinboardRow[];
  currentFolderId?: string;
  onChangeFolder?: (folderId: string) => void;
}

/**
 * Shared action panel.
 *
 * Keys (single clip):
 *  - Enter      : 貼付 + 閉じる
 *  - ⌥Enter     : 貼付 + 状態維持 (次回 ⌘Space で続行)
 *  - ⇧Enter     : 貼付 + 末尾 Enter (Slack/Discord で送信)
 *  - ⌥⇧Enter    : 貼付 + 末尾 Enter + 状態維持
 *  - ⌘C         : クリップボードに置くだけ
 *
 * Keys (multi-select, ≥ 2 件):
 *  - Enter      : 改行で結合 + 末尾改行 → 1 度に貼付
 *  - ⌥Enter     : 同上 + 状態維持
 *  - ⌘Enter     : 同上 (selection 強制)
 *
 * Keys (selection):
 *  - Space      : 選択トグル
 *  - ⌘A / ⌘D    : 全選択 / 解除
 *
 * Keys (folder):
 *  - Tab / ⇧Tab : フォルダ前後切替 (Tab が動かない場合 ⌘] / ⌘[ にフォールバック)
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
  const multi = count >= 2;

  return (
    <ActionPanel>
      <ActionPanel.Section title="Paste">
        <Action
          title={multi ? `Paste ${count} Clips (joined)` : "Paste"}
          icon={multi ? Icon.Stack : Icon.ArrowDownCircle}
          onAction={() => (multi ? pasteJoined(selectedClips) : pasteAndClose(clip))}
        />
        <Action
          title={multi ? `Paste ${count} & Keep State` : "Paste & Keep State"}
          icon={Icon.Repeat}
          shortcut={{ modifiers: ["opt"], key: "return" } as Keyboard.Shortcut}
          onAction={() =>
            multi ? pasteJoinedAndKeepState(selectedClips) : pasteAndKeepState(clip)
          }
        />
        <Action
          title="Paste & Submit (append Enter)"
          icon={Icon.Reply}
          shortcut={{ modifiers: ["shift"], key: "return" } as Keyboard.Shortcut}
          onAction={() => pasteAndSubmit(clip)}
        />
        <Action
          title="Paste, Submit & Keep State"
          icon={Icon.Forward}
          shortcut={{ modifiers: ["opt", "shift"], key: "return" } as Keyboard.Shortcut}
          onAction={() => pasteSubmitAndKeepState(clip)}
        />
        {multi && (
          <Action
            title={`Paste ${count} as a Single Block`}
            icon={Icon.Stack}
            shortcut={{ modifiers: ["cmd"], key: "return" } as Keyboard.Shortcut}
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
          <Action
            title="Previous Folder (tab)"
            icon={Icon.ArrowLeft}
            shortcut={{ modifiers: ["shift"], key: "tab" } as Keyboard.Shortcut}
            onAction={() => onChangeFolder(prevFolderId(folders, currentFolderId))}
          />
          <Action
            title="Next Folder (tab)"
            icon={Icon.ArrowRight}
            shortcut={{ modifiers: [], key: "tab" } as Keyboard.Shortcut}
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
