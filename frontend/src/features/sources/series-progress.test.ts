import { describe, expect, it } from "vitest";
import {
  mergeSeriesProgress,
  resolveSeriesProgress,
  serverProgressMap,
  type ServerChapterProgress,
} from "./series-progress";
import type { SourceSeriesProgressMap } from "./source-progress";

function serverRow(
  chapter_key: string,
  last_page: number,
  last_read_at: string | null,
  is_completed = false,
): ServerChapterProgress {
  return { chapter_key, last_page, page_count: 20, is_completed, last_read_at };
}

describe("serverProgressMap", () => {
  it("keys stored positions by chapter key", () => {
    const map = serverProgressMap([serverRow("ch-3", 12, "2026-09-04T10:00:00")]);
    expect(map["ch-3"]).toEqual({
      page: 12,
      pageCount: 20,
      completed: false,
      updatedAt: "2026-09-04T10:00:00",
    });
  });

  it("never reports a page below one", () => {
    expect(serverProgressMap([serverRow("ch-1", 0, null)])["ch-1"]?.page).toBe(1);
  });
});

describe("mergeSeriesProgress", () => {
  it("lets the server override a local record for the same chapter", () => {
    const local: SourceSeriesProgressMap = {
      "ch-1": { page: 2, pageCount: 20, completed: false, updatedAt: "2020-01-01T00:00:00Z" },
    };
    const merged = mergeSeriesProgress(
      local,
      serverProgressMap([serverRow("ch-1", 19, "2026-09-04T10:00:00")]),
    );
    expect(merged["ch-1"]?.page).toBe(19);
  });

  it("keeps a local record the server has never heard of", () => {
    const local: SourceSeriesProgressMap = {
      "ch-legacy": { page: 5, pageCount: 20, completed: false, updatedAt: "2020-01-01T00:00:00Z" },
    };
    const merged = mergeSeriesProgress(local, serverProgressMap([]));
    expect(merged["ch-legacy"]?.page).toBe(5);
  });
});

describe("resolveSeriesProgress", () => {
  it("shows the position the reader saved to the server", () => {
    // The regression: the reader posts progress to `/reader/progress`, and the
    // series page must render it. It used to read only the client-side store
    // that nothing writes any more, so every chapter looked unread and the
    // Continue button never appeared.
    const view = resolveSeriesProgress({
      serverRows: [
        serverRow("ch-1", 20, "2026-09-01T10:00:00", true),
        serverRow("ch-2", 7, "2026-09-04T10:00:00"),
      ],
      localMap: {},
    });

    expect(view.map["ch-1"]?.completed).toBe(true);
    expect(view.map["ch-2"]).toEqual({
      page: 7,
      pageCount: 20,
      completed: false,
      updatedAt: "2026-09-04T10:00:00",
    });
  });

  it("still surfaces an adopted local position for a chapter the server lacks", () => {
    const view = resolveSeriesProgress({
      serverRows: [],
      localMap: {
        "ch-legacy": {
          page: 11,
          pageCount: 20,
          completed: false,
          updatedAt: "2026-08-01T00:00:00Z",
        },
      },
    });
    expect(view.map["ch-legacy"]?.page).toBe(11);
  });
});
