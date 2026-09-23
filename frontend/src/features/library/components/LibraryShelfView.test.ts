import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, expect, it } from "vitest";

import { BOOTSTRAP_QUERY_KEY } from "@/features/auth/hooks";
import type { BootstrapStatus } from "@/features/auth/types";
import { LIBRARY_QUERY_ROOT } from "../hooks";
import type { ContinueReadingItem, FollowedSeries, SeriesListResponse } from "../types";
import { LibraryShelfView } from "./LibraryShelfView";

const followed: FollowedSeries = {
  id: 15,
  source_id: "asurascans",
  series_key: "childhood-friend-of-the-zenith-05c7df14",
  series_identity: "childhood-friend-of-the-zenith",
  title: "Childhood Friend of the Zenith",
  cover_url: "/sources/asurascans/series/childhood-friend-of-the-zenith-05c7df14/cover",
  is_favorite: false,
  reading_status: "reading",
  notify: true,
  sort_order: 0,
  content_rating: "safe",
  rating: "safe",
  mature_override: null,
  chapter_count: 107,
  last_checked_at: null,
  created_at: null,
  updated_at: null,
  read_state: {
    started: true,
    chapter_key: "childhood-friend-of-the-zenith-05c7df14:1",
    chapter_number: 1,
    position: 1,
    total: 107,
    latest_number: 107,
    new_count: 106,
  },
};

const resume: ContinueReadingItem = {
  source_id: "asurascans",
  series_key: "childhood-friend-of-the-zenith-05c7df14",
  chapter_key: "childhood-friend-of-the-zenith-05c7df14:1",
  chapter_number: 1,
  last_page: 6,
  page_count: 14,
  last_read_at: "2026-09-22T09:08:31",
};

/**
 * The shelf as the server would answer it, rendered without a browser: every
 * query it reads is already in the cache, so nothing is fetched.
 */
function renderShelf(continueItems: ContinueReadingItem[]): string {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const status: BootstrapStatus = {
    needs_bootstrap: false,
    novels_enabled: false,
  } as BootstrapStatus;
  client.setQueryData(BOOTSTRAP_QUERY_KEY, status);
  const list: SeriesListResponse = {
    items: [followed],
    total: 1,
    page: 1,
    per_page: 200,
    page_size: 1,
    has_next: false,
    has_more: false,
    total_pages: 1,
  };
  client.setQueryData(
    [LIBRARY_QUERY_ROOT, "series", { page: 1, per_page: 200, sort: "recently_updated" }],
    list,
  );
  client.setQueryData([LIBRARY_QUERY_ROOT, "continue-reading", 1], continueItems);
  return renderToStaticMarkup(
    createElement(QueryClientProvider, { client }, createElement(LibraryShelfView)),
  );
}

/** Every element whose class list carries all of `classes`. */
function elementsWith(html: string, classes: string[]): string[] {
  return [...html.matchAll(/<(\w+) class="([^"]*)"/g)]
    .filter(([, , list]) => classes.every((name) => list.split(" ").includes(name)))
    .map(([tag]) => tag);
}

describe("LibraryShelfView continue reading", () => {
  it("renders the shelf from the cache (the harness works)", () => {
    const html = renderShelf([]);
    expect(html).toContain("Childhood Friend of the Zenith");
  });

  it("shows the hero card and rail from md up, not only on /library/browse", () => {
    const html = renderShelf([resume]);
    const rail = elementsWith(html, ["hidden", "md:block"]);
    expect(rail).toHaveLength(1);
    expect(rail[0]).toMatch(/^<section/);
    expect(html).toContain("Continue Reading");
    expect(html).toContain("Jump back in");
  });

  it("keeps the one-row strip below md, so exactly one shows at any width", () => {
    const html = renderShelf([resume]);
    const strip = elementsWith(html, ["md:hidden"]);
    expect(strip).toHaveLength(1);
    expect(strip[0]).toMatch(/^<a/);
    // Neither is visible at both widths.
    expect(elementsWith(html, ["md:hidden", "md:block"])).toHaveLength(0);
  });

  it("names the series on both, from the followed rows when the payload has no title", () => {
    const html = renderShelf([resume]);
    expect(html).toContain("Continue reading Childhood Friend of the Zenith");
    expect(html).toMatch(/Jump back in<\/p><h3[^>]*>Childhood Friend of the Zenith<\/h3>/);
  });

  it("names a series the shelf's rows do not hold from the payload's own title", () => {
    const html = renderShelf([
      {
        ...resume,
        series_key: "surviving-as-a-genius-on-borrowed-time-6f7fe6eb",
        chapter_key: "surviving-as-a-genius-on-borrowed-time-6f7fe6eb:94",
        chapter_number: 94,
        title: "Surviving as a Genius on Borrowed Time",
      },
    ]);
    expect(html).toContain("Continue reading Surviving as a Genius on Borrowed Time");
    expect(html).toMatch(/Jump back in<\/p><h3[^>]*>Surviving as a Genius on Borrowed Time<\/h3>/);
    expect(html).not.toContain(">surviving-as-a-genius-on-borrowed-time-6f7fe6eb<");
  });

  it("shows neither when there is nothing to resume", () => {
    const html = renderShelf([]);
    expect(html).not.toContain("Continue Reading");
    expect(html).not.toContain("Continue reading");
  });
});
