import { Action, ActionPanel, Icon, Keyboard } from "@raycast/api";
import type { ClipRow } from "./types";
import {
  pasteAndClose,
  pasteAndStay,
  copyAndClose,
  pasteJoined,
  pasteSequenceStay,
} from "./multipaste";

interface Props {
  clip: ClipRow;
  selectedClips: ClipRow[]; // [] if none
  onToggleSelect: (id: number) => void;
  onSelectAll: () => void;
  onClearSelection: () => void;
}

export function ClipActions({
  clip,
  selectedClips,
  onToggleSelect,
  onSelectAll,
  onClearSelection,
}: Props) {
  const hasSelection = selectedClips.length > 0;
  return (
    <ActionPanel>
      <ActionPanel.Section title="Paste">
        <Action
          title="Paste & Close"
          icon={Icon.ArrowDownCircle}
          onAction={() => pasteAndClose(clip)}
        />
        <Action
          title="Paste & Stay (continuous)"
          icon={Icon.Repeat}
          shortcut={{ modifiers: ["opt"], key: "return" }}
          onAction={() => pasteAndStay(clip)}
        />
        {hasSelection && (
          <Action
            title={`Paste ${selectedClips.length} as a Single Block`}
            icon={Icon.Stack}
            shortcut={{ modifiers: ["cmd"], key: "return" }}
            onAction={() => pasteJoined(selectedClips)}
          />
        )}
        {hasSelection && (
          <Action
            title={`Paste ${selectedClips.length} in Sequence`}
            icon={Icon.List}
            shortcut={{ modifiers: ["cmd", "opt"], key: "return" }}
            onAction={() => pasteSequenceStay(selectedClips)}
          />
        )}
      </ActionPanel.Section>

      <ActionPanel.Section title="Copy">
        <Action
          title="Copy & Close"
          icon={Icon.Clipboard}
          shortcut={{ modifiers: ["cmd"], key: "c" } as Keyboard.Shortcut}
          onAction={() => copyAndClose(clip)}
        />
      </ActionPanel.Section>

      <ActionPanel.Section title="Selection">
        <Action
          title="Toggle Selection"
          icon={Icon.CheckCircle}
          shortcut={{ modifiers: [], key: "space" }}
          onAction={() => onToggleSelect(clip.id)}
        />
        <Action
          title="Select All"
          icon={Icon.CircleFilled}
          shortcut={{ modifiers: ["cmd"], key: "a" }}
          onAction={onSelectAll}
        />
        <Action
          title="Clear Selection"
          icon={Icon.Circle}
          shortcut={{ modifiers: ["cmd"], key: "d" }}
          onAction={onClearSelection}
        />
      </ActionPanel.Section>
    </ActionPanel>
  );
}
