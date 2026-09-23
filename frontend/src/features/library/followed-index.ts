/**
 * The whole followed set, and "is this series followed?" over it.
 *
 * `GET /library/series` serves at most 200 rows a page while a profile may
 * follow up to 1000 (`max_follows_per_profile`). Every screen that asks about
 * the *whole* library — the Follow button's index, a collection's grid, its
 * add picker and its remove list — used to read page 1 alone, so past 200
 * follows a series that sorts late looked unfollowed: offered "Follow" on its
 * own page, missing from the picker, and "No longer followed" in the remove
 * dialog while still followed.
 */

import type { SeriesId } from "@/types/api";
import type { FollowedSeries, SeriesListResponse } from "./types";

/** The server's `per_page` ceiling on `GET /library/series`. */
export const FOLLOWED_PAGE_SIZE = 200;

/**
 * Pages past this are not asked for: 1000 follows is five pages, and a
 * server that kept answering `has_next` would otherwise be asked forever.
 */
export const FOLLOWED_MAX_PAGES = 10;

/**
 * Every followed row, page after page until the server says there is no
 * next one. A page that fails fails the whole read rather than returning the
 * pages before it: a partial list is exactly the wrong answer this exists to
 * stop, since a missing row reads as "not followed".
 */
export async function fetchAllFollowed(
  fetchPage: (page: number) => Promise<SeriesListResponse>,
): Promise<FollowedSeries[]> {
  const rows: FollowedSeries[] = [];
  const seen = new Set<string>();
  for (let page = 1; page <= FOLLOWED_MAX_PAGES; page += 1) {
    const response = await fetchPage(page);
    for (const row of response.items) {
      // A follow made between two page reads shifts the rest down a place,
      // which serves the row at the seam twice.
      const key = `${row.source_id}:${row.series_key}`;
      if (seen.has(key)) continue;
      seen.add(key);
      rows.push(row);
    }
    if (!response.has_next || response.items.length === 0) break;
  }
  return rows;
}

export interface FollowedIndex {
  /** `"sourceId:seriesKey" -> followed_id`, by the exact key followed. */
  index: Map<string, number>;
  /** `"sourceId:seriesIdentity" -> followed_id`; see `followedIdFor`. */
  identities: Map<string, number>;
  /** `"sourceId:seriesKey" -> title`. */
  titles: Map<string, string>;
}

export function buildFollowedIndex(
  rows: readonly FollowedSeries[],
): FollowedIndex {
  const index = new Map<string, number>();
  const identities = new Map<string, number>();
  const titles = new Map<string, string>();
  for (const row of rows) {
    const key = `${row.source_id}:${row.series_key}`;
    index.set(key, row.id);
    if (row.title) titles.set(key, row.title);
    const identity = row.series_identity || row.series_key;
    // The first follow wins, the same one the server hands back when the
    // series is followed again under another key.
    const identityKey = `${row.source_id}:${identity}`;
    if (!identities.has(identityKey)) identities.set(identityKey, row.id);
  }
  return { index, identities, titles };
}

/**
 * The follow for the series on a page, or `null`.
 *
 * By the exact key first. Failing that, by `seriesIdentity` — the page
 * payload's own `series_identity` — because Asura rotates the suffix on its
 * slugs: a series followed under last week's key is served this week under
 * another, and matched by key alone the page offered "Follow" for a series
 * already followed. The identity is the connector's answer, compared as
 * given; nothing here reads meaning into a key.
 */
export function followedIdFor(
  followed: Pick<FollowedIndex, "index" | "identities">,
  ref: SeriesId,
  seriesIdentity?: string | null,
): number | null {
  const exact = followed.index.get(`${ref.sourceId}:${ref.seriesKey}`);
  if (exact !== undefined) return exact;
  if (!seriesIdentity) return null;
  return followed.identities.get(`${ref.sourceId}:${seriesIdentity}`) ?? null;
}
