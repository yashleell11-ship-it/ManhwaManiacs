import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { StripChapter } from "./strip";
import {
  createStripProgressTracker,
  PROGRESS_SAVE_MS,
  type ProgressWriteBody,
} from "./strip-progress";

function chapter(key: string, pageCount: number, number: number): StripChapter {
  return {
    sourceId: "asurascans",
    seriesKey: "series/one",
    chapterKey: key,
    chapterNumber: number,
    title: `Chapter ${number}`,
    pageCount,
    previousChapterKey: null,
    nextChapterKey: null,
    pages: Array.from({ length: pageCount }, (_, index) => ({
      id: `${key}:${index + 1}`,
      number: index + 1,
      imageUrl: `/img/${key}/${index + 1}`,
      width: null,
      height: null,
    })),
  };
}

const one = chapter("ch-1", 20, 1);
const two = chapter("ch-2", 10, 2);

function setup(chapters: readonly StripChapter[] = [one, two]) {
  const writes: Array<{ chapterKey: string; body: ProgressWriteBody }> = [];
  const tracker = createStripProgressTracker({
    chapters: () => chapters,
    takeElapsed: () => 3,
    save: (chapterKey, body) => writes.push({ chapterKey, body }),
  });
  return { tracker, writes };
}

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("createStripProgressTracker", () => {
  it("debounces a run of reports into one write of the furthest page", () => {
    const { tracker, writes } = setup();
    for (let page = 1; page <= 5; page += 1) {
      tracker.report({ chapterKey: "ch-1", pageNumber: page, pageCount: 20 });
    }
    expect(writes).toHaveLength(0);
    vi.advanceTimersByTime(PROGRESS_SAVE_MS);
    expect(writes).toEqual([
      {
        chapterKey: "ch-1",
        body: {
          chapter_number: 1,
          last_page: 5,
          page_count: 20,
          is_completed: false,
          time_spent_seconds: 3,
        },
      },
    ]);
  });

  it("never rewinds a chapter", () => {
    const { tracker, writes } = setup();
    tracker.report({ chapterKey: "ch-1", pageNumber: 8, pageCount: 20 });
    vi.advanceTimersByTime(PROGRESS_SAVE_MS);
    tracker.report({ chapterKey: "ch-1", pageNumber: 3, pageCount: 20 });
    vi.advanceTimersByTime(PROGRESS_SAVE_MS);
    expect(writes.map((write) => write.body.last_page)).toEqual([8]);
  });

  it("marks the chapter complete when its last page is reached", () => {
    const { tracker, writes } = setup();
    tracker.report({ chapterKey: "ch-1", pageNumber: 20, pageCount: 20 });
    vi.advanceTimersByTime(PROGRESS_SAVE_MS);
    expect(writes).toHaveLength(1);
    expect(writes[0].body).toMatchObject({ last_page: 20, is_completed: true });
  });

  it("flush sends the waiting write at once instead of dropping it", () => {
    const { tracker, writes } = setup();
    tracker.report({ chapterKey: "ch-1", pageNumber: 20, pageCount: 20 });
    // The reader leaves before the debounce fires (Back, a route into the next
    // chapter): the completion must still reach the server.
    tracker.flush();
    expect(writes).toHaveLength(1);
    expect(writes[0]).toMatchObject({
      chapterKey: "ch-1",
      body: { last_page: 20, is_completed: true },
    });
    // ...and exactly once: the cancelled timer does not send it again.
    vi.advanceTimersByTime(PROGRESS_SAVE_MS * 2);
    expect(writes).toHaveLength(1);
  });

  it("flush with nothing waiting sends nothing", () => {
    const { tracker, writes } = setup();
    tracker.report({ chapterKey: "ch-1", pageNumber: 4, pageCount: 20 });
    vi.advanceTimersByTime(PROGRESS_SAVE_MS);
    tracker.flush();
    tracker.flush();
    expect(writes).toHaveLength(1);
  });

  it("crossing forwards completes the chapter left behind, once", () => {
    const { tracker, writes } = setup();
    tracker.report({ chapterKey: "ch-1", pageNumber: 20, pageCount: 20 });
    tracker.report({ chapterKey: "ch-2", pageNumber: 1, pageCount: 10 });
    vi.advanceTimersByTime(PROGRESS_SAVE_MS);
    expect(writes).toEqual([
      expect.objectContaining({
        chapterKey: "ch-1",
        body: expect.objectContaining({ last_page: 20, is_completed: true }),
      }),
      expect.objectContaining({
        chapterKey: "ch-2",
        body: expect.objectContaining({ last_page: 1, is_completed: false }),
      }),
    ]);
  });

  it("moving back a chapter sends the page still waiting in the one left", () => {
    const { tracker, writes } = setup();
    tracker.report({ chapterKey: "ch-2", pageNumber: 4, pageCount: 10 });
    tracker.report({ chapterKey: "ch-1", pageNumber: 20, pageCount: 20 });
    vi.advanceTimersByTime(PROGRESS_SAVE_MS);
    expect(writes.map((write) => [write.chapterKey, write.body.last_page])).toEqual([
      ["ch-2", 4],
      ["ch-1", 20],
    ]);
  });
});
