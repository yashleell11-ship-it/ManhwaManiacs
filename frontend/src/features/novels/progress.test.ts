import { describe, expect, it } from "vitest";
import {
  activeParagraphIndex,
  bucketCount,
  bucketForParagraph,
  chapterPercent,
  MAX_PROGRESS_BUCKETS,
  nextProgressPush,
  paragraphForBucket,
  progressForParagraph,
  readingParagraphIndex,
  resumeScrollTop,
} from "./progress";

describe("bucketCount", () => {
  it("gives a short chapter one bucket per paragraph", () => {
    expect(bucketCount(1)).toBe(1);
    expect(bucketCount(30)).toBe(30);
    expect(bucketCount(100)).toBe(100);
  });

  it("caps a long chapter so a bucket is never finer than ~1%", () => {
    expect(bucketCount(101)).toBe(MAX_PROGRESS_BUCKETS);
    expect(bucketCount(2400)).toBe(MAX_PROGRESS_BUCKETS);
  });

  it("never returns zero, so page_count is never a divide-by-zero", () => {
    expect(bucketCount(0)).toBe(1);
    expect(bucketCount(-5)).toBe(1);
    expect(bucketCount(Number.NaN)).toBe(1);
  });
});

describe("bucketForParagraph", () => {
  it("is 1-based — a fresh chapter reports bucket 1, never 0", () => {
    expect(bucketForParagraph(0, 40)).toBe(1);
    expect(bucketForParagraph(0, 900)).toBe(1);
  });

  it("maps the last paragraph to the last bucket", () => {
    expect(bucketForParagraph(39, 40)).toBe(40);
    expect(bucketForParagraph(899, 900)).toBe(MAX_PROGRESS_BUCKETS);
  });

  it("tracks the paragraph one-for-one while the chapter is short", () => {
    for (let index = 0; index < 30; index += 1) {
      expect(bucketForParagraph(index, 30)).toBe(index + 1);
    }
  });

  it("advances monotonically through a long chapter", () => {
    let previous = 0;
    for (let index = 0; index < 900; index += 1) {
      const bucket = bucketForParagraph(index, 900);
      expect(bucket).toBeGreaterThanOrEqual(previous);
      previous = bucket;
    }
    expect(previous).toBe(MAX_PROGRESS_BUCKETS);
  });

  it("clamps nonsense rather than reporting off the end", () => {
    expect(bucketForParagraph(-3, 40)).toBe(1);
    expect(bucketForParagraph(4000, 40)).toBe(40);
    expect(bucketForParagraph(0, 0)).toBe(1);
  });
});

describe("paragraphForBucket", () => {
  it("resumes at the FIRST paragraph of the bucket, never past it", () => {
    // 900 paragraphs over 100 buckets: bucket 2 starts at paragraph 9.
    expect(paragraphForBucket(1, 900)).toBe(0);
    expect(paragraphForBucket(2, 900)).toBe(9);
    expect(paragraphForBucket(100, 900)).toBe(891);
  });

  it("round-trips: resuming a bucket reports that same bucket", () => {
    for (const paragraphCount of [7, 30, 100, 313, 900, 2400]) {
      const buckets = bucketCount(paragraphCount);
      for (let bucket = 1; bucket <= buckets; bucket += 1) {
        const paragraph = paragraphForBucket(bucket, paragraphCount);
        expect(bucketForParagraph(paragraph, paragraphCount)).toBe(bucket);
      }
    }
  });

  it("clamps out-of-range buckets into the chapter", () => {
    expect(paragraphForBucket(0, 40)).toBe(0);
    expect(paragraphForBucket(-1, 40)).toBe(0);
    expect(paragraphForBucket(999, 40)).toBe(39);
    expect(paragraphForBucket(3, 0)).toBe(0);
  });
});

describe("activeParagraphIndex", () => {
  const offsets = [0, 120, 260, 400, 560];

  it("reports the paragraph the reading line is inside", () => {
    expect(activeParagraphIndex(offsets, 0)).toBe(0);
    expect(activeParagraphIndex(offsets, 119)).toBe(0);
    expect(activeParagraphIndex(offsets, 120)).toBe(1);
    expect(activeParagraphIndex(offsets, 399)).toBe(2);
    expect(activeParagraphIndex(offsets, 10_000)).toBe(4);
  });

  it("never goes below the first paragraph when scrolled above the text", () => {
    expect(activeParagraphIndex(offsets, -300)).toBe(0);
  });

  it("survives an unmeasured chapter", () => {
    expect(activeParagraphIndex([], 400)).toBe(0);
  });
});

