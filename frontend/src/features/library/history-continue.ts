import type { SourceChapterSummary } from "@/features/sources/types";
import { readingOrder } from "@/features/reader/read-all";
import { parseUtcTimestamp } from "@/lib/utc-time";
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

/** One chapter's stored position, as a series page holds it. */
export interface SeriesChapterPosition {
  page: number;
  completed: boolean;
  /** When it was last read — breaks a tie between unnumbered chapters. */
  updatedAt?: string;
}

/**
 * What a series page's Continue button offers.
 *
 * `start` — nothing read yet: the first chapter in reading order.
 * `resume` — a chapter and the position to open it at.
 * `caught-up` — the furthest chapter is finished and nothing follows it. On a
 * book's own page that is the answer "Continue" gives everywhere else — the
 * book's page — so the button has nowhere to go and says so instead.
 */
export type SeriesContinue =
  | { kind: "start"; point: ResumePoint }
  | { kind: "resume"; point: ResumePoint }
  | { kind: "caught-up" };

/**
 * Continue for a whole series: the chapter the reader got FURTHEST in.
 *
 * The same rule {@link historyResumePoint} applies to one row, applied to the
 * furthest row rather than the newest. The series pages used to take the most
 * recently touched chapter, and production shows what that costs: re-reading
 * Shadow Slave chapter 1 made Continue reopen chapter 1 at its last paragraph
 * while chapter 5 sat half read, and five seconds on TBATE's prologue made it
 * resume there instead of at the chapter after the one just finished. The
 * server's continue-reading strip answers the same shared table
 * (`backend/tests/fixtures/reading_navigation_cases.json`).
 *
 * "Furthest" is highest chapter number; an unnumbered chapter ranks below
 * every numbered one, and between unnumbered chapters the newest read wins —
 * the order the server ranks its rows in. A position for a key the list does
 * not carry is ignored: there is no chapter to open for it.
 *
 * Null only when the series has no chapters at all.
 */
export function seriesContinue(
  chapters: readonly SourceChapterSummary[],
  progress: Readonly<Record<string, SeriesChapterPosition | undefined>>,
): SeriesContinue | null {
  const order = readingOrder(chapters);
  if (order.length === 0) return null;

  let best = -1;
  let bestReadAt = Number.NEGATIVE_INFINITY;
  for (let index = 0; index < order.length; index += 1) {
    const row = progress[order[index].chapterKey];
    if (!row) continue;
    const readAt = parseUtcTimestamp(row.updatedAt) ?? Number.NEGATIVE_INFINITY;
    if (best === -1 || isFurther(order[index].number, readAt, order[best].number, bestReadAt)) {
      best = index;
      bestReadAt = readAt;
    }
  }

  if (best === -1) {
    return { kind: "start", point: { chapterKey: order[0].chapterKey, page: 1 } };
  }
  const row = progress[order[best].chapterKey]!;
  const point = historyResumePoint(
    { chapter_key: order[best].chapterKey, last_page: row.page, is_completed: row.completed },
    chapters,
  );
  return point ? { kind: "resume", point } : { kind: "caught-up" };
}

/** Whether a chapter at (`number`, `readAt`) is further than the current pick. */
function isFurther(
  number: number | null,
  readAt: number,
  bestNumber: number | null,
  bestReadAt: number,
): boolean {
  if (number != null && bestNumber == null) return true;
  if (number == null && bestNumber != null) return false;
  if (number != null && bestNumber != null && number !== bestNumber) {
    return number > bestNumber;
  }
  return readAt > bestReadAt;
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
