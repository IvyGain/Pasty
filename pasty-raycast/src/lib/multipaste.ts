import { Clipboard, closeMainWindow, PopToRootType, showHUD } from "@raycast/api";
import type { ClipRow } from "./types";

/**
 * Paste helpers for the Pasty Raycast extension.
 *
 * Naming convention:
 *  - `*AndClose`    — paste then let Raycast pop back to root (default)
 *  - `*AndKeepState` — paste with `PopToRootType.Suspended` so the next time the
 *                     user reopens this command (⌘Space → P → Enter), the list,
 *                     cursor and multi-select state are still there. Effectively
 *                     the "stay open" experience: Raycast hides for the paste but
 *                     does not reset.
 *  - `*Submit`      — appends "\n" to the pasted text so the receiving app
 *                     (Slack / Discord / iMessage) sends the message immediately.
 */

function rawText(c: ClipRow): string {
  return c.content ?? c.preview ?? "";
}

function truncate(s: string, n: number): string {
  return s.length <= n ? s : s.slice(0, n - 1) + "…";
}

// === Single clip ===

export async function pasteAndClose(clip: ClipRow) {
  await Clipboard.paste(rawText(clip));
}

export async function pasteAndKeepState(clip: ClipRow) {
  await closeMainWindow({ popToRootType: PopToRootType.Suspended });
  await Clipboard.paste(rawText(clip));
  await showHUD(`Pasted: ${truncate(clip.preview, 40)} — ⌘Space で続行`);
}

export async function pasteAndSubmit(clip: ClipRow) {
  await Clipboard.paste(rawText(clip) + "\n");
}

export async function pasteSubmitAndKeepState(clip: ClipRow) {
  await closeMainWindow({ popToRootType: PopToRootType.Suspended });
  await Clipboard.paste(rawText(clip) + "\n");
  await showHUD(`Sent: ${truncate(clip.preview, 40)} — ⌘Space で続行`);
}

export async function copyAndClose(clip: ClipRow) {
  await Clipboard.copy(rawText(clip));
}

// === Multi-clip ===

/** Join with newlines + trailing newline so the receiver "sends" each line. */
export async function pasteJoined(clips: ClipRow[]) {
  if (clips.length === 0) return;
  const merged = clips.map(rawText).join("\n") + "\n";
  await Clipboard.paste(merged);
}

export async function pasteJoinedAndKeepState(clips: ClipRow[]) {
  if (clips.length === 0) return;
  await closeMainWindow({ popToRootType: PopToRootType.Suspended });
  const merged = clips.map(rawText).join("\n") + "\n";
  await Clipboard.paste(merged);
  await showHUD(`Pasted ${clips.length} clips — ⌘Space で続行`);
}
