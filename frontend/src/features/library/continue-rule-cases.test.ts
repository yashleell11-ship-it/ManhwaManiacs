import { describe, expect, it } from "vitest";
import { resolveSeriesProgress } from "@/features/sources/series-progress";
import {
  libraryReadingOrder,
  librarySeriesContinue,
  seriesContinue,
  type LibrarySeriesChapters,
} from "./history-continue";
import {
  caseBook,
  readingNavigationCases,
  type CaseProgressRow,
} from "./reading-navigation-cases.testkit";

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

/**
 * The library's own series page, fed the way it is fed: its payload's chapter
 * list and `progress` overlay, which carries no read times.
 */
function libraryPayload(book: string, rows: readonly CaseProgressRow[]): LibrarySeriesChapters {
  return {
    source_id: "fixture",
    series_key: book,
    chapters: readingNavigationCases.books[book].map((chapter) => ({
      key: chapter.key,
      number: chapter.number,
      title: chapter.title,
      published_at: null,
    })),
    progress: Object.fromEntries(
      rows.map((row) => [
        row.chapter_key,
        { last_page: row.last_page, is_completed: row.is_completed },
      ]),
    ),
  };
}

describe("the library series page answers the shared table too", () => {
  for (const testCase of readingNavigationCases.continue) {
    it(testCase.name, () => {
      const answer = librarySeriesContinue(libraryPayload(testCase.book, testCase.progress));

      if (testCase.expect === "caught_up") {
        expect(answer).toEqual({ kind: "caught-up" });
      } else if (testCase.expect === "start") {
        expect(answer).toEqual({
          kind: "start",
          point: { chapterKey: readingNavigationCases.books[testCase.book][0].key, page: 1 },
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

describe("librarySeriesContinue", () => {
  const chapters = [
    { key: "extra", number: null, title: "Extra", published_at: null },
    { key: "c1", number: 1, title: null, published_at: null },
    { key: "c2", number: 2, title: null, published_at: null },
  ];
  const payload = (progress: LibrarySeriesChapters["progress"]): LibrarySeriesChapters => ({
    source_id: "src",
    series_key: "s",
    chapters,
    progress,
  });

  it("is null for a series with no chapters", () => {
    expect(librarySeriesContinue({ ...payload({}), chapters: [] })).toBeNull();
  });

  it("starts at chapter 1, not at an unnumbered extra listed before it", () => {
    expect(librarySeriesContinue(payload({}))).toEqual({
      kind: "start",
      point: { chapterKey: "c1", page: 1 },
    });
  });

  it("a caught-up reader is told so, not sent back into the last chapter", () => {
    const numbered = {
      ...payload({
        c1: { last_page: 20, is_completed: true },
        c2: { last_page: 20, is_completed: true },
      }),
      chapters: chapters.filter((chapter) => chapter.number !== null),
    };
    expect(librarySeriesContinue(numbered)).toEqual({ kind: "caught-up" });
  });

  it("an unnumbered chapter never outranks a numbered one", () => {
    expect(
      librarySeriesContinue(
        payload({
          c1: { last_page: 7, is_completed: false },
          extra: { last_page: 3, is_completed: false },
        }),
      ),
    ).toEqual({ kind: "resume", point: { chapterKey: "c1", page: 7 } });
  });

  // The overlay has no read times, so the tie between chapters of the same
  // rank has to go to the one further along the list. Taking the first sent a
  // reader back into a chapter they had already finished.
  it("in a book that numbers nothing, resumes the chapter furthest along the list", () => {
    const unnumbered = ["a", "b", "c", "d"].map((key) => ({
      key,
      number: null,
      title: null,
      published_at: null,
    }));
    expect(
      librarySeriesContinue({
        ...payload({
          a: { last_page: 20, is_completed: true },
          b: { last_page: 20, is_completed: true },
          c: { last_page: 7, is_completed: false },
        }),
        chapters: unnumbered,
      }),
    ).toEqual({ kind: "resume", point: { chapterKey: "c", page: 7 } });
  });

  it("between chapters that share a number, resumes the later one", () => {
    const split = [
      { key: "c1", number: 1, title: null, published_at: null },
      { key: "c2-part1", number: 2, title: null, published_at: null },
      { key: "c2-part2", number: 2, title: null, published_at: null },
      { key: "c3", number: 3, title: null, published_at: null },
    ];
    expect(
      librarySeriesContinue({
        ...payload({
          c1: { last_page: 20, is_completed: true },
          "c2-part1": { last_page: 20, is_completed: true },
          "c2-part2": { last_page: 4, is_completed: false },
        }),
        chapters: split,
      }),
    ).toEqual({ kind: "resume", point: { chapterKey: "c2-part2", page: 4 } });
  });
});

describe("libraryReadingOrder", () => {
  it("lists numbered chapters by number, then unnumbered ones as the source listed them", () => {
    const order = libraryReadingOrder({
      source_id: "src",
      series_key: "s",
      progress: {},
      chapters: [
        { key: "side-a", number: null, title: null, published_at: null },
        { key: "c2", number: 2, title: null, published_at: null },
        { key: "side-b", number: null, title: null, published_at: null },
        { key: "c1", number: 1, title: null, published_at: null },
      ],
    });
    expect(order.map((chapter) => chapter.key)).toEqual(["c1", "c2", "side-a", "side-b"]);
  });
});
