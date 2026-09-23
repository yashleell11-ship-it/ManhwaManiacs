import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  buildPageViews,
  buildSpreads,
  clampViewIndex,
  findViewIndex,
  pagedProgressPosition,
  spreadDisplayOrder,
  viewLeadPage,
} from "./spread";
import { createStripProgressTracker, PROGRESS_SAVE_MS } from "./strip-progress";
import type { StripChapter } from "./strip";

describe("buildSpreads", () => {
  it("stands the cover alone so the drawn spreads stay in phase", () => {
    expect(buildSpreads(6)).toEqual([[1], [2, 3], [4, 5], [6]]);
    expect(buildSpreads(5)).toEqual([[1], [2, 3], [4, 5]]);
  });

  it("pairs from page one when the chapter has no cover", () => {
    expect(buildSpreads(5, false)).toEqual([
      [1, 2],
      [3, 4],
      [5],
    ]);
  });

  it("handles the degenerate chapter lengths", () => {
    expect(buildSpreads(0)).toEqual([]);
    expect(buildSpreads(-3)).toEqual([]);
    expect(buildSpreads(Number.NaN)).toEqual([]);
    expect(buildSpreads(1)).toEqual([[1]]);
    expect(buildSpreads(2)).toEqual([[1], [2]]);
  });
});

describe("buildPageViews", () => {
  it("gives one page per view outside double-page mode", () => {
    expect(buildPageViews(3, "single")).toEqual([[1], [2], [3]]);
    expect(buildPageViews(3, "continuous")).toEqual([[1], [2], [3]]);
  });

  it("pairs into spreads in double-page mode", () => {
    expect(buildPageViews(4, "double")).toEqual([[1], [2, 3], [4]]);
  });
});

describe("spreadDisplayOrder", () => {
  it("puts the earlier page on the right when reading right-to-left", () => {
    expect(spreadDisplayOrder([2, 3], "rtl")).toEqual([3, 2]);
    expect(spreadDisplayOrder([2, 3], "ltr")).toEqual([2, 3]);
  });

  it("leaves a lone cover alone in both directions", () => {
    expect(spreadDisplayOrder([1], "rtl")).toEqual([1]);
    expect(spreadDisplayOrder([1], "ltr")).toEqual([1]);
  });

  it("does not mutate the view it was given", () => {
    const view = [2, 3];
    spreadDisplayOrder(view, "rtl");
    expect(view).toEqual([2, 3]);
  });
});

describe("findViewIndex", () => {
  const views = buildSpreads(6);

  it("finds the spread holding a page", () => {
    expect(findViewIndex(views, 1)).toBe(0);
    expect(findViewIndex(views, 3)).toBe(1);
    expect(findViewIndex(views, 6)).toBe(3);
  });

  it("clamps pages outside the chapter to the nearest end", () => {
    expect(findViewIndex(views, 0)).toBe(0);
    expect(findViewIndex(views, 99)).toBe(3);
    expect(findViewIndex([], 4)).toBe(0);
  });
});

describe("viewLeadPage", () => {
  it("reports the first page read in the view", () => {
    expect(viewLeadPage([2, 3])).toBe(2);
    expect(viewLeadPage([3, 2])).toBe(2);
    expect(viewLeadPage([])).toBe(1);
  });
});

describe("clampViewIndex", () => {
  it("makes paging past either end a no-op", () => {
    const views = buildSpreads(6);
    expect(clampViewIndex(views, -1)).toBe(0);
    expect(clampViewIndex(views, 99)).toBe(3);
    expect(clampViewIndex([], 5)).toBe(0);
  });
});

describe("pagedProgressPosition", () => {
  it("reports the single page on screen", () => {
    expect(pagedProgressPosition("single", "ch-1", [4], 20)).toEqual({
      chapterKey: "ch-1",
      pageNumber: 4,
      pageCount: 20,
    });
  });

  it("reports a spread's LAST page, so a chapter ending on a spread completes", () => {
    expect(pagedProgressPosition("double", "ch-1", [2, 3], 7)?.pageNumber).toBe(3);
    // Display order is irrelevant: a right-to-left spread is still pages 6 and 7.
    expect(pagedProgressPosition("double", "ch-1", [7, 6], 7)?.pageNumber).toBe(7);
  });

  it("leaves the strip to report for itself", () => {
    expect(pagedProgressPosition("continuous", "ch-1", [4], 20)).toBeNull();
  });

  it("reports nothing before the chapter or its pages are known", () => {
    expect(pagedProgressPosition("single", null, [1], 20)).toBeNull();
    expect(pagedProgressPosition("single", "ch-1", undefined, 20)).toBeNull();
    expect(pagedProgressPosition("single", "ch-1", [1], 0)).toBeNull();
  });
});

describe("paged reading saves progress like the strip", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  // Seven pages: in double mode the views are [1], [2,3], [4,5], [6,7], so the
  // chapter ends on a spread.
  const chapter: StripChapter = {
    sourceId: "asurascans",
    seriesKey: "series/one",
    chapterKey: "ch-1",
    chapterNumber: 1,
    title: "Chapter 1",
    pageCount: 7,
    previousChapterKey: null,
    nextChapterKey: "ch-2",
    pages: Array.from({ length: 7 }, (_, index) => ({
      id: `ch-1:${index + 1}`,
      number: index + 1,
      imageUrl: `/img/ch-1/${index + 1}`,
      width: null,
      height: null,
    })),
  };

  function readThrough(mode: "single" | "double") {
    const writes: Array<{ last_page: number; is_completed?: boolean }> = [];
    const tracker = createStripProgressTracker({
      chapters: () => [chapter],
      takeElapsed: () => 0,
      save: (_, body) => writes.push(body),
    });
    for (const view of buildPageViews(chapter.pages.length, mode)) {
      const position = pagedProgressPosition(mode, chapter.chapterKey, view, chapter.pages.length);
      if (position) tracker.report(position);
      vi.advanceTimersByTime(PROGRESS_SAVE_MS);
    }
    return writes;
  }

  it("single mode: turning to the last page saves the chapter complete", () => {
    const writes = readThrough("single");
    expect(writes.map((write) => write.last_page)).toEqual([1, 2, 3, 4, 5, 6, 7]);
    expect(writes.at(-1)).toMatchObject({ last_page: 7, is_completed: true });
  });

  it("double mode: the final spread saves the chapter complete", () => {
    const writes = readThrough("double");
    expect(writes.map((write) => write.last_page)).toEqual([1, 3, 5, 7]);
    expect(writes.at(-1)).toMatchObject({ last_page: 7, is_completed: true });
  });
});
