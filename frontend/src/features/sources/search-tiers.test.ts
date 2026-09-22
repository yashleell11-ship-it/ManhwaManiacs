import { QueryClient, QueryObserver } from "@tanstack/react-query";
import { afterEach, describe, expect, it, vi } from "vitest";

import { sourcesApi } from "./api";
import {
  federatedSearchQueryKey,
  federatedSearchRestOptions,
  mergeSearchTiers,
  resolveSearchTiers,
} from "./hooks";
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

/**
 * Regression: the previous term's tier 2 was shown as the new term's results.
 *
 * Tier 2's key changes with every term, and it used to carry
 * `placeholderData: (previous) => previous`. TanStack hands a pending query the
 * observer's LAST data as that placeholder (the old term's ~87 sources), so the
 * moment the new tier 1 settled, the screen read "N results found" over a mix
 * of the new term's pinned sources and the old term's everything-else.
 */
describe("tier 2 across a change of term", () => {
  const solo = { q: "solo leveling", page: 1, per_page: 40 };
  const orv = { q: "omniscient reader", page: 1, per_page: 40 };

  function observeSoloLeveling(client: QueryClient) {
    const soloFirst = response({ groups: [group("asurascans")], next_tier: 2 });
    const soloRest = response({ groups: [group("mangadex")], sources_queried: 87 });
    client.setQueryData(federatedSearchQueryKey(solo, 2), soloRest);
    const observer = new QueryObserver(client, federatedSearchRestOptions(solo, soloFirst));
    const unsubscribe = observer.subscribe(() => {});
    // The old term's tier 2 really was on screen before the switch.
    expect(observer.getCurrentResult().data).toBe(soloRest);
    return { observer, unsubscribe };
  }

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("does not fold the old term's tier 2 into the new term's tier 1", () => {
    // The new tier 2 never answers inside this test: it stays in flight.
    vi.spyOn(sourcesApi, "federatedSearch").mockReturnValue(new Promise(() => {}));
    const client = new QueryClient();
    const { observer, unsubscribe } = observeSoloLeveling(client);

    const orvFirst = response({ groups: [group("reaperscans")], next_tier: 2 });
    observer.setOptions(federatedSearchRestOptions(orv, orvFirst));
    const shown = resolveSearchTiers(orvFirst, observer.getCurrentResult());

    expect(shown.data?.groups.map((g) => g.source)).toEqual(["reaperscans"]);
    expect(shown.data?.sources_queried).toBe(0);
    // And the screen is told the rest is still coming, not that it is done.
    expect(shown.isLoadingRest).toBe(true);
    unsubscribe();
    client.clear();
  });

  it("drops the old tier 2 when the new term has no tier 2 at all", () => {
    const client = new QueryClient();
    const { observer, unsubscribe } = observeSoloLeveling(client);

    const orvOnly = response({ groups: [group("reaperscans")], next_tier: null });
    observer.setOptions(federatedSearchRestOptions(orv, orvOnly));
    const shown = resolveSearchTiers(orvOnly, observer.getCurrentResult());

    expect(shown.data?.groups.map((g) => g.source)).toEqual(["reaperscans"]);
    expect(shown.isLoadingRest).toBe(false);
    unsubscribe();
    client.clear();
  });
});

describe("resolveSearchTiers", () => {
  it("never merges tier 2 data that is only a placeholder", () => {
    const first = response({ groups: [group("reaperscans")], next_tier: 2 });
    const stale = response({ groups: [group("mangadex")], sources_queried: 87 });

    const shown = resolveSearchTiers(first, {
      data: stale,
      isPending: false,
      isPlaceholderData: true,
    });

    expect(shown.data?.groups.map((g) => g.source)).toEqual(["reaperscans"]);
    expect(shown.isLoadingRest).toBe(true);
  });

  it("merges the real tier 2 and stops saying it is loading", () => {
    const first = response({ groups: [group("reaperscans")], next_tier: 2 });
    const second = response({ groups: [group("mangadex")], next_tier: null });

    const shown = resolveSearchTiers(first, {
      data: second,
      isPending: false,
      isPlaceholderData: false,
    });

    expect(shown.data?.groups.map((g) => g.source)).toEqual(["reaperscans", "mangadex"]);
    expect(shown.isLoadingRest).toBe(false);
  });

  it("shows nothing until tier 1 has answered", () => {
    const shown = resolveSearchTiers(undefined, {
      data: undefined,
      isPending: true,
      isPlaceholderData: false,
    });

    expect(shown.data).toBeUndefined();
    expect(shown.isLoadingRest).toBe(false);
  });
});
