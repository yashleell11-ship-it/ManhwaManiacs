import { beforeEach, describe, expect, it, vi } from "vitest";
import { env } from "@/config/env";
import { http } from "@/services/http";
import type { SourceChapterSummary } from "@/features/sources/types";
import { libraryApi } from "./api";
import {
  historyChapterLabel,
  historyCoverSrc,
  historyResumePoint,
  historyTitle,
} from "./history-continue";

vi.mock("@/services/http", () => ({
  http: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}));

const mocked = vi.mocked(http);

beforeEach(() => {
  vi.clearAllMocks();
});

function chapter(id: string, number: number | null): SourceChapterSummary {
  return {
    id,
    source_id: "asurascans",
    series_id: "orv",
    title: `Chapter ${id}`,
    number,
    page_count: 0,
    release_date: null,
  };
}

// The same table the Flutter half answers
// (mobile/test/features/library/resume_location_test.dart).
describe("historyResumePoint", () => {
  it("reopens an unfinished chapter at its stored position", () => {
    expect(
      historyResumePoint({ chapter_key: "c12", last_page: 60, is_completed: false }),
    ).toEqual({ chapterKey: "c12", page: 60 });
  });

  it("never consults the chapter list for an unfinished chapter", () => {
    expect(
      historyResumePoint({ chapter_key: "c12", last_page: 7, is_completed: false }, [
        chapter("c12", 12),
        chapter("c13", 13),
      ]),
    ).toEqual({ chapterKey: "c12", page: 7 });
  });

  it("opens a stored position of 0 at page 1", () => {
    expect(
      historyResumePoint({ chapter_key: "c1", last_page: 0, is_completed: false }),
    ).toEqual({ chapterKey: "c1", page: 1 });
  });

  it("moves a finished chapter on to the next one, from the top", () => {
    expect(
      historyResumePoint({ chapter_key: "c12", last_page: 40, is_completed: true }, [
        chapter("c11", 11),
        chapter("c12", 12),
        chapter("c13", 13),
      ]),
    ).toEqual({ chapterKey: "c13", page: 1 });
  });

  it("means the next NUMBER even when the source lists newest-first", () => {
    expect(
      historyResumePoint({ chapter_key: "c12", last_page: 40, is_completed: true }, [
        chapter("c13", 13),
        chapter("c12", 12),
        chapter("c11", 11),
      ]),
    ).toEqual({ chapterKey: "c13", page: 1 });
  });

  it("sorts unnumbered extras after the numbered story", () => {
    expect(
      historyResumePoint({ chapter_key: "c2", last_page: 9, is_completed: true }, [
        chapter("omake", null),
        chapter("c2", 2),
        chapter("c3", 3),
      ]),
    ).toEqual({ chapterKey: "c3", page: 1 });
  });

  it("has nothing to continue to after a finished last chapter", () => {
    expect(
      historyResumePoint({ chapter_key: "c13", last_page: 40, is_completed: true }, [
        chapter("c12", 12),
        chapter("c13", 13),
      ]),
    ).toBeNull();
  });

  it("does not guess when the list no longer carries the chapter", () => {
    expect(
      historyResumePoint({ chapter_key: "gone", last_page: 40, is_completed: true }, [
        chapter("c12", 12),
      ]),
    ).toBeNull();
  });

  it("has nothing to continue to when a finished row's list is unavailable", () => {
    expect(
      historyResumePoint({ chapter_key: "c12", last_page: 40, is_completed: true }),
    ).toBeNull();
  });
});

describe("historyTitle", () => {
  it("names the book", () => {
    expect(historyTitle({ series_title: "Shadow Slave" })).toBe("Shadow Slave");
  });

  it("never falls back to the raw series key", () => {
    // A novelarchive key is a database id; it used to be printed as the name.
    expect(historyTitle({ series_title: null })).toBe("Unknown book");
    expect(historyTitle({ series_title: "   " })).toBe("Unknown book");
  });
});

describe("historyCoverSrc", () => {
  it("resolves the relative proxy path production rows carry against the API", () => {
    expect(
      historyCoverSrc({ cover_url: "/sources/asurascans/series/nano-machine-6f7fe6eb/cover" }),
    ).toBe(`${env.apiUrl}/sources/asurascans/series/nano-machine-6f7fe6eb/cover`);
  });

  it("sizes the proxy cover for the tile it is painted into", () => {
    expect(historyCoverSrc({ cover_url: "/sources/a/series/b/cover" }, "64px")).toMatch(
      new RegExp(`^${env.apiUrl}/sources/a/series/b/cover\\?w=\\d+$`),
    );
  });

  it("leaves an absolute cover untouched", () => {
    expect(historyCoverSrc({ cover_url: "https://cdn.example/c.jpg" })).toBe(
      "https://cdn.example/c.jpg",
    );
  });

  it("is null for a row with no cover", () => {
    expect(historyCoverSrc({ cover_url: null })).toBeNull();
    expect(historyCoverSrc({ cover_url: "" })).toBeNull();
  });
});

describe("historyChapterLabel", () => {
  it("prefers the chapter number and falls back to the key", () => {
    expect(historyChapterLabel({ chapter_number: 12, chapter_key: "c12" })).toBe("Ch 12");
    expect(historyChapterLabel({ chapter_number: null, chapter_key: "prologue" })).toBe(
      "prologue",
    );
  });
});

describe("libraryApi.readingHistory", () => {
  it("asks for one row per BOOK", async () => {
    mocked.get.mockResolvedValueOnce([]);
    await libraryApi.readingHistory(50, 0);
    expect(mocked.get).toHaveBeenCalledWith("/reader/history", {
      query: { limit: 50, offset: 0, collapse: "series" },
    });
  });
});
