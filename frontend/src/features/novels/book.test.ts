import { describe, expect, it } from "vitest";
import {
  caseBook,
  readingNavigationCases,
} from "@/features/library/reading-navigation-cases.testkit";
import {
  byline,
  estimateSeriesLength,
  extendTocWindow,
  formatChapterCount,
  formatChapterNumber,
  formatEstimatedTotal,
  formatEstimatedWords,
  goToChapterMatches,
  isSceneBreak,
  MIN_DROP_CAP_LENGTH,
  MIN_LENGTH_SAMPLE,
  printedChapterNumber,
  splitDropCap,
  tocEntry,
  tocWindowAround,
} from "./book";

const LONG = "A".repeat(MIN_DROP_CAP_LENGTH + 20);

describe("byline", () => {
  it("names the author, and says nothing when there is none", () => {
    expect(byline("Sanderson")).toBe("by Sanderson");
    expect(byline("  Sanderson  ")).toBe("by Sanderson");
    expect(byline("")).toBeNull();
    expect(byline("   ")).toBeNull();
    expect(byline(null)).toBeNull();
    expect(byline(undefined)).toBeNull();
  });
});

describe("formatChapterCount", () => {
  it("counts chapters, respecting the singular", () => {
    expect(formatChapterCount(412)).toBe("412 chapters");
    expect(formatChapterCount(1)).toBe("1 chapter");
  });

  it("says nothing when the source reported no count", () => {
    expect(formatChapterCount(0)).toBeNull();
    expect(formatChapterCount(null)).toBeNull();
    expect(formatChapterCount(undefined)).toBeNull();
    expect(formatChapterCount(Number.NaN)).toBeNull();
    expect(formatChapterCount(-3)).toBeNull();
  });
});

describe("estimateSeriesLength", () => {
  it("projects the sample mean across the catalogue", () => {
    const estimate = estimateSeriesLength(100, [2000, 3000, 2500]);
    expect(estimate.sampleSize).toBe(3);
    expect(estimate.meanWords).toBe(2500);
    expect(estimate.totalWords).toBe(250_000);
    // 250,000 words at 250 wpm.
    expect(estimate.minutes).toBe(1000);
  });

  it("refuses to project from too small a sample — that would be invention", () => {
    const one = estimateSeriesLength(400, [2500]);
    expect(one.sampleSize).toBe(1);
    expect(one.meanWords).toBeNull();
    expect(one.minutes).toBeNull();
    expect(MIN_LENGTH_SAMPLE).toBeGreaterThan(1);
  });

  it("refuses to project when the source reports no chapter count", () => {
    const estimate = estimateSeriesLength(0, [2000, 3000]);
    expect(estimate.chapters).toBe(0);
    expect(estimate.minutes).toBeNull();
  });

  it("ignores unusable samples rather than averaging zeros in", () => {
    const estimate = estimateSeriesLength(10, [0, Number.NaN, -5, 1000, 3000]);
    expect(estimate.sampleSize).toBe(2);
    expect(estimate.meanWords).toBe(2000);
  });

  it("handles an empty sample", () => {
    const estimate = estimateSeriesLength(120, []);
    expect(estimate.sampleSize).toBe(0);
    expect(estimate.totalWords).toBeNull();
  });
});

describe("formatEstimatedTotal", () => {
  it("reports whole hours for a book-length estimate", () => {
    expect(formatEstimatedTotal(estimateSeriesLength(100, [2500, 2500]))).toBe("≈ 17 h");
  });

  it("falls back to minutes for something under an hour", () => {
    expect(formatEstimatedTotal(estimateSeriesLength(2, [1000, 1000]))).toBe("≈ 8 min");
  });

  it("says nothing when there is nothing to project from", () => {
    expect(formatEstimatedTotal(estimateSeriesLength(100, []))).toBeNull();
  });
});

