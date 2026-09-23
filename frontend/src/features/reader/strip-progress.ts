import type { ProgressPush } from "./api";
import { chapterIndexOf, type StripChapter, type StripPosition } from "./strip";

/** How long a reported page waits before it is written, so a scroll is one write. */
export const PROGRESS_SAVE_MS = 500;

/** A progress write, minus the series identity the caller already holds. */
export type ProgressWriteBody = Omit<ProgressPush, "source_id" | "series_key" | "chapter_key">;

export interface StripProgressDeps {
  /** The strip's loaded chapters RIGHT NOW — read on every report, never cached. */
  chapters: () => readonly StripChapter[];
  /** Send one write. Called with the chapter it is about. */
  save: (chapterKey: string, body: ProgressWriteBody) => void;
  /** Seconds read since the last write (see `reading-clock.ts`). */
  takeElapsed: () => number;
  /** Fires when the reported chapter differs from the previous report's. */
  onChapterChange?: (chapterKey: string) => void;
  delayMs?: number;
}

export interface StripProgressTracker {
  /** The reader is at this chapter and page. Called on every frame / page turn. */
  report: (position: StripPosition) => void;
  /** Send the debounced write now, if one is waiting. */
  flush: () => void;
}

interface PendingWrite {
  chapterKey: string;
  chapterNumber: number | null;
  pageNumber: number;
  pageCount: number;
}

/**
 * Reading position for a strip that spans several chapters (spec R1/R2).
 *
 * Progress is per chapter and always has been — `(source, series, chapter)` with
 * a page inside it — so the only new problem a strip creates is knowing WHICH
 * chapter a page belongs to. The strip answers that on every scroll frame; this
 * turns the answer into writes:
 *
 * - the page is recorded against its own chapter, on both sides of a seam, so
 *   "reading into chapter 12 records chapter 12";
 * - crossing forwards marks the chapter left behind complete, because the
 *   debounced tracker never gets to report a final page once the reading line
 *   has moved on;
 * - nothing ever rewinds: scrolling back to re-read is not a claim to be
 *   earlier in a chapter than the reader got to. The server's furthest-wins
 *   merge would refuse it anyway, but the write would still be pointless and
 *   would rewind the optimistic local state the series page reads back;
 * - a write that is still waiting on the debounce is SENT, not dropped, when
 *   the reader moves to another chapter or leaves (`flush`). The last page of
 *   a chapter is exactly the report most likely to be followed within half a
 *   second by Back or a turn into the next chapter, and dropping it left the
 *   chapter unfinished everywhere but this device's own scroll key;
 * - every write carries how long it has been since the last one, which is what
 *   the server turns into a session's duration (see `reading-clock.ts`).
 *
 * Pure (no React) so the rules above are tested directly; `useStripProgress`
 * is the hook around it. The paged modes report through the same tracker, one
 * report per page turn, so they save exactly like the strip does.
 */
export function createStripProgressTracker(deps: StripProgressDeps): StripProgressTracker {
  const delayMs = deps.delayMs ?? PROGRESS_SAVE_MS;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let pending: PendingWrite | null = null;
  let previous: StripPosition | null = null;
  /**
   * Furthest page already REPORTED, per chapter — a strip visits several.
   *
   * Reported, not written: a report only arms the debounce below, and the next
   * scroll frame disarms it again. This map exists to stop the reader rewinding
   * within a chapter, and it must never be read as "the server has this".
   */
  const furthestSeen = new Map<string, number>();
  /**
   * Chapters whose completion HAS actually been sent.
   *
   * Separate from `furthestSeen` on purpose, and the distinction is the whole
   * point: reading a chapter straight through sets `furthestSeen` to its last
   * page while only arming a 500 ms timer, and crossing the seam clears that
   * timer before it fires. A `completeChapter` that took `furthestSeen` as
   * proof of a write therefore skipped the one write that survives the
   * crossing, and a reader who read four chapters in one scroll had three of
   * them recorded nowhere at all.
   */
  const completedSent = new Set<string>();

  const disarm = () => {
    if (timer) clearTimeout(timer);
    timer = null;
  };

  const send = (write: PendingWrite) => {
    deps.save(write.chapterKey, {
      chapter_number: write.chapterNumber,
      last_page: write.pageNumber,
      page_count: write.pageCount,
      is_completed: write.pageCount > 0 && write.pageNumber >= write.pageCount,
      time_spent_seconds: deps.takeElapsed(),
    });
  };

  const flush = () => {
    disarm();
    const write = pending;
    pending = null;
    // A completion already sent for this chapter says more than any page in
    // it could; re-sending the page would only be a redundant write.
    if (write && !completedSent.has(write.chapterKey)) send(write);
  };

  const completeChapter = (chapterKey: string) => {
    const chapters = deps.chapters();
    const chapter = chapters[chapterIndexOf(chapters, chapterKey)];
    if (!chapter || chapter.pages.length === 0) return;
    if (completedSent.has(chapterKey)) return;
    completedSent.add(chapterKey);
    furthestSeen.set(chapterKey, chapter.pages.length);
    deps.save(chapterKey, {
      chapter_number: chapter.chapterNumber,
      last_page: chapter.pages.length,
      page_count: chapter.pages.length,
      is_completed: true,
      time_spent_seconds: deps.takeElapsed(),
    });
  };

  const report = (position: StripPosition) => {
    const chapters = deps.chapters();
    const last = previous;
    previous = position;

    if (last && last.chapterKey !== position.chapterKey) {
      // Everything the reading line passed OVER is finished, not just the
      // chapter directly above: one wheel gesture can clear a short chapter
      // between two frames, and it would otherwise be left half-read for
      // ever. Resolved against the live strip rather than the reported
      // index, so a report built from an older row list still lands right.
      const from = chapterIndexOf(chapters, last.chapterKey);
      const to = chapterIndexOf(chapters, position.chapterKey);
      for (let index = from; index >= 0 && index < to; index += 1) {
        completeChapter(chapters[index].chapterKey);
      }
      // Whatever was still waiting belongs to the chapter being left: send it
      // rather than let this chapter's first report overwrite it.
      flush();
      deps.onChapterChange?.(position.chapterKey);
    }

    const furthest = furthestSeen.get(position.chapterKey) ?? 0;
    if (position.pageNumber <= furthest) return;
    furthestSeen.set(position.chapterKey, position.pageNumber);

    disarm();
    pending = {
      chapterKey: position.chapterKey,
      chapterNumber: chapters[chapterIndexOf(chapters, position.chapterKey)]?.chapterNumber ?? null,
      pageNumber: position.pageNumber,
      pageCount: position.pageCount,
    };
    timer = setTimeout(flush, delayMs);
  };

  return { report, flush };
}
