import { describe, expect, it } from "vitest";
import { env } from "@/config/env";
import { withCoverWidth } from "@/lib/cover-url";
import { sourceImageUrl } from "./api";
import {
  globalSearchHref,
  globalSearchScopeLabel,
  LOCAL_SEARCH_GROUP_KEY,
  replaceSearchGroup,
  resolveSearchCovers,
  searchGroupFromSourceSeries,
  searchGroupKey,
  searchGroupNote,
  searchGroupWithError,
  searchResultCount,
  splitSearchGroups,
  withResolvedCover,
} from "./global-search";
import { prettifySourceId } from "./source-branding";
import type {
  GlobalSearchGroup,
  GlobalSearchItem,
  GlobalSearchResponse,
  PaginatedSourceSeries,
  SourceSeriesSummary,
} from "./types";

function item(overrides: Partial<GlobalSearchItem> = {}): GlobalSearchItem {
  return {
    kind: "source",
    source: "mangadex",
    series_id: "abc-123",
    title: "Some Series",
    cover_url: "https://cdn.example.com/cover.jpg",
    author: null,
    extra: null,
    ...overrides,
  };
}

function group(overrides: Partial<GlobalSearchGroup> = {}): GlobalSearchGroup {
  return {
    source: "mangadex",
    source_name: "MangaDex",
    icon_url: null,
    status: "ok",
    error: null,
    total: 1,
    has_more: false,
    items: [item()],
    ...overrides,
  };
}

describe("globalSearchHref", () => {
  it("routes local hits to the library series route", () => {
    expect(globalSearchHref(item({ kind: "local", source: null, series_id: "42" }))).toBe(
      "/library/42",
    );
  });

  it("routes source hits to the source series route", () => {
    expect(globalSearchHref(item({ source: "mangadex", series_id: "abc-123" }))).toBe(
      "/sources/mangadex/series/abc-123",
    );
  });

  it("percent-encodes source series ids containing unsafe path characters", () => {
    expect(
      globalSearchHref(item({ source: "toonily", series_id: "manga/slug?x=1" })),
    ).toBe("/sources/toonily/series/manga%2Fslug%3Fx%3D1");
  });
});

describe("globalSearchScopeLabel", () => {
  it("returns null when no sources were queried", () => {
    expect(globalSearchScopeLabel(0, 0)).toBeNull();
  });

  it("summarizes the queried source count", () => {
    expect(globalSearchScopeLabel(5, 0)).toBe("Searched 5 sources");
  });

  it("uses the singular noun for a single source", () => {
    expect(globalSearchScopeLabel(1, 0)).toBe("Searched 1 source");
  });

  it("appends a failed count when some sources failed", () => {
    expect(globalSearchScopeLabel(5, 2)).toBe("Searched 5 sources (2 failed)");
  });
});

describe("searchGroupKey", () => {
  it("keys a source group by its connector id", () => {
    expect(searchGroupKey(group({ source: "toonily" }))).toBe("toonily");
  });

  it("gives the local library group a key of its own", () => {
    expect(searchGroupKey(group({ source: null }))).toBe(LOCAL_SEARCH_GROUP_KEY);
  });
});

describe("searchResultCount", () => {
  it("counts hits across every section", () => {
    expect(
      searchResultCount([
        group({ items: [item(), item({ series_id: "b" })] }),
        group({ source: "toonily", items: [] }),
        group({ source: "bato", items: [item({ series_id: "c" })] }),
      ]),
    ).toBe(3);
  });
});

