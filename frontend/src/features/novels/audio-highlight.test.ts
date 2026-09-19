import { describe, expect, it, vi } from "vitest";

import { ACTIVE_CLASS, createHighlighter } from "./audio-highlight";

/**
 * Tested against a fake root rather than jsdom, which also pins how little
 * this is allowed to touch: `querySelector`, `classList`, `scrollIntoView`.
 * The reason it exists at all is that `timeupdate` fires ~4x a second, and
 * driving that through React would re-render a page of prose that often — on
 * the one screen where a stutter is least acceptable.
 */
function fakeNode(segment: number) {
  const classes = new Set<string>();
  return {
    segment,
    classList: {
      add: (c: string) => classes.add(c),
      remove: (c: string) => classes.delete(c),
    },
    scrollIntoView: vi.fn(),
    has: (c: string) => classes.has(c),
  };
}

function fakeRoot(segments: number[]) {
  const nodes = new Map(segments.map((n) => [n, fakeNode(n)]));
  const queries: string[] = [];
  const root = {
    querySelector: (selector: string) => {
      queries.push(selector);
      const match = /data-segment="(\d+)"/.exec(selector);
      return match ? (nodes.get(Number(match[1])) ?? null) : null;
    },
  };
  return { root: root as unknown as HTMLElement, nodes, queries };
}

describe("createHighlighter", () => {
  it("lights up the segment being spoken", () => {
    const { root, nodes } = fakeRoot([0, 1, 2]);
    const h = createHighlighter(() => root);

    h.set(1);

    expect(nodes.get(1)!.has(ACTIVE_CLASS)).toBe(true);
  });

  it("moves the highlight rather than accumulating them", () => {
    const { root, nodes } = fakeRoot([0, 1, 2]);
    const h = createHighlighter(() => root);

    h.set(1);
    h.set(2);

    expect(nodes.get(1)!.has(ACTIVE_CLASS)).toBe(false);
    expect(nodes.get(2)!.has(ACTIVE_CLASS)).toBe(true);
  });

  it("does not touch the DOM when the segment has not changed", () => {
    // The playhead reports the same segment many times before it moves on.
    // Re-querying each time would be the entire cost of this feature.
    const { root, queries } = fakeRoot([0, 1]);
    const h = createHighlighter(() => root);

    h.set(1);
    h.set(1);
    h.set(1);

    expect(queries).toHaveLength(1);
  });

  it("clears when playback stops", () => {
    // One sentence left lit after the voice stops reads as a bug.
    const { root, nodes } = fakeRoot([0, 1]);
    const h = createHighlighter(() => root);

    h.set(1);
    h.set(null);

    expect(nodes.get(1)!.has(ACTIVE_CLASS)).toBe(false);
  });

  it("clears rather than guessing when the segment is gone", () => {
    // A refetched chapter, or a timing map from a different render. Lighting
    // up whatever happens to sit there now would be worse than nothing.
    const { root, nodes } = fakeRoot([0, 1]);
    const h = createHighlighter(() => root);

    h.set(1);
    h.set(99);

    expect(nodes.get(1)!.has(ACTIVE_CLASS)).toBe(false);
  });

  it("re-queries after a miss rather than staying stuck", () => {
    const { root, queries } = fakeRoot([0, 1]);
    const h = createHighlighter(() => root);

    h.set(99);
    h.set(99);

    expect(queries).toHaveLength(2);
  });

  it("survives a root that is not mounted yet", () => {
    const h = createHighlighter(() => null);

    expect(() => h.set(1)).not.toThrow();
  });

  it("scrolls only when asked", () => {
    const { root, nodes } = fakeRoot([0, 1]);

    createHighlighter(() => root).set(1);
    expect(nodes.get(1)!.scrollIntoView).not.toHaveBeenCalled();

    createHighlighter(() => root, { scroll: true }).set(1);
    expect(nodes.get(1)!.scrollIntoView).toHaveBeenCalledWith({
      // "nearest", so a reader who scrolled ahead is not yanked back on every
      // sentence — it moves only once the line has actually left view.
      block: "nearest",
      behavior: "smooth",
    });
  });

  it("cleans up after itself", () => {
    const { root, nodes } = fakeRoot([0, 1]);
    const h = createHighlighter(() => root);

    h.set(1);
    h.dispose();

    expect(nodes.get(1)!.has(ACTIVE_CLASS)).toBe(false);
  });
});
