import { http, sourceChapterQuery } from "@/services/http";
import type { ChapterId, SeriesId } from "@/types/api";
import { bucketCount } from "./progress";
import { countWords } from "./reading-time";
import type {
  NovelAttributionPayload,
  NovelChapterContent,
  NovelChapterPayload,
  NovelChapterWindowPayload,
} from "./types";

/**
 * Build a renderable chapter from the wire payload. The sole content builder,
 * mirroring the manga reader's `manifestToChapterContent`.
 *
 * The title falls back to the chapter number and then to a bare "Chapter":
 * novel aggregators routinely publish untitled chapters, and a blank heading
 * in the middle of a continuous scroll is worse than a generic one.
 *
 * `word_count` is trusted when the server sent one and recomputed from the
 * paragraphs when it did not (an older cache row, a payload shape that
 * changed) — the reading-time estimate is the main thing a reader looks at
 * before opening a chapter, so "unknown" is worth a cheap local count.
 */
export function toNovelChapter(payload: NovelChapterPayload): NovelChapterContent {
  const paragraphs = Array.isArray(payload.paragraphs) ? payload.paragraphs : [];
  const title =
    payload.title?.trim() ||
    (payload.chapter_number != null ? `Chapter ${payload.chapter_number}` : "Chapter");
  return {
    sourceId: payload.source_id,
    seriesKey: payload.series_key,
    chapterKey: payload.chapter_key,
    chapterNumber: payload.chapter_number,
    title,
    paragraphs,
    previousChapterKey: payload.prev,
    nextChapterKey: payload.next,
    wordCount: payload.word_count > 0 ? payload.word_count : countWords(paragraphs),
    buckets: bucketCount(paragraphs.length),
    cache: payload.cache ?? null,
  };
}

export const novelsApi = {
  /**
   * One chapter as sanitized plain-text paragraphs.
   *
   * Query-param identity, like every other source-native endpoint: connector
   * keys are opaque and routinely contain `/`, so they are never path segments
   * here. 404s when `MM_NOVELS_ENABLED` is off — the whole router is unmounted,
   * so an off feature is indistinguishable from one that was never built.
   */
  chapter: (ref: ChapterId) =>
    http.get<NovelChapterPayload>("/novels/chapter", {
      query: sourceChapterQuery(ref),
    }),

  /**
   * Who speaks each quoted line, when that is already known.
   *
   * Read-only on the server: attribution costs money per chapter and is bought
   * by a deliberate pass, never by somebody opening a chapter. An unattributed
   * chapter answers `attributed: false` rather than 404, because that is the
   * ordinary state for most of the library and a reader should not be walking
   * error paths for it.
   */
  attribution: (ref: ChapterId) =>
    http.get<NovelAttributionPayload>("/novels/attribution", {
      query: sourceChapterQuery(ref),
    }),

  /**
   * A bounded window of one book's chapters, in one round trip.
   *
   * POST, not GET, for the same reason `readerApi.manifestBatch` is: the body
   * is a list of opaque keys that routinely contain slashes, and twenty of
   * them do not belong in a query string. It is still a read.
   *
   * The honest claim is not raw speed. Against a warm server cache this is
   * roughly what the same chapters cost one at a time; what it buys is a cold
   * cache — the misses fan out server-side instead of queueing behind each
   * other — and, more importantly here, ONE call against the rate limiter
   * instead of N. Firing several `GET /novels/chapter` at once spends the
   * `sources` bucket N times over and trips it; a window spends the `bulk`
   * bucket once. Callers must bound the list — `boundedWindow` in
   * `chapter-window.ts` is the guard — because over the cap is a 413.
   */
  chapterWindow: (ref: SeriesId, chapterKeys: readonly string[]) =>
    http.post<NovelChapterWindowPayload>("/novels/chapters", {
      source_id: ref.sourceId,
      series_key: ref.seriesKey,
      chapter_keys: chapterKeys,
    }),
};
