import { readingOrder, type OrderedChapter } from "@/features/reader/read-all";
import { BARE_ORDINAL_PREFIX, chapterLabel } from "@/features/sources/chapter-label";
import type { SourceChapterSummary } from "@/features/sources/types";
import { WORDS_PER_MINUTE } from "./reading-time";

/**
 * The book-shaped presentation logic the novel side leads with.
 *
 * A manga screen is poster-led: the cover carries the identity and the metadata
 * is a caption under it. Novels have weak cover art — an aggregator's generated
 * placeholder, more often than not — and strong metadata, so the novel screens
 * invert that: title, author, length. This module owns the parts of that
 * inversion that are decisions rather than markup, so they can be tested
 * without a DOM.
 */

// --- Front matter -----------------------------------------------------------

/** "by Neil Gaiman", or null when the source did not name an author. */
export function byline(author: string | null | undefined): string | null {
  const trimmed = author?.trim();
  return trimmed ? `by ${trimmed}` : null;
}

/** "412 chapters" / "1 chapter"; null for a source that did not say. */
export function formatChapterCount(count: number | null | undefined): string | null {
  if (count == null || !Number.isFinite(count) || count <= 0) return null;
  const whole = Math.round(count);
  return `${whole.toLocaleString()} ${whole === 1 ? "chapter" : "chapters"}`;
}

/**
 * How long the whole book is, projected from the chapters actually measured.
 *
 * There is no bulk word-count endpoint and no `word_count` on a chapter
 * listing, so the only real numbers available are the chapters whose text has
 * been fetched — the handful the series page prefetches, plus anything already
 * read (see `useCachedNovelWordCounts`). This projects the mean of that sample
 * across the catalogue.
 *
 * It is an ESTIMATE and the UI says so. Two guards keep it from being a
 * fabrication: it refuses to project from fewer than {@link MIN_LENGTH_SAMPLE}
 * measured chapters, and it reports `sampleSize` so a caller can qualify the
 * number ("from 5 chapters") rather than presenting it as a fact.
 */
export const MIN_LENGTH_SAMPLE = 2;

export interface SeriesLengthEstimate {
  /** Chapters the source reports, 0 when it reports none. */
  chapters: number;
  /** How many chapters the mean was taken over. */
  sampleSize: number;
  /** Mean words per measured chapter, or null with too small a sample. */
  meanWords: number | null;
  /** Projected words for the whole series, or null when not projectable. */
  totalWords: number | null;
  /** Projected reading minutes for the whole series, or null. */
  minutes: number | null;
}

export function estimateSeriesLength(
  chapterCount: number | null | undefined,
  sampledWordCounts: Iterable<number>,
): SeriesLengthEstimate {
  const chapters =
    chapterCount != null && Number.isFinite(chapterCount) && chapterCount > 0
      ? Math.round(chapterCount)
      : 0;

  let total = 0;
  let sampleSize = 0;
  for (const words of sampledWordCounts) {
    if (!Number.isFinite(words) || words <= 0) continue;
    total += words;
    sampleSize += 1;
  }

  if (sampleSize < MIN_LENGTH_SAMPLE || chapters === 0) {
    return { chapters, sampleSize, meanWords: null, totalWords: null, minutes: null };
  }

  const meanWords = Math.round(total / sampleSize);
  const totalWords = meanWords * chapters;
  return {
    chapters,
    sampleSize,
    meanWords,
    totalWords,
    minutes: Math.max(1, Math.round(totalWords / WORDS_PER_MINUTE)),
  };
}

/**
 * "≈ 61 h" for a whole-book estimate, or null when there is nothing to project
 * from. Hours only — nobody plans a 400-chapter novel to the minute, and a
 * spurious "≈ 61 h 14 min" would claim a precision the sample does not have.
 */
export function formatEstimatedTotal(estimate: SeriesLengthEstimate): string | null {
  if (estimate.minutes == null) return null;
  const hours = estimate.minutes / 60;
  if (hours < 1) return `≈ ${Math.max(1, Math.round(estimate.minutes))} min`;
  return `≈ ${Math.round(hours).toLocaleString()} h`;
}

/**
 * "≈ 1.1M words" / "≈ 84,000 words" for a projected total.
 *
 * Rounded hard on purpose: this is a projection from a handful of chapters, and
 * "≈ 1,043,217 words" would read as a count.
 */
