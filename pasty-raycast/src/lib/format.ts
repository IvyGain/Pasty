import { Icon } from "@raycast/api";
import type { ClipRow } from "./types";
import { blobUrl } from "./db";

export function kindIcon(kind: ClipRow["kind"]): Icon {
  switch (kind) {
    case "image": return Icon.Image;
    case "link": return Icon.Link;
    case "file": return Icon.Document;
    case "code": return Icon.Code;
    case "color": return Icon.Swatch;
    case "richText": return Icon.Text;
    default: return Icon.Text;
  }
}

export function relativeTime(unixSeconds: number): string {
  const diff = Math.max(0, Date.now() / 1000 - unixSeconds);
  if (diff < 60) return `${Math.round(diff)}s`;
  if (diff < 3600) return `${Math.round(diff / 60)}m`;
  if (diff < 86400) return `${Math.round(diff / 3600)}h`;
  if (diff < 86400 * 7) return `${Math.round(diff / 86400)}d`;
  return new Date(unixSeconds * 1000).toLocaleDateString();
}

export function shortBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

export function isImagePath(s: string | null | undefined): boolean {
  if (!s) return false;
  return /\.(png|jpe?g|heic|heif|gif|webp|tiff?|bmp)$/i.test(s);
}

/** Returns the on-disk file path for image clips (from kind=image dataPath OR kind=file content). */
export function imageFilePath(clip: ClipRow): string | null {
  if (clip.kind === "image" && clip.dataPath) return blobUrl(clip.dataPath);
  if (clip.kind === "file" && clip.content && isImagePath(clip.content)) {
    const c = clip.content.trim();
    if (c.startsWith("file://")) return c;
    if (c.startsWith("/")) return "file://" + c;
  }
  return null;
}

const CODE_HINTS = ["{", "function ", "const ", "let ", "var ", "import ", "export ", "<?", "<!", "#!/"];
export function looksLikeCode(s: string): boolean {
  const head = s.slice(0, 200);
  return CODE_HINTS.some((h) => head.includes(h));
}

export function detailMarkdown(clip: ClipRow): string {
  const img = imageFilePath(clip);
  if (img) return `![](${img.replace(/ /g, "%20")})`;
  const text = clip.content ?? clip.preview;
  if (clip.kind === "link") return `[${text}](${text})\n\n${text}`;
  if (clip.kind === "code" || looksLikeCode(text)) return "```\n" + text + "\n```";
  return text;
}
