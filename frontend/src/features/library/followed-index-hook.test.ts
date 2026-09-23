import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { followedIndexFor, useFollowedIndex } from "./hooks";
import type { FollowedSeries } from "./types";

function row(id: number, seriesKey: string): FollowedSeries {
  return {
    id,
    source_id: "bato",
    series_key: seriesKey,
    title: seriesKey,
    cover_url: "",
    is_favorite: false,
    reading_status: "reading",
    notify: true,
    sort_order: 0,
    content_rating: "safe",
    rating: "safe",
    mature_override: null,
    chapter_count: 1,
    last_checked_at: null,
    created_at: null,
    updated_at: null,
  };
}

type FollowedIndexResult = ReturnType<typeof useFollowedIndex>;

/** Mounts `count` consumers of the hook over one seeded cache and returns what each got. */
function consume(count: number, rows: FollowedSeries[]): FollowedIndexResult[] {
  const client = new QueryClient();
  client.setQueryData(["library", "followed-index"], rows);
  const results: FollowedIndexResult[] = [];
  function Consumer() {
    results.push(useFollowedIndex());
    return null;
  }
  renderToStaticMarkup(
    createElement(
      QueryClientProvider,
      { client },
      Array.from({ length: count }, (_, key) => createElement(Consumer, { key })),
    ),
  );
  return results;
}

describe("followedIndexFor", () => {
  it("builds one index per fetched list and hands the same one to every caller", () => {
    const rows = [row(1, "a"), row(2, "b")];
    const first = followedIndexFor(rows);
    expect(followedIndexFor(rows)).toBe(first);
    expect(first.index.get("bato:b")).toBe(2);
  });

  it("builds afresh for a new list, as a refetch or an invalidation delivers", () => {
    const rows = [row(1, "a")];
    expect(followedIndexFor([...rows])).not.toBe(followedIndexFor(rows));
  });

  it("answers an empty index before the list has loaded", () => {
    expect(followedIndexFor(undefined).index.size).toBe(0);
    expect(followedIndexFor(undefined)).toBe(followedIndexFor(undefined));
  });
});

describe("useFollowedIndex", () => {
  it("shares one index across every consumer of the same list", () => {
    const [a, b, c] = consume(3, [row(1, "a"), row(2, "b")]);
    expect(a.index).toBe(b.index);
    expect(b.index).toBe(c.index);
    expect(a.index.get("bato:a")).toBe(1);
    expect(a.lookup({ sourceId: "bato", seriesKey: "b" })).toBe(2);
  });

  it("exposes no fetch-cycle state, so a background refetch re-renders no consumer", () => {
    const [result] = consume(1, [row(1, "a")]);
    for (const field of ["isFetching", "fetchStatus", "isStale", "isRefetching", "dataUpdatedAt"]) {
      expect(result).not.toHaveProperty(field);
    }
    expect(result.isSuccess).toBe(true);
    expect(result.data).toHaveLength(1);
  });
});