export function formatEstimatedWords(estimate: SeriesLengthEstimate): string | null {
  const total = estimate.totalWords;
  if (total == null || total <= 0) return null;
  if (total >= 1_000_000) return `≈ ${(total / 1_000_000).toFixed(1)}M words`;
  if (total >= 10_000) return `≈ ${Math.round(total / 1000).toLocaleString()}k words`;
  return `≈ ${(Math.round(total / 100) * 100).toLocaleString()} words`;
}

// --- Table of contents ------------------------------------------------------

export interface TocEntry {
  /** The number column: "12", "12.5", or null for an unnumbered chapter. */
  ordinal: string | null;
  /** The chapter's own title, or null when it has nothing but a number. */
  title: string | null;
}

/**
 * One line of a table of contents: a number column and a title.
 *
 * A download-style row list writes "Chapter 12" and then, underneath,
 * "Chapter 12: The Gate Opens". A table of contents sets the number in its own
 * column and the title beside it, once. The de-duplication that makes that
 * possible is `chapterLabel`'s and is reused rather than re-derived — sources
 * embed the number in the title in half a dozen shapes and that function
 * already knows all of them.
 */
export function tocEntry(chapter: {
  number: number | null;
  title: string | null;
}): TocEntry {
  const label = chapterLabel(chapter);
  if (chapter.number == null) {
    return { ordinal: null, title: label.primary };
  }
  return { ordinal: formatChapterNumber(chapter.number), title: label.secondary };
}

/**
 * "12" / "12.5". `String` already drops a trailing `.0` (JSON has no integer
 * type, so a whole chapter number arrives as `12` either way) — the point of
 * the wrapper is that a non-finite number renders as nothing rather than
 * "NaN" in the ordinal column.
 */
export function formatChapterNumber(value: number): string {
  return Number.isFinite(value) ? String(value) : "";
}

// --- Go to chapter ----------------------------------------------------------

/**
 * "Chapter 120", "Ch. 45", "c-1: Prologue" — the number a source writes at the
 * front of a title, behind a word for "chapter". "Chapter 12.5" is read whole.
 */
