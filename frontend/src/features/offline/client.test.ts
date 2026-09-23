import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { OfflineState, OfflineWorkerState, SavedChapterEntry } from "./types";

/**
 * The page's copy of the worker's state is published only when it changed.
 *
 * While any chapter is saving the worker broadcasts about every 300 ms, and
 * every broadcast is a fresh structured clone. Publishing each one as a new
 * snapshot re-rendered every subscriber, and on a series page a subscriber is
 * an unwindowed chapter list. These pin that a repeat is not a change, that a
 * change to one entry leaves the others' objects alone, and that the download
 * queue's stall clock still hears a worker that is repeating itself.
 */

type Listener = (event: { type: string; data?: unknown }) => void;

const g = globalThis as unknown as Record<string, unknown>;

function entry(overrides: Partial<SavedChapterEntry> = {}): SavedChapterEntry {
  return {
    key: "u1p7:src:series:c1",
    sourceId: "src",
    seriesKey: "series",
    chapterKey: "c1",
    title: "Chapter 1",
    seriesTitle: "Series",
    medium: "manga",
    pageCount: 10,
    payloadUrl: "https://api.example/chapters/c1",
    urls: ["https://img.example/1.jpg", "https://img.example/2.jpg"],
    savedPages: 2,
    bytes: 2048,
    status: "saving",
    failed: 0,
    stale: false,
    savedAt: 1,
    lastOpenedAt: null,
    readAt: null,
    ...overrides,
  };
}

function workerState(entries: SavedChapterEntry[]): OfflineWorkerState {
  return {
    scopeToken: "u1p7",
    entries,
    retentionMs: null,
    estimate: { usage: 100, quota: 1000 },
    openChapterKey: null,
  };
}

/** A structured clone, which is what every `postMessage` delivers. */
function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

/** Just enough `window` for `client.ts` to register and hear the worker. */
function mountPage() {
  const containerListeners = new Map<string, Set<Listener>>();
  const target = (map: Map<string, Set<Listener>>) => ({
    addEventListener(type: string, listener: Listener) {
      if (!map.has(type)) map.set(type, new Set());
      map.get(type)!.add(listener);
    },
    removeEventListener(type: string, listener: Listener) {
      map.get(type)?.delete(listener);
    },
  });
  const active = { postMessage() {} };
  const registration = { active, waiting: null, installing: null, addEventListener() {} };
  g.document = { visibilityState: "visible", ...target(new Map()) };
  g.window = {
    isSecureContext: true,
    location: { origin: "https://manhwa.example" },
    setTimeout: (fn: () => void, ms: number) => setTimeout(fn, ms),
    clearTimeout: (id: unknown) => clearTimeout(id as NodeJS.Timeout),
    navigator: {
      serviceWorker: {
        ...target(containerListeners),
        controller: active,
        ready: Promise.resolve(registration),
        register: async () => registration,
      },
      storage: { persisted: async () => true, persist: async () => true },
    },
  };
  return {
    broadcast(state: OfflineWorkerState) {
      for (const listener of containerListeners.get("message") ?? []) {
        listener({ type: "message", data: { type: "mm-offline/state", state: clone(state) } });
      }
    },
  };
}

async function loadClient() {
  vi.resetModules();
  return import("./client");
}

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_ENABLE_SW", "1");
});

afterEach(() => {
  vi.unstubAllEnvs();
  delete g.window;
  delete g.document;
});

describe("worker state broadcasts", () => {
  it("does not publish a broadcast that repeats the last one", async () => {
    const page = mountPage();
    const client = await loadClient();
    await client.registerOfflineWorker();
    let published = 0;
    client.subscribeOffline(() => {
      published += 1;
    });

    const state = workerState([entry()]);
    page.broadcast(state);
    const first = client.getOfflineSnapshot();
    page.broadcast(state);
    page.broadcast(state);

    expect(published).toBe(1);
    expect(client.getOfflineSnapshot()).toBe(first);
  });

  it("publishes a real change, and keeps the objects of the entries that did not change", async () => {
    const page = mountPage();
    const client = await loadClient();
    await client.registerOfflineWorker();
    const other = entry({ key: "u1p7:src:other:c9", seriesKey: "other", chapterKey: "c9", status: "ready", savedPages: 10 });
    page.broadcast(workerState([entry(), other]));
    const before = client.getOfflineSnapshot();
    let published = 0;
    client.subscribeOffline(() => {
      published += 1;
    });

    page.broadcast(workerState([entry({ savedPages: 3, bytes: 3072 }), other]));

    const after = client.getOfflineSnapshot();
    expect(published).toBe(1);
    expect(after).not.toBe(before);
    expect(after.entries[0].savedPages).toBe(3);
    expect(after.entries[0]).not.toBe(before.entries[0]);
    expect(after.entries[1]).toBe(before.entries[1]);
    expect(after.estimate).toBe(before.estimate);
  });

  it("still tells the stall clock about a repeat", async () => {
    const page = mountPage();
    const client = await loadClient();
    await client.registerOfflineWorker();
    let heard = 0;
    client.subscribeWorkerHeard(() => {
      heard += 1;
    });

    const state = workerState([entry()]);
    page.broadcast(state);
    page.broadcast(state);

    expect(heard).toBe(2);
  });
});

describe("reconcileOfflineState", () => {
  it("returns the previous state when nothing differs", async () => {
    const { reconcileOfflineState } = await loadClient();
    const previous: OfflineState = { ...workerState([entry()]), readiness: "ready" };
    expect(reconcileOfflineState(previous, clone(previous))).toBe(previous);
  });

  it("notices a change anywhere, not only in the fields a row shows", async () => {
    const { reconcileOfflineState } = await loadClient();
    const previous: OfflineState = { ...workerState([entry()]), readiness: "ready" };
    const changes: OfflineState[] = [
      { ...clone(previous), readiness: "unscoped" },
      { ...clone(previous), openChapterKey: "u1p7:src:series:c1" },
      { ...clone(previous), estimate: { usage: 101, quota: 1000 } },
      { ...clone(previous), entries: [entry({ urls: ["https://img.example/1.jpg"] })] },
      { ...clone(previous), entries: [entry({ lastOpenedAt: 5 })] },
      { ...clone(previous), entries: [] },
    ];
    for (const next of changes) {
      expect(reconcileOfflineState(previous, next)).not.toBe(previous);
    }
  });

  it("reuses each entry's object when the worker reorders the list", async () => {
    const { reconcileOfflineState } = await loadClient();
    const a = entry();
    const b = entry({ key: "k2", chapterKey: "c2" });
    const previous: OfflineState = { ...workerState([a, b]), readiness: "ready" };
    const reordered = reconcileOfflineState(previous, {
      ...previous,
      entries: clone([b, a]),
    });
    expect(reordered).not.toBe(previous);
    expect(reordered.entries[0]).toBe(b);
    expect(reordered.entries[1]).toBe(a);
  });
});
