import { describe, expect, it } from "vitest";

import {
  followAlongTiming,
  segmentAt,
  seekMsForParagraph,
  timingMatchesText,
  type AudioSegment,
} from "./audio-follow";

/**
 * Follow-along runs on every `timeupdate` — about four times a second against
 * a chapter of several hundred segments — and its failure mode is a highlight
 * on the wrong words, which tells the reader the pipeline is lying. So most of
 * this is about refusing rather than guessing.
 */

function seg(i: number, start: number, end: number, p = i, s = 0, e = 10): AudioSegment {
  return { i, start_ms: start, end_ms: end, p, s, e, voice: "v1", speaker: null, speech: false };
}

// Contiguous and monotonic, exactly as the renderer emits it.
const MAP = [seg(0, 0, 1200), seg(1, 1200, 3400), seg(2, 3400, 3900), seg(3, 3900, 9000)];

describe("segmentAt", () => {
  it("finds the segment covering a time", () => {
    expect(segmentAt(MAP, 2000)).toBe(1);
  });

  it("owns its start instant", () => {
    expect(segmentAt(MAP, 1200)).toBe(1);
  });

  it("gives a boundary to the LATER segment", () => {
    // Otherwise the highlight sticks a frame behind the voice at every
    // sentence break.
    expect(segmentAt(MAP, 3400)).toBe(2);
    expect(segmentAt(MAP, 3399)).toBe(1);
  });

  it("covers the very start", () => {
    expect(segmentAt(MAP, 0)).toBe(0);
  });

  it("highlights nothing past the end", () => {
    expect(segmentAt(MAP, 9000)).toBe(-1);
    expect(segmentAt(MAP, 99999)).toBe(-1);
  });

  it("highlights nothing before the start", () => {
    expect(segmentAt([seg(0, 500, 1000)], 0)).toBe(-1);
  });

  it("survives an empty map", () => {
    expect(segmentAt([], 100)).toBe(-1);
  });

  it("refuses a time that is not a number", () => {
    // A player reports NaN between loading and playing.
    expect(segmentAt(MAP, NaN)).toBe(-1);
  });

  it("lands in a gap without inventing a segment", () => {
    const gapped = [seg(0, 0, 1000), seg(1, 2000, 3000)];

    expect(segmentAt(gapped, 1500)).toBe(-1);
  });

  it("agrees with a linear scan across the whole map", () => {
    // The binary search is only safe because the map is monotonic; this is
    // the property test for that.
    for (let t = 0; t < 9000; t += 37) {
      const expected = MAP.findIndex((x) => t >= x.start_ms && t < x.end_ms);
      expect(segmentAt(MAP, t)).toBe(expected);
    }
  });
});

describe("seekMsForParagraph", () => {
  it("starts at the first segment of that paragraph", () => {
    expect(seekMsForParagraph(MAP, 2)).toBe(3400);
  });

  it("falls forward when a paragraph has no audio of its own", () => {
    // A blank paragraph renders nothing; tapping it should play on, not
    // restart the chapter.
    const sparse = [seg(0, 0, 1000, 0), seg(1, 1000, 2000, 5)];

    expect(seekMsForParagraph(sparse, 3)).toBe(1000);
  });

  it("returns null past the end", () => {
    expect(seekMsForParagraph(MAP, 99)).toBeNull();
  });
});

describe("timingMatchesText", () => {
  const paragraphs = ["0123456789abc", "0123456789abc", "0123456789abc", "0123456789abc"];

  it("accepts a map whose ranges all exist", () => {
    expect(timingMatchesText(MAP, paragraphs)).toBe(true);
  });

  it("rejects a map pointing past the end of a paragraph", () => {
    // The chapter cache refetched and the text got shorter. Highlighting
    // against this would light up the wrong words.
    expect(timingMatchesText([seg(0, 0, 100, 0, 0, 999)], paragraphs)).toBe(false);
  });

  it("rejects a map pointing at a paragraph that is gone", () => {
    expect(timingMatchesText([seg(0, 0, 100, 42)], paragraphs)).toBe(false);
  });

  it("rejects an inverted or empty range", () => {
    expect(timingMatchesText([seg(0, 0, 100, 0, 5, 5)], paragraphs)).toBe(false);
    expect(timingMatchesText([seg(0, 0, 100, 0, 9, 3)], paragraphs)).toBe(false);
  });

  it("treats an empty map as not matching", () => {
    // Nothing to follow along with is not the same as following along fine.
    expect(timingMatchesText([], paragraphs)).toBe(false);
  });
});

/**
 * The server is the only side that can see the text a chapter was narrated
 * from. When it says that text is not provably what the reader has on screen,
 * the chapter is still an audiobook — it plays — but nothing is lit up or
 * followed, because the voice may be reading words the page no longer has.
 */
describe("followAlongTiming", () => {
  const paragraphs = ["0123456789abc", "0123456789abc", "0123456789abc", "0123456789abc"];
  const manifest = (highlight_safe?: boolean) => ({
    available: true,
    segments: MAP,
    ...(highlight_safe === undefined ? {} : { highlight_safe }),
  });

  it("follows along when the server vouches for the text and the ranges fit", () => {
    expect(followAlongTiming(manifest(true), paragraphs)).toBe(MAP);
  });

  it("follows nothing when the server says the text differs", () => {
    // The ranges still fit here, so the client-side check alone would have
    // highlighted: this is the case the flag exists for.
    expect(timingMatchesText(MAP, paragraphs)).toBe(true);
    expect(followAlongTiming(manifest(false), paragraphs)).toBeNull();
  });

  it("follows nothing when the server does not say", () => {
    // A manifest without the flag cannot vouch for the text either.
    expect(followAlongTiming(manifest(), paragraphs)).toBeNull();
  });

  it("still refuses a vouched-for map that no longer fits the page", () => {
    // The page can hold newer text than the manifest was built against.
    expect(followAlongTiming(manifest(true), ["short"])).toBeNull();
  });

  it("follows nothing when there is no audio, or no manifest yet", () => {
    expect(
      followAlongTiming({ available: false, segments: MAP, highlight_safe: true }, paragraphs),
    ).toBeNull();
    expect(followAlongTiming(undefined, paragraphs)).toBeNull();
  });
});
