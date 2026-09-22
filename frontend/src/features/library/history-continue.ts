import type { SourceChapterSummary } from "@/features/sources/types";
import { readingOrder } from "@/features/reader/read-all";
import { libraryCoverUrl } from "./api";
import type { ReadingHistoryItem } from "./types";

/**
 * The history shelf — one tile per BOOK, and what its Continue opens.
 *
 * Pure and free of React, so the rule can be tested here and checked against
 * the Flutter half (`mobile/lib/features/library/utils/resume_location.dart`),
 * which answers the same table of cases.
 */

/** Where Continue lands: a chapter and the position to open it at. */
export interface ResumePoint {
  chapterKey: string;
  /** A page for the page reader, a progress bucket for the novel reader. */
  page: number;
}

/**
 * "Continue" on a stored reading position — the rule the continue-reading rail
 * already gets from the server (`FollowedSeriesService.continue_reading`):
 *
 *   * an UNFINISHED chapter reopens at its stored position — `?page=`, which
 *     each reader reads in the unit it saved (a page, or a novel's bucket);
 *   * a FINISHED chapter moves on to the chapter after it, from the top;
 *   * a finished chapter with nothing after it (caught up, or a key the list no
 *     longer carries) has no chapter to name, and answers null — the caller
 *     opens the book's page instead of reopening the finished chapter.
 *
 * `chapters` is only consulted for a finished row: a mid-chapter row is its own
 * answer, so the caller need not fetch the list for it.
 */
export function historyResumePoint(
  entry: Pick<ReadingHistoryItem, "chapter_key" | "last_page" | "is_completed">,
  chapters: readonly SourceChapterSummary[] = [],
): ResumePoint | null {
  if (!entry.is_completed) {
    return { chapterKey: entry.chapter_key, page: entry.last_page > 1 ? entry.last_page : 1 };
  }
  // Reading order, not listing order: a connector that lists newest-first
  // would otherwise make "next" mean older. The same order the server's
  // `_next_known_chapter` and the Read-all strip walk.
  const order = readingOrder(chapters);
  const index = order.findIndex((chapter) => chapter.chapterKey === entry.chapter_key);
  if (index === -1 || index + 1 >= order.length) return null;
  return { chapterKey: order[index + 1].chapterKey, page: 1 };
}

/**
 * The book's name, or "Unknown book".
 *
 * The server's series cache has a TTL, so a book read months ago may have aged
 * out. This used to print the raw `series_key`, which for some sources is a
 * database id — a novel titled "69faa859a5f4c7d1b734d496".
 */
export function historyTitle(entry: Pick<ReadingHistoryItem, "series_title">): string {
  const title = entry.series_title?.trim();
  return title ? title : "Unknown book";
}

/**
 * The cover's absolute URL, or null when the row has none.
 *
 * The server hands the cover over as it sits in `source_series_cache`, which in
 * production is the backend-RELATIVE proxy path `/sources/{src}/series/{key}/
 * cover`. As a bare `<img src>` that resolves against the web origin instead of
 * the API — the bug the phone shipped with — so it goes through the same
 * helper the library grid uses, which also sizes it for the tile.
 */
export function historyCoverSrc(
  entry: Pick<ReadingHistoryItem, "cover_url">,
  sizes?: string | null,
): string | null {
  const cover = entry.cover_url?.trim();
  return cover ? libraryCoverUrl(cover, sizes) : null;
}

/** "Ch 12", or the raw key for a source that numbers nothing. */
export function historyChapterLabel(
  entry: Pick<ReadingHistoryItem, "chapter_number" | "chapter_key">,
): string {
  return entry.chapter_number != null ? `Ch ${entry.chapter_number}` : entry.chapter_key;
}