describe("readingParagraphIndex", () => {
  // A 45-paragraph chapter ending on a short line, then the end-of-chapter
  // block (rule, "End of", length, Next card, links) and the article's bottom
  // padding — about 400px of furniture under the last paragraph.
  const offsets = Array.from({ length: 45 }, (_, index) => 300 + index * 110);
  const lastTop = offsets[offsets.length - 1];
  const scrollHeight = lastTop + 36 + 400;
  const clientHeight = 900;
  const options = { lineRatio: 0.35, endSlack: 48 };
  const bottom = {
    scrollTop: scrollHeight - clientHeight,
    clientHeight,
    scrollHeight,
  };

  it("finishes the chapter when it is scrolled to the end", () => {
    const index = readingParagraphIndex(offsets, bottom, options);
    expect(progressForParagraph(index, offsets.length).completed).toBe(true);
  });

  it("counts the end from within the edge slack", () => {
    const nearly = { ...bottom, scrollTop: bottom.scrollTop - 40 };
    expect(readingParagraphIndex(offsets, nearly, options)).toBe(44);
  });

  it("reads the paragraph under the line anywhere short of the end", () => {
    const middle = { scrollTop: 2000, clientHeight, scrollHeight };
    expect(readingParagraphIndex(offsets, middle, options)).toBe(
      activeParagraphIndex(offsets, 2000 + clientHeight * 0.35),
    );
  });

  it("does not finish a chapter a resume landed at the end of", () => {
    const index = readingParagraphIndex(offsets, bottom, {
      ...options,
      placedByRestore: true,
    });
    expect(progressForParagraph(index, offsets.length).completed).toBe(false);
  });

  it("survives an unmeasured chapter", () => {
    expect(readingParagraphIndex([], bottom, options)).toBe(0);
  });
});

describe("resumeScrollTop", () => {
  // The reader's own geometry: the reading line a third of the way down a
  // 900px scroller, and paragraphs of uneven height, as prose has.
  const lineRatio = 0.35;
  const viewportHeight = 900;
  const heights = [
    40, 180, 72, 72, 250, 36, 108, 144, 72, 300, 36, 36, 90, 162, 72, 54, 216,
    72, 108, 36, 144, 72, 90, 126, 72, 36, 180, 72, 54, 108, 36, 72, 90, 144,
    72, 36, 108, 216, 72, 54, 90, 36, 126, 72, 36,
  ];
  const offsets: number[] = [];
  heights.reduce((top, height) => {
    offsets.push(top + 0.4);
    return top + height + 26;
  }, 400);

  /** What the reader saves straight after landing — the restore is a scroll. */
  function reportedAfterResume(bucket: number): number {
    const paragraph = paragraphForBucket(bucket, offsets.length);
    // `setReaderScrollTop` rounds, so the landing does too.
    const scrollTop = Math.round(
      resumeScrollTop(offsets[paragraph], viewportHeight, lineRatio),
    );
    const index = activeParagraphIndex(
      offsets,
      scrollTop + viewportHeight * lineRatio,
    );
    return progressForParagraph(index, offsets.length).bucket;
  }

  it("reports the saved position back, not paragraphs further on", () => {
    // Opening at paragraph 20 used to save 23 half a second later without a
    // scroll, and the next Continue opened there.
    for (let bucket = 2; bucket <= offsets.length; bucket += 1) {
      expect(reportedAfterResume(bucket)).toBe(bucket);
    }
  });

  it("does not creep forward across repeated opens", () => {
    let saved = 20;
    for (let open = 0; open < 5; open += 1) {
      saved = Math.max(saved, reportedAfterResume(saved));
    }
    expect(saved).toBe(20);
  });
});

describe("progressForParagraph", () => {
  it("packs a position into the last_page / page_count pair", () => {
    expect(progressForParagraph(0, 40)).toEqual({
      bucket: 1,
      buckets: 40,
      completed: false,
    });
  });

  it("marks the chapter complete only at the final bucket", () => {
    expect(progressForParagraph(38, 40).completed).toBe(false);
    expect(progressForParagraph(39, 40).completed).toBe(true);
    expect(progressForParagraph(899, 900).completed).toBe(true);
  });
});

describe("nextProgressPush", () => {
  it("sends a position that moves the reader forward", () => {
    const position = progressForParagraph(12, 40);
    expect(nextProgressPush(position, 5)).toBe(position);
  });

  it("never rewinds — scrolling back to re-read reports nothing", () => {
    const position = progressForParagraph(3, 40);
    expect(nextProgressPush(position, 12)).toBeNull();
    expect(nextProgressPush(position, 4)).toBeNull();
  });

  it("does not resend the position already stored", () => {
    const position = progressForParagraph(11, 40);
    expect(position.bucket).toBe(12);
    expect(nextProgressPush(position, 12)).toBeNull();
  });
});

describe("chapterPercent", () => {
  it("reads out as a percentage of the chapter", () => {
    expect(chapterPercent(1, 100)).toBe(1);
    expect(chapterPercent(50, 100)).toBe(50);
    expect(chapterPercent(40, 40)).toBe(100);
    expect(chapterPercent(3, 40)).toBe(8);
  });

  it("clamps rather than reporting over 100%", () => {
    expect(chapterPercent(120, 100)).toBe(100);
    expect(chapterPercent(-4, 100)).toBe(0);
    expect(chapterPercent(4, 0)).toBe(0);
  });
});
