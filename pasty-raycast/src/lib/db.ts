import { executeSQL } from "@raycast/utils";
import { getPreferenceValues } from "@raycast/api";
import { homedir } from "os";
import { join } from "path";
import { existsSync } from "fs";
import type { ClipRow, PinboardRow } from "./types";

interface Prefs {
  dbPath?: string;
  pageSize?: string;
}

export function dbFile(): string {
  const custom = getPreferenceValues<Prefs>().dbPath?.trim();
  if (custom && custom.length > 0) return custom.replace(/^~/, homedir());
  return join(homedir(), "Library", "Application Support", "Pasty", "clips.sqlite");
}

export function dbExists(): boolean {
  return existsSync(dbFile());
}

export function pageSize(): number {
  const v = parseInt(getPreferenceValues<Prefs>().pageSize ?? "200", 10);
  return Number.isFinite(v) ? v : 200;
}

const COLS = "id, kind, preview, content, dataPath, sourceBundleId, sourceAppName, byteSize, createdAt";

async function withRetry<T>(fn: () => Promise<T>, retries = 3): Promise<T> {
  for (let attempt = 0; attempt < retries; attempt++) {
    try { return await fn(); }
    catch (e) {
      const msg = String((e as Error).message || e);
      if (!msg.includes("SQLITE_BUSY") || attempt === retries - 1) throw e;
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  throw new Error("withRetry exhausted");
}

export async function recentClips(limit = pageSize()): Promise<ClipRow[]> {
  return withRetry(() => executeSQL<ClipRow>(dbFile(),
    `SELECT ${COLS} FROM clip_items ORDER BY createdAt DESC LIMIT ${limit};`));
}

export async function searchClips(q: string): Promise<ClipRow[]> {
  const trimmed = q.trim();
  if (!trimmed) return recentClips();
  // Match against the FTS5 search table (clip_search) if it exists, fall back to LIKE.
  try {
    return await withRetry(() => executeSQL<ClipRow>(dbFile(),
      `SELECT c.${COLS.split(", ").join(", c.")} FROM clip_items c
       JOIN clip_search s ON s.rowid = c.id
       WHERE clip_search MATCH '${escapeForFts(trimmed)}*'
       ORDER BY c.createdAt DESC LIMIT ${pageSize()};`));
  } catch {
    // FTS table missing or query parse error → LIKE fallback
    const like = "%" + trimmed.replace(/[%_]/g, "") + "%";
    return withRetry(() => executeSQL<ClipRow>(dbFile(),
      `SELECT ${COLS} FROM clip_items
       WHERE preview LIKE '${like}' OR content LIKE '${like}'
       ORDER BY createdAt DESC LIMIT ${pageSize()};`));
  }
}

export async function clipsInFolder(folderId: number): Promise<ClipRow[]> {
  return withRetry(() => executeSQL<ClipRow>(dbFile(),
    `SELECT c.${COLS.split(", ").join(", c.")} FROM clip_items c
     JOIN pinboard_items p ON p.clipId = c.id
     WHERE p.pinboardId = ${folderId}
     ORDER BY p.position ASC, c.createdAt DESC
     LIMIT ${pageSize()};`));
}

export async function recentImages(): Promise<ClipRow[]> {
  return withRetry(() => executeSQL<ClipRow>(dbFile(),
    `SELECT ${COLS} FROM clip_items
     WHERE kind = 'image'
        OR (kind = 'file' AND (
            lower(content) LIKE '%.png' OR lower(content) LIKE '%.jpg'
         OR lower(content) LIKE '%.jpeg' OR lower(content) LIKE '%.heic'
         OR lower(content) LIKE '%.gif'  OR lower(content) LIKE '%.webp'
         OR lower(content) LIKE '%.tiff' OR lower(content) LIKE '%.bmp'
        ))
     ORDER BY createdAt DESC LIMIT ${pageSize()};`));
}

export async function pinboards(): Promise<PinboardRow[]> {
  return withRetry(() => executeSQL<PinboardRow>(dbFile(),
    `SELECT id, name, colorHex FROM pinboards ORDER BY name ASC;`));
}

function escapeForFts(s: string): string {
  // FTS5 needs single quote escape + remove control chars.
  return s.replace(/'/g, "''").replace(/[^\w\sぁ-んァ-ヶー一-龯]/g, " ");
}

/** Blob directory for raw image files (PNG, etc) saved by Pasty for kind=image. */
export function blobUrl(relativePath: string): string {
  return "file://" + join(homedir(), "Library", "Application Support", "Pasty", "blobs", relativePath);
}
