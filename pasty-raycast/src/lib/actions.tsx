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

  // 複数選択時のペーストが終わったら選択をクリアして、
  // 状態維持モード (⌥Enter) で再表示しても古い選択が残らないようにする。
  const pasteDefault = () => {
    if (multi) {
      const targets = [...selectedClips];
      onClearSelection();
      pasteJoined(targets);
    } else {
      pasteAndClose(clip);
    }
  };
  const pasteKeep = () => {
    if (multi) {
      const targets = [...selectedClips];
      onClearSelection();
      pasteJoinedAndKeepState(targets);
    } else {
      pasteAndKeepState(clip);
    }
  };

  return (
    <ActionPanel>
      <ActionPanel.Section title="Paste">
        <Action
          title={multi ? `Paste ${count} Clips (joined)` : "Paste"}
          icon={multi ? Icon.Stack : Icon.ArrowDownCircle}
          onAction={pasteDefault}
        />
        <Action
          title={multi ? `Paste ${count} & Keep State` : "Paste & Keep State"}
          icon={Icon.Repeat}
          shortcut={{ modifiers: ["opt"], key: "return" } as Keyboard.Shortcut}
          onAction={pasteKeep}
        />
        <Action
          // 末尾に改行を追加して貼付。Slack / Discord / iMessage で
          // 「貼付 → 送信」を 1 アクションで完了させるショートカット。
          title="Paste + Send (append Return)"
          icon={Icon.Reply}
          shortcut={{ modifiers: ["shift"], key: "return" } as Keyboard.Shortcut}
          onAction={() => pasteAndSubmit(clip)}
        />
        <Action
          title="Paste + Send & Keep State"
          icon={Icon.Forward}
          shortcut={{ modifiers: ["opt", "shift"], key: "return" } as Keyboard.Shortcut}
          onAction={() => pasteSubmitAndKeepState(clip)}
        />
        {multi && (
          <Action
            title={`Paste ${count} as a Single Block`}
            icon={Icon.Stack}
            shortcut={{ modifiers: ["cmd"], key: "return" } as Keyboard.Shortcut}
            onAction={() => {
              const targets = [...selectedClips];
              onClearSelection();
              pasteJoined(targets);
            }}
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

      {folders && onChangeFolder && currentFolderId !== undefined && (
        <ActionPanel.Section title="Filter">
          <Action
            title="Previous Filter"
            icon={Icon.ArrowLeft}
            shortcut={{ modifiers: ["cmd"], key: "[" } as Keyboard.Shortcut}
            onAction={() => onChangeFolder(prevFilterId(folders, currentFolderId))}
          />
          <Action
            title="Next Filter"
            icon={Icon.ArrowRight}
            shortcut={{ modifiers: ["cmd"], key: "]" } as Keyboard.Shortcut}
            onAction={() => onChangeFolder(nextFilterId(folders, currentFolderId))}
          />
        </ActionPanel.Section>
      )}
    </ActionPanel>
  );
}

/**
 * Filter ids in cycle order:
 *   "all" → kind:text → kind:image → kind:link → kind:file → folder:<id1> → folder:<id2> ...
 */
function allFilterIds(folders: PinboardRow[]): string[] {
  return [
    "all",
    "kind:text",
    "kind:image",
    "kind:link",
    "kind:file",
    ...folders.map((f) => `folder:${f.id}`),
  ];
}

function nextFilterId(folders: PinboardRow[], current: string): string {
  const ids = allFilterIds(folders);
  const idx = ids.indexOf(current);
  return ids[(idx + 1 + ids.length) % ids.length];
}

function prevFilterId(folders: PinboardRow[], current: string): string {
  const ids = allFilterIds(folders);
  const idx = ids.indexOf(current);
  return ids[(idx - 1 + ids.length) % ids.length];
}
