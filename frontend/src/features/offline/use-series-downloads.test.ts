import { describe, expect, it } from "vitest";
import type { OfflineState, SavedChapterEntry } from "./types";
import { selectSeriesOffline, seriesOfflineSnapshot } from "./use-series-downloads";

/**
 * A series page re-renders only when a chapter row would look different.
 *
 * The page renders every chapter row with no windowing, and the worker
 * broadcasts about every 300 ms while a chapter saves. A row shows a chapter's
 * download state ("saving", "saved", ...), never its page count, so a
 * broadcast that only moves `savedPages`, or only touches another series, must
 * hand `useSyncExternalStore` the same object it had, which is what stops the
 * re-render.
 */

const REF = { sourceId: "src", seriesKey: "series" };

function entry(chapterKey: string, overrides: Partial<SavedChapterEntry> = {}): SavedChapterEntry {
  return {
    key: `u1p7:src:series:${chapterKey}`,
    sourceId: "src",
    seriesKey: "series",
    chapterKey,
    title: chapterKey,
    seriesTitle: "Series",
    medium: "manga",
    pageCount: 10,
    payloadUrl: `https://api.example/${chapterKey}`,
    urls: [],
    savedPages: 0,
    bytes: 0,
    status: "saving",
    failed: 0,
    stale: false,
    savedAt: 1,
    lastOpenedAt: null,
    readAt: null,
    ...overrides,
  };
}

function state(
  entries: SavedChapterEntry[],
  readiness: OfflineState["readiness"] = "ready",
): OfflineState {
  return {
    readiness,
    scopeToken: "u1p7",
    entries,
    retentionMs: null,
    estimate: null,
    openChapterKey: null,
  };
}

describe("selectSeriesOffline", () => {
  it("keeps the view while an in-flight save only stores more pages", () => {
    const first = selectSeriesOffline(null, state([entry("c1", { savedPages: 1 })]), REF);
    const next = selectSeriesOffline(
      first,
      state([entry("c1", { savedPages: 7, bytes: 7000 })]),
      REF,
    );
    expect(next).toBe(first);
  });

  it("keeps the view when only another series changes", () => {
    const mine = entry("c1", { status: "ready", savedPages: 10 });
    const first = selectSeriesOffline(null, state([mine]), REF);
    const elsewhere = entry("x1", { seriesKey: "other", key: "u1p7:src:other:x1" });
    const next = selectSeriesOffline(
      first,
      state([mine, { ...elsewhere, savedPages: 4 }]),
      REF,
    );
    expect(next).toBe(first);
  });

  it("replaces the view when a chapter's state changes", () => {
    const first = selectSeriesOffline(null, state([entry("c1", { savedPages: 9 })]), REF);
    const done = selectSeriesOffline(
      first,
      state([entry("c1", { status: "ready", savedPages: 10 })]),
      REF,
    );
    expect(done).not.toBe(first);
    expect(done.saved.get("c1")?.status).toBe("ready");
  });

  it("replaces the view when a chapter arrives, leaves, or goes stale", () => {
    const ready = entry("c1", { status: "ready", savedPages: 10 });
    const first = selectSeriesOffline(null, state([ready]), REF);
    expect(selectSeriesOffline(first, state([ready, entry("c2")]), REF)).not.toBe(first);
    expect(selectSeriesOffline(first, state([]), REF)).not.toBe(first);
    expect(
      selectSeriesOffline(first, state([{ ...ready, stale: true }]), REF),
    ).not.toBe(first);
  });

  it("replaces the view when downloads become unavailable", () => {
    const first = selectSeriesOffline(null, state([]), REF);
    const next = selectSeriesOffline(first, state([], "unsupported"), REF);
    expect(next).not.toBe(first);
    expect(next.unavailable).toBe(true);
  });
});

describe("seriesOfflineSnapshot", () => {
  it("returns one object across broadcasts that change nothing a row shows", () => {
    let current = state([entry("c1", { savedPages: 1 })]);
    const getSnapshot = seriesOfflineSnapshot(() => current, REF);
    const first = getSnapshot();
    // React reads the snapshot more than once per render.
    expect(getSnapshot()).toBe(first);

    for (let page = 2; page < 10; page += 1) {
      current = state([entry("c1", { savedPages: page, bytes: page * 1000 })]);
      expect(getSnapshot()).toBe(first);
    }

    current = state([entry("c1", { status: "ready", savedPages: 10 })]);
    const saved = getSnapshot();
    expect(saved).not.toBe(first);
    expect(getSnapshot()).toBe(saved);
  });
});
