import { describe, expect, it } from "vitest";
import { resolveSeriesProgress } from "@/features/sources/series-progress";
import { seriesContinue } from "./history-continue";
import { caseBook, readingNavigationCases } from "./reading-navigation-cases.testkit";

/**
 * The series pages' Continue, against the table the server's strip and the
 * phone answer too (`backend/tests/fixtures/reading_navigation_cases.json`).
 *
 * The progress goes through `resolveSeriesProgress` exactly as the pages feed
 * it, so the stored rows are read in the shape the pages actually hold.
 */
describe("seriesContinue answers the shared table", () => {
  for (const testCase of readingNavigationCases.continue) {
    it(testCase.name, () => {
      const { map } = resolveSeriesProgress({ serverRows: testCase.progress, localMap: {} });
      const answer = seriesContinue(caseBook(testCase.book), map);

      if (testCase.expect === "caught_up") {
        expect(answer).toEqual({ kind: "caught-up" });
      } else if (testCase.expect === "start") {
        expect(answer).toEqual({
          kind: "start",
          point: { chapterKey: caseBook(testCase.book)[0].id, page: 1 },
        });
      } else {
        expect(answer).toEqual({
          kind: "resume",
          point: { chapterKey: testCase.expect.chapter_key, page: testCase.expect.page },
        });
      }
    });
  }
});

describe("seriesContinue", () => {
  const book = caseBook("short");

  it("is null for a series with no chapters", () => {
    expect(seriesContinue([], {})).toBeNull();
  });

  it("ignores a position for a chapter the list no longer carries", () => {
    expect(
      seriesContinue(book, {
        gone: { page: 9, completed: false, updatedAt: "2026-09-20T00:00:00" },
        a: { page: 3, completed: false, updatedAt: "2026-09-01T00:00:00" },
      }),
    ).toEqual({ kind: "resume", point: { chapterKey: "a", page: 3 } });
  });

  it("ranks an unnumbered chapter below every numbered one", () => {
    const withExtra = [...book, { ...book[0], id: "extra", number: null, title: "Extra" }];
    expect(
      seriesContinue(withExtra, {
        b: { page: 5, completed: false, updatedAt: "2026-09-01T00:00:00" },
        extra: { page: 2, completed: false, updatedAt: "2026-09-20T00:00:00" },
      }),
    ).toEqual({ kind: "resume", point: { chapterKey: "b", page: 5 } });
  });

  it("an adopted local position still counts where the server has none", () => {
    const { map } = resolveSeriesProgress({
      serverRows: [],
      localMap: { b: { page: 4, pageCount: 10, completed: false, updatedAt: "2026-09-01T00:00:00Z" } },
    });
    expect(seriesContinue(book, map)).toEqual({
      kind: "resume",
      point: { chapterKey: "b", page: 4 },
    });
  });
});
