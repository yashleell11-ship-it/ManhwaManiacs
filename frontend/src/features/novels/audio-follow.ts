/**
 * Which sentence is being spoken right now, and which words to light up.
 *
 * The timing map is contiguous and monotonic by construction — each segment
 * was rendered on its own, so its duration IS `len(samples)/sample_rate` and
 * the next one starts exactly where it ended. That lets this be a binary
 * search rather than a scan, which matters: it runs on every `timeupdate`,
 * roughly four times a second, against a chapter of several hundred segments.
 *
 * Everything here refuses rather than guesses. A player reports a time before
 * the first segment or past the last; a chapter's text can be refetched and no
 * longer match the offsets the audio was rendered against. In both cases the
 * answer is "highlight nothing" — audio with no highlight is an audiobook,
 * which is the product's baseline. A highlight on the wrong words is worse
 * than none, because it tells the reader the pipeline is lying to them.
 */

/** One rendered sentence, as `GET /novels/audio` sends it. */
export type AudioSegment = {
  i: number;
  start_ms: number;
  end_ms: number;
  /** Paragraph index, and offsets within it. */
  p: number;
  s: number;
  e: number;
  voice: string;
  speaker: string | null;
  speech: boolean;
};

/**
 * Index of the segment covering `timeMs`, or -1.
 *
 * Half-open: a segment owns `[start_ms, end_ms)`. At an exact boundary the
 * LATER segment wins, which is what stops the highlight sticking a frame
 * behind the voice at every sentence break.
 */
export function segmentAt(segments: readonly AudioSegment[], timeMs: number): number {
  if (segments.length === 0 || !Number.isFinite(timeMs)) return -1;
  if (timeMs < segments[0].start_ms) return -1;
  if (timeMs >= segments[segments.length - 1].end_ms) return -1;

  let low = 0;
  let high = segments.length - 1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    const seg = segments[mid];
    if (timeMs < seg.start_ms) high = mid - 1;
    else if (timeMs >= seg.end_ms) low = mid + 1;
    else return mid;
  }
  // A gap between segments. Contiguous maps have none, but a map built by
  // another renderer might, and landing in one is not an error.
  return -1;
}

/**
 * Where to seek to play the sentence at a given place in the text.
 *
 * The reverse direction: tapping a paragraph should start the audio at that
 * paragraph, not restart the chapter.
 */
export function seekMsForParagraph(
  segments: readonly AudioSegment[],
  paragraph: number,
): number | null {
  for (const seg of segments) {
    if (seg.p >= paragraph) return seg.start_ms;
  }
  return null;
}

/**
 * Whether this timing map still describes the text on screen.
 *
 * The chapter cache refetches, so the paragraphs a render was made from will
 * eventually be replaced. A segment carries the exact range it spoke, so the
 * check is simply whether that range still exists — an out-of-range offset
 * means the text moved underneath the audio.
 */
export function timingMatchesText(
  segments: readonly AudioSegment[],
  paragraphs: readonly string[],
): boolean {
  if (segments.length === 0) return false;
  for (const seg of segments) {
    const paragraph = paragraphs[seg.p];
    if (paragraph === undefined) return false;
    if (seg.e > paragraph.length || seg.s < 0 || seg.e <= seg.s) return false;
  }
  return true;
}
