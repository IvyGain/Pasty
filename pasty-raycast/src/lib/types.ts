/**
 * Shared type contract for the Pasty Raycast extension.
 *
 * All commands (browse, search, folders, images, paste-stack) import from this
 * module. Keep this file framework-free — no Raycast / Node imports — so it can
 * be used safely from both UI and headless contexts (e.g. tests).
 */

/**
 * Discriminator describing what a clip represents.
 * - `text`     — plain text capture
 * - `richText` — styled text (RTF / HTML source preserved)
 * - `code`     — source code snippet
 * - `image`    — bitmap stored as a blob under Application Support/Pasty/blobs
 * - `link`     — URL (http/https/etc)
 * - `file`     — file path or file URL captured from Finder
 * - `color`    — color value (hex / rgb)
 * - `other`    — anything that doesn't match the above
 */
export type ClipKind = "text" | "richText" | "code" | "image" | "link" | "file" | "color" | "other";

/**
 * A single clipboard item row from the `clip_items` SQLite table.
 *
 * Fields:
 * - `id`              — primary key
 * - `kind`            — see {@link ClipKind}
 * - `preview`         — short, sanitized one-liner safe to render in a list
 * - `content`         — full textual payload (null for pure-blob images)
 * - `dataPath`        — relative path inside the blobs/ directory (image kind)
 * - `sourceAppName`   — human-readable source app (e.g. "Safari")
 * - `sourceBundleId`  — bundle id of the source app (e.g. "com.apple.Safari")
 * - `byteSize`        — payload size in bytes
 * - `createdAt`       — capture time as a unix epoch in **seconds**
 */
export interface ClipRow {
  id: number;
  kind: ClipKind;
  preview: string;
  content: string | null;
  dataPath: string | null;
  sourceAppName: string | null;
  sourceBundleId: string | null;
  byteSize: number;
  createdAt: number; // unix epoch seconds
}

/**
 * A user-defined pinboard (folder) from the `pinboards` table.
 *
 * - `id`       — primary key
 * - `name`     — display label
 * - `colorHex` — tint color in `#RRGGBB` form, used for the folder icon
 */
export interface PinboardRow {
  id: number;
  name: string;
  colorHex: string;
}

/**
 * Join row connecting a clip to a pinboard, from `pinboard_items`.
 *
 * - `pinboardId` — FK → {@link PinboardRow.id}
 * - `clipId`     — FK → {@link ClipRow.id}
 * - `title`      — optional per-folder override label (null = use clip preview)
 * - `position`   — sort order within the folder (ascending)
 */
export interface PinboardItemRow {
  pinboardId: number;
  clipId: number;
  title: string | null;
  position: number;
}
