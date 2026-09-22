/**
 * Loading a rendered chapter's audio, with the session attached.
 *
 * NOT `<audio src={url}>`, and that is not a stylistic choice. `mm_session` is
 * httpOnly and `SameSite=lax`, so a browser-MANAGED subresource request to
 * another origin never carries it: in dev the page is on :3000 and the API on
 * :8000, and the element would load nothing but a 401. `services/http.ts`
 * records this as the same failure that took `next/image`'s optimizer out
 * app-wide, and solves it the same way — go through fetch, which keeps
 * `credentials: "include"`.
 *
 * The cost is real and worth naming: an object URL means the whole file is in
 * memory, so playback cannot begin until it has all arrived and the server's
 * Range support buys nothing here. At 24 kbps a twelve-minute chapter is about
 * two megabytes, which is a short wait once rather than a broken player in
 * dev. The MOBILE client is the one that benefits from Range, and it can:
 * it holds a token and sets its own headers, so it streams the URL directly.
 *
 * Fetched only when the reader presses play — most people open a chapter to
 * read it, and nobody should spend two megabytes on a button they never
 * touched.
 */

import { requestBlob, sourceChapterQuery } from "@/services/http";
import type { ChapterId } from "@/types/api";

/** The path and query the audio lives at, shared by both clients. */
export function novelAudioPath(ref: ChapterId): {
  path: string;
  query: Record<string, string>;
} {
  // Query parameters, never path segments: connector keys are opaque and
  // routinely contain slashes and percent-encoding.
  return { path: "/novels/audio/file", query: sourceChapterQuery(ref) };
}

/**
 * Fetch the chapter's audio and hand back an object URL.
 *
 * The caller owns the URL and must `URL.revokeObjectURL` it — a leaked one
 * pins the whole file in memory for the life of the tab.
 *
 * `signal` lets a reader who leaves the chapter mid-download stop paying for
 * the rest of it; see `latest-load.ts` for why the caller must still check it
 * after this resolves.
 */
export async function loadNovelAudioObjectUrl(
  ref: ChapterId,
  { signal }: { signal?: AbortSignal } = {},
): Promise<string> {
  const { path, query } = novelAudioPath(ref);
  const { blob } = await requestBlob(path, { query, signal });
  return URL.createObjectURL(blob);
}
