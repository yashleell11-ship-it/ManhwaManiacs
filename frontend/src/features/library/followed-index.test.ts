import { describe, expect, it } from "vitest";
import {
  buildFollowedIndex,
  fetchAllFollowed,
  FOLLOWED_MAX_PAGES,
  followedIdFor,
} from "./followed-index";
import type { FollowedSeries, SeriesListResponse } from "./types";

function row(
  id: number,
  seriesKey: string,
  extra: Partial<FollowedSeries> = {},
): FollowedSeries {
  return {
    id,
    source_id: "asurascans",
    series_key: seriesKey,
    title: `Series ${id}`,
    cover_url: "",
    is_favorite: false,
    reading_status: "reading",
    notify: true,
    sort_order: 0,
    content_rating: "safe",
    rating: "safe",
    mature_override: null,
    chapter_count: 0,
    last_checked_at: null,
    created_at: null,
    updated_at: null,
    ...extra,
  } as FollowedSeries;
}

function page(items: FollowedSeries[], hasNext: boolean): SeriesListResponse {
  return {
    items,
    total: 0,
    page: 1,
    per_page: 200,
    page_size: 200,
    has_next: hasNext,
    has_more: hasNext,
    total_pages: 1,
  };
}

/** A library of `total` follows served 200 a page, the way the server does. */
function library(total: number) {
  const rows = Array.from({ length: total }, (_, i) => row(i + 1, `s-${i + 1}`));
  const asked: number[] = [];
  const fetchPage = async (n: number) => {
    asked.push(n);
    const start = (n - 1) * 200;
    return page(rows.slice(start, start + 200), start + 200 < total);
  };
  return { fetchPage, asked };
}

describe("fetchAllFollowed", () => {
  it("reads every page, so a follow past the first 200 is still in the set", async () => {
    const { fetchPage, asked } = library(250);

    const rows = await fetchAllFollowed(fetchPage);

    expect(rows).toHaveLength(250);
    expect(rows.some((r) => r.series_key === "s-240")).toBe(true);
    expect(asked).toEqual([1, 2]);
  });

  it("covers the whole 1000-follow cap", async () => {
    const { fetchPage, asked } = library(1000);

    expect(await fetchAllFollowed(fetchPage)).toHaveLength(1000);
    expect(asked).toEqual([1, 2, 3, 4, 5]);
  });

  it("drops the row a follow made mid-read serves on two pages", async () => {
    const pages = [page([row(1, "a"), row(2, "b")], true), page([row(2, "b"), row(3, "c")], false)];

    const rows = await fetchAllFollowed(async (n) => pages[n - 1]!);

    expect(rows.map((r) => r.id)).toEqual([1, 2, 3]);
  });

  it("fails whole when a later page fails, rather than answer with a partial set", async () => {
    const fetchPage = async (n: number) => {
      if (n === 2) throw new Error("offline");
      return page([row(n, `s-${n}`)], true);
    };

    await expect(fetchAllFollowed(fetchPage)).rejects.toThrow("offline");
  });

  it("stops at the page ceiling when the server never says it is done", async () => {
    let asked = 0;
    await fetchAllFollowed(async (n) => {
      asked += 1;
      return page([row(n, `s-${n}`)], true);
    });

    expect(asked).toBe(FOLLOWED_MAX_PAGES);
  });
});

describe("followedIdFor", () => {
  const OLD = "the-great-mage-returns-after-4000-years-08677664";
  const NEW = "the-great-mage-returns-after-4000-years-05c7df14";
  const IDENTITY = "the-great-mage-returns-after-4000-years";

  it("finds a follow made under an older Asura key from the new-key page", () => {
    const index = buildFollowedIndex([row(7, OLD, { series_identity: IDENTITY })]);

    expect(
      followedIdFor(index, { sourceId: "asurascans", seriesKey: NEW }, IDENTITY),
    ).toBe(7);
  });

  it("still answers by the exact key, with or without an identity", () => {
    const index = buildFollowedIndex([row(7, OLD, { series_identity: IDENTITY })]);

    expect(followedIdFor(index, { sourceId: "asurascans", seriesKey: OLD })).toBe(7);
  });

  it("does not match a different series, or the same identity on another source", () => {
    const index = buildFollowedIndex([row(7, OLD, { series_identity: IDENTITY })]);

    expect(
      followedIdFor(
        index,
        { sourceId: "asurascans", seriesKey: "the-great-mage-05c7df14" },
        "the-great-mage",
      ),
    ).toBeNull();
    expect(
      followedIdFor(index, { sourceId: "mangadex", seriesKey: NEW }, IDENTITY),
    ).toBeNull();
    expect(followedIdFor(index, { sourceId: "asurascans", seriesKey: NEW })).toBeNull();
  });

  it("treats a row from a server without identities as named by its key", () => {
    const index = buildFollowedIndex([row(3, "solo-leveling")]);

    expect(
      followedIdFor(
        index,
        { sourceId: "asurascans", seriesKey: "other" },
        "solo-leveling",
      ),
    ).toBe(3);
  });
});