describe("searchGroupNote", () => {
  it("returns nothing for a section that has results", () => {
    expect(searchGroupNote(group())).toBeNull();
  });

  it("surfaces the backend's message for a failed source", () => {
    expect(
      searchGroupNote(group({ status: "error", error: "Timed out", items: [] })),
    ).toBe("Timed out");
  });

  it("falls back to a generic message when a failure carries none", () => {
    expect(searchGroupNote(group({ status: "error", error: null, items: [] }))).toBe(
      "This source did not answer.",
    );
  });

  it("keeps the 'returned noise' explanation on an empty section", () => {
    // The backend discarded results unrelated to the query — different from
    // the source simply having nothing.
    expect(
      searchGroupNote(
        group({ status: "empty", error: "Source returned 82 results unrelated to the query; ignored.", items: [] }),
      ),
    ).toBe("Source returned 82 results unrelated to the query; ignored.");
  });

  it("says so plainly when a source just had nothing", () => {
    expect(searchGroupNote(group({ status: "empty", error: null, items: [] }))).toBe(
      "No matches",
    );
  });
});

describe("splitSearchGroups", () => {
  it("keeps failed sources visible even with no items, so a retry is reachable", () => {
    const failed = group({ source: "bato", status: "error", error: "Timed out", items: [] });
    const silent = group({ source: "toonily", status: "empty", error: null, items: [] });
    const { visible, quiet } = splitSearchGroups([group(), failed, silent]);
    expect(visible.map((entry) => entry.source)).toEqual(["mangadex", "bato"]);
    expect(quiet.map((entry) => entry.source)).toEqual(["toonily"]);
  });

  it("preserves the server's group order in both buckets", () => {
    const groups = [
      group({ source: "a", items: [] , status: "empty" }),
      group({ source: "b" }),
      group({ source: "c", items: [], status: "empty" }),
    ];
    const { visible, quiet } = splitSearchGroups(groups);
    expect(visible.map((entry) => entry.source)).toEqual(["b"]);
    expect(quiet.map((entry) => entry.source)).toEqual(["a", "c"]);
  });
});

describe("replaceSearchGroup", () => {
  function response(groups: GlobalSearchGroup[]): GlobalSearchResponse {
    return {
      items: [item()],
      groups,
      sources_queried: groups.length,
      sources_failed: 0,
      page: 1,
      has_more: false,
    };
  }

  it("swaps one section in place, leaving the rest and their order alone", () => {
    const original = response([
      group({ source: null, source_name: "My Library" }),
      group({ source: "bato", status: "error", error: "Timed out", items: [] }),
      group({ source: "toonily" }),
    ]);
    const fixed = group({ source: "bato", source_name: "Bato", items: [item({ source: "bato" })] });

    const next = replaceSearchGroup(original, fixed);

    expect(next.groups.map(searchGroupKey)).toEqual([
      LOCAL_SEARCH_GROUP_KEY,
      "bato",
      "toonily",
    ]);
    expect(next.groups[1]).toBe(fixed);
    expect(original.groups[1].status).toBe("error");
  });

  it("leaves the legacy flat list untouched -- the web renders groups", () => {
    const original = response([group({ source: "bato", items: [] })]);
    const next = replaceSearchGroup(original, group({ source: "bato" }));
    expect(next.items).toBe(original.items);
  });
});

