import { readFileSync } from "node:fs";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createPendingProgress, flushWhenLeaving, type LeaveTargets } from "./pending-progress";

const DELAY = 500;

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

/** A document and window that only carry events, like the reader binds to. */
function leaveTargets() {
  const doc = Object.assign(new EventTarget(), {
    visibilityState: "visible" as DocumentVisibilityState,
  });
  const win = new EventTarget();
  const targets: LeaveTargets = { document: doc, window: win };
  const hide = () => {
    doc.visibilityState = "hidden";
    doc.dispatchEvent(new Event("visibilitychange"));
  };
  const show = () => {
    doc.visibilityState = "visible";
    doc.dispatchEvent(new Event("visibilitychange"));
  };
  const pagehide = () => win.dispatchEvent(new Event("pagehide"));
  return { targets, hide, show, pagehide };
}

describe("createPendingProgress", () => {
  it("debounces a run of writes into the last one", () => {
    const sent: number[] = [];
    const pending = createPendingProgress(DELAY);
    pending.schedule(() => sent.push(1));
    pending.schedule(() => sent.push(2));
    pending.schedule(() => sent.push(3));
    vi.advanceTimersByTime(DELAY - 1);
    expect(sent).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(sent).toEqual([3]);
  });

  it("sends a waiting write at once on flush, and never a second time", () => {
    const sent: number[] = [];
    const pending = createPendingProgress(DELAY);
    pending.schedule(() => sent.push(7));
    pending.flush();
    expect(sent).toEqual([7]);
    vi.advanceTimersByTime(DELAY * 4);
    pending.flush();
    expect(sent).toEqual([7]);
  });

  it("does nothing on flush when nothing is waiting", () => {
    const pending = createPendingProgress(DELAY);
    expect(() => pending.flush()).not.toThrow();
  });

  it("drops a waiting write on cancel", () => {
    const sent: number[] = [];
    const pending = createPendingProgress(DELAY);
    pending.schedule(() => sent.push(1));
    pending.cancel();
    vi.advanceTimersByTime(DELAY * 2);
    pending.flush();
    expect(sent).toEqual([]);
  });
});

describe("flushWhenLeaving", () => {
  it("flushes when the page is hidden, not when it is shown", () => {
    const flush = vi.fn();
    const { targets, hide, show } = leaveTargets();
    flushWhenLeaving(flush, targets);
    show();
    expect(flush).not.toHaveBeenCalled();
    hide();
    expect(flush).toHaveBeenCalledTimes(1);
  });

  it("flushes on pagehide", () => {
    const flush = vi.fn();
    const { targets, pagehide } = leaveTargets();
    flushWhenLeaving(flush, targets);
    pagehide();
    expect(flush).toHaveBeenCalledTimes(1);
  });

  it("flushes on unbind (the reader unmounting) and stops listening", () => {
    const flush = vi.fn();
    const { targets, hide, pagehide } = leaveTargets();
    const unbind = flushWhenLeaving(flush, targets);
    unbind();
    expect(flush).toHaveBeenCalledTimes(1);
    hide();
    pagehide();
    expect(flush).toHaveBeenCalledTimes(1);
  });
});

describe("a debounced novel write when the reader is left", () => {
  // The bug: the unmount cleared the timer, so the write waiting on it was
  // never sent at all.
  it("is sent on unmount, inside the debounce", () => {
    const sent: string[] = [];
    const pending = createPendingProgress(DELAY);
    const { targets } = leaveTargets();
    const unbind = flushWhenLeaving(pending.flush, targets);
    pending.schedule(() => sent.push("bucket 40"));
    vi.advanceTimersByTime(DELAY / 5);
    unbind();
    expect(sent).toEqual(["bucket 40"]);
    vi.advanceTimersByTime(DELAY * 2);
    expect(sent).toEqual(["bucket 40"]);
  });

  it("is sent when the tab is hidden, and the next one still debounces", () => {
    const sent: string[] = [];
    const pending = createPendingProgress(DELAY);
    const { targets, hide } = leaveTargets();
    flushWhenLeaving(pending.flush, targets);
    pending.schedule(() => sent.push("bucket 12"));
    hide();
    expect(sent).toEqual(["bucket 12"]);
    pending.schedule(() => sent.push("bucket 13"));
    expect(sent).toEqual(["bucket 12"]);
    vi.advanceTimersByTime(DELAY);
    expect(sent).toEqual(["bucket 12", "bucket 13"]);
  });

  it("is sent on pagehide", () => {
    const sent: string[] = [];
    const pending = createPendingProgress(DELAY);
    const { targets, pagehide } = leaveTargets();
    flushWhenLeaving(pending.flush, targets);
    pending.schedule(() => sent.push("bucket 99"));
    pagehide();
    expect(sent).toEqual(["bucket 99"]);
  });
});

describe("NovelReader", () => {
  // The reader is a route-level component with no DOM in this suite, so its
  // wiring is asserted on the source: every debounced write goes through the
  // pending write, and leaving flushes it rather than clearing a timer.
  const source = readFileSync(
    join(process.cwd(), "src/features/novels/components/NovelReader.tsx"),
    "utf8",
  );

  it("debounces progress through the pending write", () => {
    expect(source).toContain("createPendingProgress(PROGRESS_SAVE_MS)");
    expect(source).toMatch(/pendingProgress\.schedule\(\(\) => persistProgress\(push\)\)/);
    expect(source).not.toMatch(/setTimeout\(/);
  });

  it("flushes it when the reader is left instead of dropping it", () => {
    expect(source).toMatch(/useEffect\(\(\) => flushWhenLeaving\(pendingProgress\.flush\)/);
    expect(source).not.toMatch(/clearTimeout\(/);
  });
});
