/**
 * Split a paragraph into narration and per-speaker quoted runs.
 *
 * Pure, so the rule that matters can be tested without a DOM: **offsets are
 * only trusted when they prove themselves.** The chapter text comes from a
 * seven-day LRU cache that REFETCHES, so the paragraphs a set of attributions
 * was computed against will eventually be replaced by a re-scrape that may
 * differ by a character. Offsets against the old text would tint the wrong
 * words — quietly, and in a way that looks like a bad model rather than stale
 * data.
 *
 * There is a second way the same thing happens. The server counts offsets in
 * Unicode CODE POINTS; JavaScript counts UTF-16 code units. They agree for
 * every character in the Basic Multilingual Plane and disagree by one per
 * astral character — an emoji, a rare CJK ideograph — so a single emoji early
 * in a paragraph slides every later span.
 *
 * One check covers both: each span carries the first few characters of what it
 * was, and a run whose text does not start with them is not the run that was
 * attributed. When any span in a paragraph fails, the whole paragraph renders
 * as plain text. Untinted prose is the product's own baseline; prose tinted
 * against text that moved is worse than no tinting at all.
 */

/** One attributed stretch of speech, as the server stores it. */
export type SpeakerSpan = {
  /** Start offset into the paragraph. */
  s: number;
  /** End offset, exclusive. */
  e: number;
  /** First characters of the attributed text, for proving the offsets. */
  head: string;
  /** The speaker's label, or null when the line stays with the narrator. */
  speaker: string | null;
};

/** A run of text, with the speaker it belongs to. */
export type TintedRun = {
  text: string;
  /** null for narration, and for quoted speech nobody could be named for. */
  speaker: string | null;
};

/**
 * Runs for one paragraph, or null when the offsets cannot be trusted.
 *
 * A null return is the caller's signal to render the paragraph as it always
 * was — not an error to report.
 */
export function tintParagraph(
  paragraph: string,
  spans: readonly SpeakerSpan[],
): TintedRun[] | null {
  if (spans.length === 0) return null;

  // Ascending and non-overlapping, whatever order they arrived in. Overlapping
  // spans cannot both be rendered, and silently dropping one would tint a line
  // with a speaker that is not on it.
  const ordered = [...spans].sort((a, b) => a.s - b.s);
  let cursor = 0;
  const runs: TintedRun[] = [];

  for (const span of ordered) {
    if (span.s < cursor || span.e <= span.s || span.e > paragraph.length) {
      return null;
    }
    const text = paragraph.slice(span.s, span.e);
    // The proof. `head` is a prefix of what this span was when it was
    // attributed; if the text moved, it will not match.
    if (span.head && !text.startsWith(span.head)) return null;

    if (span.s > cursor) {
      runs.push({ text: paragraph.slice(cursor, span.s), speaker: null });
    }
    runs.push({ text, speaker: span.speaker });
    cursor = span.e;
  }

  if (cursor < paragraph.length) {
    runs.push({ text: paragraph.slice(cursor), speaker: null });
  }
  return runs;
}

/**
 * Stable hue per speaker, so a character keeps their colour across chapters.
 *
 * Assigned by the order the cast is given rather than by hashing the name: a
 * hash spreads evenly but puts no distance between any two particular
 * speakers, and the two people who actually matter in a scene can land a few
 * degrees apart and read as the same colour. Walking a fixed, well-separated
 * ring guarantees the busiest speakers are the furthest apart.
 */
const HUES = [212, 348, 152, 32, 272, 190, 122, 318, 12, 242, 168, 52];

export function speakerHues(cast: readonly string[]): Map<string, number> {
  const hues = new Map<string, number>();
  for (const name of cast) {
    // Keyed on how many DISTINCT speakers have been seen, not the array index,
    // so a repeated name does not burn a hue and leave two later speakers
    // sharing one.
    if (!hues.has(name)) hues.set(name, HUES[hues.size % HUES.length]);
  }
  return hues;
}
