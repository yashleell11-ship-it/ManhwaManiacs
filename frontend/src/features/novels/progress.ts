/**
 * Reading position for a novel chapter, expressed in the fields the server
 * already merges.
 *
 * `chapter_progress` stores `(chapter_number, last_page, page_count)` and
 * merges **furthest-wins** — a stale client replaying an old position can
 * never rewind a reader (see ARCHITECTURE.md). A novel has no pages, so rather
 * than inventing a parallel progress model (and a second merge rule to keep
 * correct), a chapter's paragraphs are bucketed and the bucket index rides in
 * `last_page` with the bucket count in `page_count`. The server's merge, the
 * library's "continue reading", the mobile outbox and the statistics service
 * all keep working with no change at all.
 *
 * Buckets, not raw paragraph indices, because `page_count` is also what the UI
 * divides by: one bucket per paragraph turns a 900-paragraph chapter into
 * "page 412 of 900", and a chapter whose paragraph count shifts upstream (an
 * aggregator re-splitting a wall of text) would move a stored position by
 * hundreds. Capping at {@link MAX_PROGRESS_BUCKETS} makes a bucket ≈1% of the
 * chapter, which is stable across a re-split and reads sensibly as a percent.
 *
 * Short chapters get one bucket per paragraph, so resuming a 30-paragraph
 * chapter lands on the exact paragraph.
 */

/** A bucket is at worst ~1% of a chapter. */
export const MAX_PROGRESS_BUCKETS = 100;

/** How many buckets a chapter of `paragraphCount` paragraphs is divided into. */
export function bucketCount(paragraphCount: number): number {
  if (!Number.isFinite(paragraphCount) || paragraphCount <= 0) return 1;
  return Math.min(Math.floor(paragraphCount), MAX_PROGRESS_BUCKETS);
}

/**
 * The 1-based bucket a paragraph falls in. `paragraphIndex` is 0-based.
 *
 * 1-based because `last_page` is 1-based everywhere else in the app, and a
 * stored `0` already means "no progress" to the library and the series page.
 */
export function bucketForParagraph(
  paragraphIndex: number,
  paragraphCount: number,
): number {
  const buckets = bucketCount(paragraphCount);
  if (paragraphCount <= 0) return 1;
  const index = Math.min(
    Math.max(Math.floor(paragraphIndex), 0),
    Math.floor(paragraphCount) - 1,
  );
  return Math.min(buckets, Math.floor((index * buckets) / Math.floor(paragraphCount)) + 1);
}

/**
 * The 0-based index of the FIRST paragraph in a bucket — where resuming that
 * bucket lands the reader. Deliberately the first and not the last: re-reading
 * a paragraph you already read is free, skipping one is not.
 */
export function paragraphForBucket(bucket: number, paragraphCount: number): number {
  const count = Math.max(Math.floor(paragraphCount), 0);
  if (count <= 0) return 0;
  const buckets = bucketCount(count);
  const clamped = Math.min(Math.max(Math.floor(bucket), 1), buckets);
  return Math.min(count - 1, Math.ceil(((clamped - 1) * count) / buckets));
}

/**
 * Which paragraph is at the top of the viewport, given each paragraph's offset
 * from the top of the scroll container.
 *
 * `offsets` is ascending; the answer is the last paragraph that starts at or
 * above the reading line. Extracted as a pure function of measured offsets so
 * the mapping is testable without a DOM — the component's only job is to
 * measure.
 */
