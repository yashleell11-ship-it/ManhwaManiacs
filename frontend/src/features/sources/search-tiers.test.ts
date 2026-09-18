import { describe, expect, it } from "vitest";

import { mergeSearchTiers } from "./hooks";
import type { GlobalSearchResponse } from "./types";

/**
 * A search is two requests now: the sources the reader pins or follows, then
 * everything else. The fold has to leave a result indistinguishable from the
 * single request it replaces — including the footer, which is the part that
 * quietly starts lying if the counts are taken from one tier.
 */
function response(
  over: Partial<GlobalSearchResponse> = {},
): GlobalSearchResponse {
  return {
    items: [],
    groups: [],
    sources_queried: 0,
    sources_failed: 0,
    page: 1,
    has_more: false,
    ...over,
  };
}

function group(source: string | null, count = 1) {
  return {
    source,
    label: source ?? "Library",
    items: Array.from({ length: count }, (_, i) => ({ id: `${source}-${i}` })),
  } as unknown as GlobalSearchResponse["groups"][number];
}

describe("mergeSearchTiers", () => {
  it("is a no-op while the rest is still in flight", () => {
    const first = response({ groups: [group("asurascans")], sources_queried: 4 });

    expect(mergeSearchTiers(first, undefined)).toBe(first);
  });

  it("keeps the local group once, not once per tier", () => {
    // The backend emits the local library on BOTH tiers, because
    // `groups[0] is the local library` is a contract the clients rely on.
    const first = response({ groups: [group(null), group("asurascans")] });
    const second = response({ groups: [group(null), group("mangadex")] });

    const merged = mergeSearchTiers(first, second);

    expect(merged.groups.filter((g) => g.source === null)).toHaveLength(1);
    expect(merged.groups.map((g) => g.source)).toEqual([
      null,
      "asurascans",
      "mangadex",
    ]);
  });

  it("keeps the reader's own sources first", () => {
    // Tier 1 is what they pinned or follow. Folding tier 2 in ahead of it
    // would bury the results they were most likely searching for.
    const first = response({ groups: [group("novelarchive")] });
    const second = response({ groups: [group("mangadex")] });

    expect(mergeSearchTiers(first, second).groups[0].source).toBe("novelarchive");
  });

  it("sums the counts so the footer is honest", () => {
    // Reporting tier 1's four sources as the whole search would be a worse lie
    // than the ten-second wait this replaces.
    const first = response({ sources_queried: 4, sources_failed: 1 });
    const second = response({ sources_queried: 87, sources_failed: 3 });

    const merged = mergeSearchTiers(first, second);

    expect(merged.sources_queried).toBe(91);
    expect(merged.sources_failed).toBe(4);
  });

  it("reports nothing still deferred once the rest has landed", () => {
    const first = response({ sources_deferred: 87, next_tier: 2 });
    const second = response({ sources_deferred: 0, next_tier: null });

    const merged = mergeSearchTiers(first, second);

    expect(merged.sources_deferred).toBe(0);
    expect(merged.next_tier).toBeNull();
  });

  it("carries has_more from either tier", () => {
    const first = response({ has_more: false });
    const second = response({ has_more: true });

    expect(mergeSearchTiers(first, second).has_more).toBe(true);
  });

  it("concatenates the flat item list older clients read", () => {
    const first = response({ items: [{ id: "a" }] as never });
    const second = response({ items: [{ id: "b" }] as never });

    expect(mergeSearchTiers(first, second).items).toHaveLength(2);
  });
});
