import type {
  GlobalSearchGroup,
  GlobalSearchItem,
  GlobalSearchResponse,
  PaginatedSourceSeries,
} from "./types";

/**
 * Route a federated search hit to its detail page:
 * - `local`  → the local library series route `/library/{series_id}`.
 * - `source` → the source series route
 *   `/sources/{source}/series/{encodeURIComponent(series_id)}`.
 *
 * `series_id` is used verbatim for local ids (numeric strings) and
 * percent-encoded for source ids, which may contain slashes or other unsafe
 * path characters.
 */
export function globalSearchHref(item: GlobalSearchItem): string {
  if (item.kind === "local") {
    return `/library/${item.series_id}`;
  }
  return `/sources/${item.source}/series/${encodeURIComponent(item.series_id)}`;
}

/**
 * Human summary of how wide a federated search reached, e.g.
 * `"Searched 5 sources"` or `"Searched 5 sources (2 failed)"`. Returns null when
 * no sources were queried, so callers can omit the line entirely.
 */
export function globalSearchScopeLabel(
  sourcesQueried: number,
  sourcesFailed: number,
): string | null {
  if (sourcesQueried <= 0) {
    return null;
  }
  const noun = sourcesQueried === 1 ? "source" : "sources";
  const base = `Searched ${sourcesQueried} ${noun}`;
  return sourcesFailed > 0 ? `${base} (${sourcesFailed} failed)` : base;
}

/** React key / identity for the local-library group, which has no source id. */
export const LOCAL_SEARCH_GROUP_KEY = "@local";

export function isLocalSearchGroup(group: GlobalSearchGroup): boolean {
  return group.source === null;
}

export function searchGroupKey(group: GlobalSearchGroup): string {
  return group.source ?? LOCAL_SEARCH_GROUP_KEY;
}

/** Total hits across every section — what the result counter reports. */
export function searchResultCount(groups: GlobalSearchGroup[]): number {
  return groups.reduce((count, group) => count + group.items.length, 0);
}

/**
 * The line to show in place of a section's results, or null when it has some.
 *
 * A backend-supplied note on an *empty* group means the source answered with
 * results it judged unrelated to the query — worth saying, because "nothing
 * matched" and "this source returned noise" are different problems.
 */
export function searchGroupNote(group: GlobalSearchGroup): string | null {
  if (group.items.length > 0) {
    return null;
  }
  if (group.status === "error") {
    return group.error ?? "This source did not answer.";
  }
  return group.error ?? "No matches";
}

/**
 * Split the sections into the ones worth showing up front and the quiet ones.
 *
 * With ~50 connectors, rendering every section would bury the hits under a wall
 * of "No matches". Failed sources stay visible regardless: their section is the
 * only place a retry can be offered, and a source that silently vanished when
 * it errored is how "the search is broken" gets misdiagnosed as "no results".
 */
export function splitSearchGroups(groups: GlobalSearchGroup[]): {
  visible: GlobalSearchGroup[];
  quiet: GlobalSearchGroup[];
} {
  const visible: GlobalSearchGroup[] = [];
  const quiet: GlobalSearchGroup[] = [];
  for (const group of groups) {
    if (group.items.length > 0 || group.status === "error") {
      visible.push(group);
    } else {
      quiet.push(group);
    }
  }
  return { visible, quiet };
}

/**
 * One search hit with its `cover_url` resolved by `resolveCoverUrl`.
 *
 * The backend serves search and suggestion covers as the same relative
 * `/sources/{id}/series/{key}/cover` path the browse listing does: it cannot
 * build an absolute one, because the host it sees behind the `/api` rewrite is
 * its own container name. Generic so a `Suggestion` keeps its `why`.
 */
export function withResolvedCover<T extends GlobalSearchItem>(
  item: T,
  resolveCoverUrl: (path: string) => string,
): T {
  return item.cover_url
    ? { ...item, cover_url: resolveCoverUrl(item.cover_url) }
    : item;
}

/**
 * Resolve every cover in a federated search response, once, as it arrives.
 *
 * Done here rather than in the card because the retry path
 * (`searchGroupFromSourceSeries`) already resolves its own rows: a card that
 * resolved again would prefix those twice (`/api/api/sources/...`).
 */
export function resolveSearchCovers(
  response: GlobalSearchResponse,
  resolveCoverUrl: (path: string) => string,
): GlobalSearchResponse {
  const resolve = (item: GlobalSearchItem) =>
    withResolvedCover(item, resolveCoverUrl);
  return {
    ...response,
    items: response.items.map(resolve),
    groups: response.groups.map((group) => ({
      ...group,
      items: group.items.map(resolve),
    })),
  };
}

/**
 * Swap one section into a cached search response, preserving group order.
 *
 * The flat `items` list is deliberately left untouched: it is the legacy view
 * the web does not render, and rebuilding the backend's round-robin interleave
 * here would duplicate server logic to no visible effect.
 */
export function replaceSearchGroup(
  response: GlobalSearchResponse,
  next: GlobalSearchGroup,
): GlobalSearchResponse {
  const key = searchGroupKey(next);
  return {
    ...response,
    groups: response.groups.map((group) =>
      searchGroupKey(group) === key ? next : group,
    ),
  };
}

/**
 * Rebuild a section from that one source's own browse response — the retry
 * path. Retrying goes to `/sources/{id}/series` rather than re-running the
 * federation, which would pay for every source to fix one.
 *
 * `resolveCoverUrl` turns a browse cover path into the same resolved URL
 * `resolveSearchCovers` gives the federated payload, so retried cards render
 * identically to the ones that arrived with the original search.
 */
export function searchGroupFromSourceSeries(
  group: GlobalSearchGroup,
  page: PaginatedSourceSeries,
  resolveCoverUrl: (path: string) => string,
): GlobalSearchGroup {
  const items: GlobalSearchItem[] = page.items.map((series) => ({
    kind: "source",
    source: group.source,
    series_id: String(series.id),
    title: series.title,
    cover_url: series.cover_url ? resolveCoverUrl(series.cover_url) : null,
    author: series.author,
    chapter_count: series.chapter_count,
    extra: null,
  }));
  return {
    ...group,
    status: items.length > 0 ? "ok" : "empty",
    error: null,
    total: items.length,
    has_more: page.has_more,
    items,
  };
}

/** Mark a section as failed, e.g. when its retry request also failed. */
export function searchGroupWithError(
  group: GlobalSearchGroup,
  message: string,
): GlobalSearchGroup {
  return { ...group, status: "error", error: message, items: [], total: 0, has_more: false };
}