describe("searchGroupFromSourceSeries", () => {
  function series(overrides: Partial<SourceSeriesSummary> = {}): SourceSeriesSummary {
    return {
      id: "series-1",
      source_id: "bato",
      title: "Lookism",
      chapter_count: 500,
      description: null,
      author: "Park Tae-joon",
      artist: null,
      status: null,
      genres: [],
      latest_chapter: null,
      cover_url: "/sources/bato/series/series-1/cover",
      ...overrides,
    };
  }

  function page(items: SourceSeriesSummary[], hasMore = false): PaginatedSourceSeries {
    return { items, page: 1, page_size: 40, total: items.length, total_pages: 1, has_more: hasMore };
  }

  const absolute = (path: string) => `https://api.example.com${path}`;

  it("rebuilds a failed section from that source's own browse response", () => {
    const failed = group({ source: "bato", status: "error", error: "Timed out", items: [], total: 0 });

    const next = searchGroupFromSourceSeries(failed, page([series()], true), absolute);

    expect(next.status).toBe("ok");
    expect(next.error).toBeNull();
    expect(next.total).toBe(1);
    expect(next.has_more).toBe(true);
    expect(next.items[0]).toEqual({
      kind: "source",
      source: "bato",
      series_id: "series-1",
      title: "Lookism",
      cover_url: "https://api.example.com/sources/bato/series/series-1/cover",
      author: "Park Tae-joon",
      chapter_count: 500,
      extra: null,
    });
  });

  it("keeps the section's identity and branding", () => {
    const failed = group({ source: "bato", source_name: "Bato", icon_url: "/icon.png", items: [] });
    const next = searchGroupFromSourceSeries(failed, page([]), absolute);
    expect(next.source).toBe("bato");
    expect(next.source_name).toBe("Bato");
    expect(next.icon_url).toBe("/icon.png");
  });

  it("reports an empty answer as empty rather than as a failure", () => {
    const failed = group({ source: "bato", status: "error", error: "Timed out", items: [] });
    const next = searchGroupFromSourceSeries(failed, page([]), absolute);
    expect(next.status).toBe("empty");
    expect(next.error).toBeNull();
  });
});

describe("resolveSearchCovers", () => {
  // What `sourcesApi.federatedSearch` resolves with.
  const resolve = (path: string) => sourceImageUrl(path);
  const relative = "/sources/mangadex/series/md%2F1/cover";

  function response(items: GlobalSearchItem[]): GlobalSearchResponse {
    return {
      items,
      groups: [group({ items })],
      sources_queried: 1,
      sources_failed: 0,
      page: 1,
      has_more: false,
    };
  }

  it("resolves a relative cover against the API base, in groups and flat items", () => {
    // The backend can no longer send an absolute cover: the host it sees
    // behind the /api rewrite is its own container name.
    const resolved = resolveSearchCovers(response([item({ cover_url: relative })]), resolve);
    const expected = `${env.apiUrl}/sources/mangadex/series/md%2F1/cover`;
    expect(resolved.groups[0].items[0].cover_url).toBe(expected);
    expect(resolved.items[0].cover_url).toBe(expected);
  });

  it("leaves a missing cover missing and an absolute one untouched", () => {
    const resolved = resolveSearchCovers(
      response([
        item({ series_id: "a", cover_url: null }),
        item({ series_id: "b", cover_url: "https://cdn.example.com/cover.jpg" }),
      ]),
      resolve,
    );
    expect(resolved.groups[0].items.map((hit) => hit.cover_url)).toEqual([
      null,
      "https://cdn.example.com/cover.jpg",
    ]);
  });

  it("hands the card a URL it can still size", () => {
    const resolved = resolveSearchCovers(response([item({ cover_url: relative })]), resolve);
    expect(withCoverWidth(resolved.groups[0].items[0].cover_url!, "80px")).toMatch(
      /\/cover\?w=\d+$/,
    );
  });
});

describe("withResolvedCover", () => {
  it("keeps a suggestion's own fields", () => {
    const suggestion = { ...item({ cover_url: "/sources/x/series/k/cover" }), why: "Swords." };
    const resolved = withResolvedCover(suggestion, (path) => `/api${path}`);
    expect(resolved).toEqual({ ...suggestion, cover_url: "/api/sources/x/series/k/cover" });
  });
});

describe("searchGroupWithError", () => {
  it("marks a section failed and drops its stale items", () => {
    const next = searchGroupWithError(group(), "Still down");
    expect(next).toMatchObject({
      status: "error",
      error: "Still down",
      items: [],
      total: 0,
      has_more: false,
    });
  });
});

describe("prettifySourceId", () => {
  it("capitalizes a source id", () => {
    expect(prettifySourceId("mangadex")).toBe("Mangadex");
  });

  it("returns an empty string unchanged", () => {
    expect(prettifySourceId("")).toBe("");
  });
});