describe("formatEstimatedWords", () => {
  it("rounds hard, because this is a projection and not a count", () => {
    // 400 chapters x 2,600 words = 1.04M.
    expect(formatEstimatedWords(estimateSeriesLength(400, [2600, 2600]))).toBe(
      "≈ 1.0M words",
    );
    // 30 x 2,800 = 84,000.
    expect(formatEstimatedWords(estimateSeriesLength(30, [2800, 2800]))).toBe(
      "≈ 84k words",
    );
    // 3 x 1,240 = 3,720 -> nearest hundred.
    expect(formatEstimatedWords(estimateSeriesLength(3, [1240, 1240]))).toBe(
      "≈ 3,700 words",
    );
  });

  it("says nothing without a projection", () => {
    expect(formatEstimatedWords(estimateSeriesLength(400, [2600]))).toBeNull();
  });
});

describe("tocEntry", () => {
  it("puts the number in its own column and the title beside it, once", () => {
    expect(tocEntry({ number: 12, title: "Chapter 12: The Gate Opens" })).toEqual({
      ordinal: "12",
      title: "The Gate Opens",
    });
    expect(tocEntry({ number: 134, title: "The Culprit (7)" })).toEqual({
      ordinal: "134",
      title: "The Culprit (7)",
    });
  });

  it("leaves the title column empty for a number-only chapter", () => {
    expect(tocEntry({ number: 133, title: "Chapter 133" })).toEqual({
      ordinal: "133",
      title: null,
    });
    expect(tocEntry({ number: 133, title: null })).toEqual({
      ordinal: "133",
      title: null,
    });
  });

  it("does not print a Royal Road ordinal twice on one row", () => {
    // Every chapter of every RR fiction is titled "N. Title", which the
    // contents page rendered whole beside its own ordinal column: "1 │ 1. Good
    // Morning Brother", for all 109 rows.
    expect(tocEntry({ number: 1, title: "1. Good Morning Brother" })).toEqual({
      ordinal: "1",
      title: "Good Morning Brother",
    });
  });

  it("keeps decimals, which are real chapters", () => {
    expect(tocEntry({ number: 12.5, title: "Interlude" })).toEqual({
      ordinal: "12.5",
      title: "Interlude",
    });
  });

  it("falls back to the title when the source numbers nothing", () => {
    expect(tocEntry({ number: null, title: "Prologue" })).toEqual({
      ordinal: null,
      title: "Prologue",
    });
    expect(tocEntry({ number: null, title: null })).toEqual({
      ordinal: null,
      title: "Chapter",
    });
  });
});

describe("formatChapterNumber", () => {
  it("renders nothing rather than NaN", () => {
    expect(formatChapterNumber(12)).toBe("12");
    expect(formatChapterNumber(12.5)).toBe("12.5");
    expect(formatChapterNumber(Number.NaN)).toBe("");
    expect(formatChapterNumber(Number.POSITIVE_INFINITY)).toBe("");
  });
});

describe("splitDropCap", () => {
  it("splits the initial letter off a real opening paragraph", () => {
    const text = `The rain had not stopped for nine days. ${LONG}`;
    expect(splitDropCap(text)).toEqual({
      initial: "T",
      rest: text.slice(1),
    });
  });

  it("refuses dialogue openers — a raised quotation mark reads as a mistake", () => {
    expect(splitDropCap(`"Wait," she said, and the door closed. ${LONG}`)).toBeNull();
    expect(splitDropCap(`“Wait,” she said, and the door closed. ${LONG}`)).toBeNull();
    expect(splitDropCap(`— and then nothing at all, for a while. ${LONG}`)).toBeNull();
    expect(splitDropCap(`1892 was a bad year for the family. ${LONG}`)).toBeNull();
  });

  it("refuses a paragraph too short to set an initial against", () => {
    expect(splitDropCap("The rain stopped.")).toBeNull();
    expect(splitDropCap("A".repeat(MIN_DROP_CAP_LENGTH - 1))).toBeNull();
    expect(splitDropCap("A".repeat(MIN_DROP_CAP_LENGTH))).not.toBeNull();
  });

  it("handles absent, blank and non-Latin openers", () => {
    expect(splitDropCap(undefined)).toBeNull();
    expect(splitDropCap("")).toBeNull();
    expect(splitDropCap("   ")).toBeNull();
    const cyrillic = `Дождь не прекращался девять дней подряд. ${LONG}`;
    expect(splitDropCap(cyrillic)?.initial).toBe("Д");
  });

  it("trims before splitting, so leading whitespace never becomes the cap", () => {
    const text = `   Morning came slowly to the valley. ${LONG}`;
    expect(splitDropCap(text)?.initial).toBe("M");
  });
});

