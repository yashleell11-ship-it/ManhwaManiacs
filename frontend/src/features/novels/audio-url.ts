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

/**
 * The two containers the server can send a chapter's audio in.
 *
 * `ogg` is the stored Ogg Opus file and the smaller of the two. `m4a` is AAC
 * in an MP4 container, made from it on the server, for the browsers that
 * cannot read Ogg at all — Safari on iPhone and iPad among them, where the
 * player would otherwise sit on a file it can never start.
 */
export type NovelAudioFormat = "ogg" | "m4a";

/** What the browser is asked about: the stored file, exactly. */
export const OGG_OPUS_MIME = "audio/ogg; codecs=opus";

/**
 * Which format to ask for, given what the browser said about Ogg Opus.
 *
 * `canPlayType` answers "probably", "maybe" or "" — and only the empty string
 * is a no. "maybe" is what browsers commonly say about a container they do
 * read, so treating it as a refusal would send them the transcoded file for
 * nothing.
 */
export function pickNovelAudioFormat(oggOpusAnswer: string): NovelAudioFormat {
  return oggOpusAnswer === "" ? "m4a" : "ogg";
}

/**
 * The format this browser should ask for.
 *
 * Asked on the press of play, never during render: there is no `Audio` on the
 * server, and the answer cannot change while the page is open.
 */
export function browserNovelAudioFormat(): NovelAudioFormat {
  return pickNovelAudioFormat(new Audio().canPlayType(OGG_OPUS_MIME));
}

/** The path and query the audio lives at, shared by both clients. */
export function novelAudioPath(
  ref: ChapterId,
  format: NovelAudioFormat,
): {
  path: string;
  query: Record<string, string>;
} {
  // Query parameters, never path segments: connector keys are opaque and
  // routinely contain slashes and percent-encoding. The format is always
  // sent, even the default, so what was asked for is visible in the request.
  return {
    path: "/novels/audio/file",
    query: { ...sourceChapterQuery(ref), format },
  };
}

/**
 * The path and query a voice's preview clip lives at.
 *
 * The voice pack is Ogg Opus like every render, so a preview on Safari for
 * iPhone was as silent as a chapter; the route takes the same `format` the
 * chapter file route does, decided the same way (`browserNovelAudioFormat`).
 * Always sent, for the same reason as in `novelAudioPath`.
 */
export function novelVoiceSamplePath(
  voiceId: string,
  format: NovelAudioFormat,
): {
  path: string;
  query: Record<string, string>;
} {
  return {
    path: "/novels/voices/sample",
    query: { voice: voiceId, format },
  };
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
 *
 * `format` is `browserNovelAudioFormat()`'s answer. The blob keeps the
 * response's media type, so the element is told what it has been given.
 */
export async function loadNovelAudioObjectUrl(
  ref: ChapterId,
  { signal, format }: { signal?: AbortSignal; format: NovelAudioFormat },
): Promise<string> {
  const { path, query } = novelAudioPath(ref, format);
  const { blob } = await requestBlob(path, { query, signal });
  return URL.createObjectURL(blob);
}
