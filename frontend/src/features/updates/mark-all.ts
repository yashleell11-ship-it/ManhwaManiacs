import { CONTENT_MODE_COPY, type ContentMode } from "@/features/content-mode/mode";

/**
 * What "Mark all read" on the Updates screen clears, and what it says.
 *
 * The list is scoped to the active content mode, so the bulk action is too:
 * clearing the whole account from Manga mode used to consume every novel
 * chapter the reader had not been shown, and they never read as new in Novels
 * mode. With novels disabled there is only one mode, so the request carries no
 * filter and the button keeps its plain label — the same request and the same
 * words a manga-only deployment always had.
 */
export interface MarkAllReadRequest {
  content_kind?: ContentMode;
}

export function markAllReadRequest(
  novelsEnabled: boolean,
  mode: ContentMode,
): MarkAllReadRequest | undefined {
  return novelsEnabled ? { content_kind: mode } : undefined;
}

/** Names the mode it clears, so nobody expects the other one to go too. */
export function markAllReadLabel(novelsEnabled: boolean, mode: ContentMode): string {
  if (!novelsEnabled) return "Mark all read";
  return `Mark all ${CONTENT_MODE_COPY[mode].label.toLowerCase()} read`;
}