export function activeParagraphIndex(
  offsets: readonly number[],
  readingLine: number,
): number {
  if (offsets.length === 0) return 0;
  let low = 0;
  let high = offsets.length - 1;
  let answer = 0;
  while (low <= high) {
    const mid = (low + high) >> 1;
    if (offsets[mid] <= readingLine) {
      answer = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return answer;
}

/** The scroll container's geometry at one moment, as the reader reads it. */
export interface ReadingViewport {
  scrollTop: number;
  clientHeight: number;
  scrollHeight: number;
}

/**
 * The paragraph being read: the one under the reading line, `lineRatio` of the
 * way down the viewport — except at the end of the scroll, where it is the
 * last paragraph.
 *
 * The line alone can never reach the end of a chapter. At the bottom it still
 * sits most of a screen above the end of the content, and below the last
 * paragraph there is only the end-of-chapter block, so a last paragraph shorter
 * than about six lines — which is how prose chapters end — never came under
 * it. A chapter read to the bottom and left by "Back to the book", or the
 * newest chapter with nothing after it, stayed a bucket or three short of
 * complete and showed as unread.
 *
 * `placedByRestore` is true while the position is the one a resume or a
 * bookmark jumped to: that landing is not reading, so a resume that runs out
 * of scroll does not finish the chapter on the reader's behalf.
 */
export function readingParagraphIndex(
  offsets: readonly number[],
  view: ReadingViewport,
  options: { lineRatio: number; endSlack: number; placedByRestore?: boolean },
): number {
  if (offsets.length === 0) return 0;
  const atEnd =
    view.scrollTop + view.clientHeight >= view.scrollHeight - options.endSlack;
  if (atEnd && !options.placedByRestore) return offsets.length - 1;
  return activeParagraphIndex(
    offsets,
    view.scrollTop + view.clientHeight * options.lineRatio,
  );
}

/**
 * How far below a paragraph's top the reading line is put back when a chapter
 * resumes at it. A couple of pixels, so the scroll writer's rounding and a
 * sub-pixel offset cannot leave the line just above the paragraph and report
 * the one before it.
 */
export const RESUME_LINE_INSET_PX = 2;

/**
 * The scroll offset that resumes a chapter at a paragraph: the one that puts
 * that paragraph's top on the READING LINE, `lineRatio` of the way down the
 * viewport — the same line progress is captured at.
 *
 * It used to put the paragraph near the top of the screen instead. The restore
 * is itself a scroll, so the reader then reported whichever paragraph was
 * under the reading line a third of a screen further down, and the save that
 * followed moved the stored position forward by two to four paragraphs nobody
 * had read. Every open did it again, so Continue skipped a little more text
 * each time.
 */
export function resumeScrollTop(
  paragraphOffset: number,
  viewportHeight: number,
  lineRatio: number,
): number {
  return paragraphOffset - viewportHeight * lineRatio + RESUME_LINE_INSET_PX;
}

export interface NovelProgressPosition {
  /** 1-based bucket index — goes in `last_page`. */
  bucket: number;
  /** Total buckets — goes in `page_count`. */
  buckets: number;
  /** Whether the reader reached the end of the chapter. */
  completed: boolean;
}

/** The position to report for a paragraph, ready to push as progress. */
export function progressForParagraph(
  paragraphIndex: number,
  paragraphCount: number,
): NovelProgressPosition {
  const buckets = bucketCount(paragraphCount);
  const bucket = bucketForParagraph(paragraphIndex, paragraphCount);
  return { bucket, buckets, completed: bucket >= buckets };
}

/**
 * The position actually worth sending, given what has already been sent for
 * this chapter.
 *
 * Never rewinds: scrolling back up to re-read a line must not tell the server
 * the reader is earlier in the chapter than they got to. The server would
 * refuse it anyway (furthest-wins), but sending it is a pointless write and
 * would rewind the OPTIMISTIC local state that the series page reads back.
 * `null` means "nothing new to say".
 */
export function nextProgressPush(
  position: NovelProgressPosition,
  furthestSent: number,
): NovelProgressPosition | null {
  if (position.bucket <= furthestSent) return null;
  return position;
}

/** Percentage through a chapter, for the reader's own progress read-out. */
export function chapterPercent(bucket: number, buckets: number): number {
  if (buckets <= 0) return 0;
  const clamped = Math.min(Math.max(bucket, 0), buckets);
  return Math.round((clamped / buckets) * 100);
}