describe("isSceneBreak", () => {
  it("recognises the ornaments sources use between scenes", () => {
    for (const marker of ["***", "* * *", "---", "◇◇◇", "※", "· · ·", "~~~"]) {
      expect(isSceneBreak(marker), marker).toBe(true);
      expect(isSceneBreak(`  ${marker}  `), marker).toBe(true);
    }
  });

  it("never swallows prose", () => {
    expect(isSceneBreak("— and then nothing at all")).toBe(false);
    expect(isSceneBreak("He ran.")).toBe(false);
    expect(isSceneBreak("1892")).toBe(false);
    expect(isSceneBreak("")).toBe(false);
    expect(isSceneBreak("   ")).toBe(false);
    // A long line of punctuation is a formatting accident, not an ornament.
    expect(isSceneBreak("*".repeat(60))).toBe(false);
  });
});

// --- Go to chapter: the shared table (backend/tests/fixtures/
// reading_navigation_cases.json), which the phone's port answers too.

describe("printedChapterNumber", () => {
  for (const { title, number, expect: printed } of readingNavigationCases.printed_numbers) {
    it(`reads ${JSON.stringify(title)} (row ${number}) as ${printed}`, () => {
      expect(printedChapterNumber({ title, number })).toBe(printed);
    });
  }
});

describe("goToChapterMatches", () => {
  for (const { book, query, expect: keys } of readingNavigationCases.goto) {
    it(`finds ${JSON.stringify(query)} in ${book} at rows [${keys.join(", ")}]`, () => {
      expect(goToChapterMatches(caseBook(book), query).map((c) => c.chapterKey)).toEqual(keys);
    });
  }

  it("never lands on the key that merely equals the typed number", () => {
    // TBATE key 120 is printed "Chapter 118"; a number filter over keys would
    // open it for "120" — two chapters short.
    const matches = goToChapterMatches(caseBook("tbate"), "120");
    expect(matches.map((c) => c.title)).toEqual(["Chapter 120"]);
    expect(matches.map((c) => c.chapterKey)).not.toContain("120");
  });

  it("answers in reading order however the source listed the chapters", () => {
    const reversed = [...caseBook("tbate")].reverse();
    expect(goToChapterMatches(reversed, "529").map((c) => c.chapterKey)).toEqual(["531", "532"]);
  });
});

describe("tocWindowAround", () => {
  it("renders everything when the book fits", () => {
    expect(tocWindowAround(120, 100, 400)).toEqual({ start: 0, end: 120 });
  });

  it("puts a far chapter near the top of a bounded window", () => {
    // Shadow Slave: going to row 3,000 renders 400 rows, not 3,188.
    expect(tocWindowAround(3188, 3000, 400)).toEqual({ start: 2788, end: 3188 });
    expect(tocWindowAround(3188, 1500, 400)).toEqual({ start: 1450, end: 1850 });
  });

  it("never starts before the first row", () => {
    expect(tocWindowAround(3188, 10, 400)).toEqual({ start: 0, end: 400 });
  });
});

describe("extendTocWindow", () => {
  it("grows earlier and later, and stops at the ends", () => {
    expect(extendTocWindow({ start: 1450, end: 1850 }, 3188, "earlier", 400)).toEqual({
      start: 1050,
      end: 1850,
    });
    expect(extendTocWindow({ start: 100, end: 500 }, 3188, "earlier", 400)).toEqual({
      start: 0,
      end: 500,
    });
    expect(extendTocWindow({ start: 2788, end: 3000 }, 3188, "later", 400)).toEqual({
      start: 2788,
      end: 3188,
    });
  });
});
