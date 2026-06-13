import { Clipboard, closeMainWindow, showHUD } from "@raycast/api";
import type { ClipRow } from "./types";

export async function pasteAndClose(clip: ClipRow) {
  await Clipboard.paste(rawText(clip));
  await closeMainWindow({ clearRootSearch: true });
}

export async function pasteAndStay(clip: ClipRow) {
  await Clipboard.paste(rawText(clip));
  await showHUD(`Pasted: ${truncate(clip.preview, 32)}`);
}

export async function copyAndClose(clip: ClipRow) {
  await Clipboard.copy(rawText(clip));
  await closeMainWindow({ clearRootSearch: true });
}

export async function pasteJoined(clips: ClipRow[], separator = "\n") {
  if (clips.length === 0) return;
  const merged = clips.map(rawText).join(separator);
  await Clipboard.paste(merged);
  await closeMainWindow({ clearRootSearch: true });
}

export async function pasteSequenceStay(clips: ClipRow[], delayMs = 120) {
  for (const c of clips) {
    await Clipboard.paste(rawText(c));
    await new Promise((r) => setTimeout(r, delayMs));
  }
  await showHUD(`Pasted ${clips.length} clips`);
}

function rawText(c: ClipRow): string {
  return c.content ?? c.preview ?? "";
}

function truncate(s: string, n: number): string {
  return s.length <= n ? s : s.slice(0, n - 1) + "…";
}