const WORD_PREFIX = /^\s*(?:chapter|chap|ch|c)\s*\.?\s*[-#]?\s*(\d+(?:\.\d+)?)(?!\d)/i;

/** A title that is nothing but a number. */
const BARE_NUMBER = /^\s*(\d+(?:\.\d+)?)\s*$/;

/** "Volume 2 Chapter 15: Return" — the word, anywhere in the title. */
const WORD_ANYWHERE = /\b(?:chapter|ch\.?)\s*[-#:]?\s*(\d+(?:\.\d+)?)(?!\d)/i;

/**
 * The chapter number a reader would say — the one printed in the title.
 *
 * Novel chapter keys and `number` are ROW ORDINALS, not the book's own
 * numbering: TBATE's prologue is row 1 and a side story takes another row, so
 * "Chapter 120" is row 122 there. A reader asking for chapter 120 means the
 * title, so this reads the title first — in the shapes the novel sources
 * actually write (novelfull's "Chapter 3188 Lost Soul", Royal Road's
 * "1. Good Morning Brother", freewebnovel's "c-1: …") — and falls back to the
 * row ordinal only for a title that carries no number at all ("Side Story:
 * Sylvie"). Nothing is ever parsed out of, or computed into, a chapter KEY.
 *
 * The phone's port is `printedChapterNumber` in `novel_book.dart`; both answer
 * `backend/tests/fixtures/reading_navigation_cases.json`.
 */
export function printedChapterNumber(chapter: {
  title: string | null;
  number: number | null;
}): number | null {
  const title = chapter.title ?? "";
  for (const pattern of [WORD_PREFIX, BARE_ORDINAL_PREFIX, BARE_NUMBER, WORD_ANYWHERE]) {
    const match = pattern.exec(title);
    if (match) return Number(match[1]);
  }
  return chapter.number;
}

/** The number in whatever was typed — "120", "ch 120", "Chapter 529" — or null. */
export function goToChapterQuery(query: string): number | null {
  const match = /(\d+(?:\.\d+)?)/.exec(query);
  return match ? Number(match[1]) : null;
}

/**
 * Every chapter whose printed number is what was typed, in reading order.
 *
 * A LIST, never a single answer: printed numbers are not unique. TBATE's keys
 * 531 and 532 are both titled "Chapter 529", and "1" is both the prologue
 * ("c-1: Prologue") and chapter one. The caller shows each with its row, and
 * the reader picks.
 *
 * Works only from the chapter list the page already holds — no source traffic
 * — and is one regex pass per chapter, which is nothing for Shadow Slave's
 * 3,188.
 */
export function goToChapterMatches(
  chapters: readonly SourceChapterSummary[],
  query: string,
): OrderedChapter[] {
  const wanted = goToChapterQuery(query);
  if (wanted === null) return [];
  return readingOrder(chapters).filter(
    (chapter) => printedChapterNumber(chapter) === wanted,
  );
}

/** Which slice of a long contents list is rendered. `end` is exclusive. */
export interface TocWindow {
  start: number;
  end: number;
}

/**
 * The slice of the contents to render around one chapter.
 *
 * "Show all" on a 3,188-chapter book lays out every row, which is the cost
 * the list's cap exists to avoid. Going to chapter 3,000 instead renders a
 * window of `size` rows with that chapter near the top — a little context
 * above it and the rest below, because below is where a reader goes next.
 */
export function tocWindowAround(total: number, index: number, size: number): TocWindow {
  if (total <= size) return { start: 0, end: total };
  const above = Math.floor(size / 8);
  const start = Math.min(Math.max(0, index - above), total - size);
  return { start, end: start + size };
}

/** `step` more rows of the contents, earlier or later. */
export function extendTocWindow(
  window: TocWindow,
  total: number,
  direction: "earlier" | "later",
  step: number,
): TocWindow {
  return direction === "earlier"
    ? { start: Math.max(0, window.start - step), end: window.end }
    : { start: window.start, end: Math.min(total, window.end + step) };
}

/** The DOM id of a contents row — what "Go to chapter" scrolls to. */
export function tocRowId(chapterKey: string): string {
  return `toc-${encodeURIComponent(chapterKey)}`;
}

// --- Chapter opener ---------------------------------------------------------

export interface DropCap {
  /** The single initial letter, set large. */
  initial: string;
  /** Everything after it — the paragraph continues in the normal face. */
  rest: string;
}

/**
 * A paragraph shorter than this is an epigraph, a dateline or a stray heading,
 * not an opening paragraph. A three-line initial over one line of text looks
 * broken, so those are left alone.
 */
export const MIN_DROP_CAP_LENGTH = 80;

/**
 * Split a chapter's first paragraph into a drop cap and the rest, or return
 * null when this paragraph should not get one.
 *
 * Refused, deliberately, when the paragraph opens with anything but a letter.
 * Dialogue is the common case — a great many web-novel chapters open on
 * `"Wait," she said` — and a raised quotation mark reads as a mistake, while
 * dropping the quote and capping the W silently alters the text. Books set
 * those openers plain too.
 */
/**
 * Whether a paragraph is a scene-break ornament rather than prose.
 *
 * Web-novel chapters mark a scene change with a line of `***`, `- - -`, `◇◇◇`
 * or similar. Run through the body renderer those become an indented paragraph
 * of punctuation, which is exactly what they are not: a book sets them centred,
 * with air above and below. Detected rather than configured because the marker
 * differs per source and per translator.
 *
 * Deliberately narrow — a short line carrying NO letters and NO digits. An
 * em-dash opener (`— and then nothing`) has letters and stays prose.
 */
export const MAX_SCENE_BREAK_LENGTH = 12;

export function isSceneBreak(paragraph: string): boolean {
  const text = paragraph.trim();
  if (text.length === 0 || text.length > MAX_SCENE_BREAK_LENGTH) return false;
  return !/[\p{L}\p{N}]/u.test(text);
}

export function splitDropCap(paragraph: string | undefined): DropCap | null {
  const text = paragraph?.trim();
  if (!text || text.length < MIN_DROP_CAP_LENGTH) return null;

  // `Intl.Segmenter` is not needed here: the test is "is the first code point a
  // letter", and a surrogate pair is read whole by `[...text][0]`.
  const [initial] = [...text];
  if (!initial || !/\p{L}/u.test(initial)) return null;

  return { initial, rest: text.slice(initial.length) };
}
