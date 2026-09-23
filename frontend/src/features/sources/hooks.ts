import {
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
  type QueryClient,
} from "@tanstack/react-query";
import { readerDebug } from "@/features/reader/debug";
import { prefetchChapterManifest } from "@/features/reader/hooks";
import { readerChapterHref } from "@/features/reader/reader-link";
import { useActiveProfileStore } from "@/features/profiles/store";
import { ApiError } from "@/types/api";
import { sourceImageUrl, sourcesApi } from "./api";
import {
  replaceSearchGroup,
  searchGroupFromSourceSeries,
  searchGroupWithError,
} from "./global-search";
import type {
  GlobalSearchResponse,
  PaginatedSourceSeries,
  SourceChapterSummary,
  SourcePin,
} from "./types";

/**
 * Cache root for everything served out of `/sources`. Exported because the
 * backend filters the installed-source list and federated search by the
 * profile's 18+ gate — see `preferences/mature-gate.ts`.
 */
export const SOURCES_QUERY_ROOT = "sources" as const;

const SOURCES_KEY = [SOURCES_QUERY_ROOT] as const;
const SOURCE_READER_STALE_MS = 5 * 60_000;
const SEARCH_STALE_MS = 30_000;

export function sourceReaderChapterQueryKey(
  sourceId: string,
  seriesId: string,
  chapterId: string,
) {
  return [...SOURCES_KEY, sourceId, "reader", seriesId, chapterId] as const;
}

/**
 * Warm a chapter for the series page's Read links.
 *
 * Prefetches the READER's own query — `GET /reader/chapter/manifest`, keyed by
 * `readerManifestQueryKey` — not `GET /sources/…/reader`. The source-native
 * rewrite moved the reader onto the manifest; this kept filling
 * `["sources", …, "reader", …]`, which no component has read since. Every
 * prefetch was therefore a live chapter scrape that made nothing faster, and it
 * spent the shared `/sources/*` rate-limit bucket (60/minute) that the series
 * page's own detail, chapter-list and cover requests come out of.
 */
export function prefetchSourceReaderChapter(
  queryClient: QueryClient,
  sourceId: string,
  seriesId: string,
  chapterId: string,
) {
  if (!sourceId || !seriesId || !chapterId) return;
  readerDebug("api-prefetch-started", {
    sourceId,
    seriesId,
    chapterId,
    scope: "source",
  });
  prefetchChapterManifest(queryClient, {
    sourceId,
    seriesKey: seriesId,
    chapterKey: chapterId,
  });
}

export function sourceReaderChapterPath(
  sourceId: string,
  seriesId: string,
  chapterId: string,
): string {
  return readerChapterHref({
    sourceId,
    seriesKey: seriesId,
    chapterKey: chapterId,
  });
}

/**
 * Every source this profile can see.
 *
 * `enabled` exists for callers that only need the listing conditionally — the
 * content-mode filter reads it solely to learn each source's `content_kind`,
 * and a deployment with novels off has no use for it at all. The query key is
 * unchanged, so a disabled caller still shares (and is served by) the cache
 * that the Sources screen fills.
 */
export function useSources(options?: { enabled?: boolean }) {
  return useQuery({
    queryKey: [...SOURCES_KEY, "installed"],
    queryFn: () => sourcesApi.listSources(),
    enabled: options?.enabled ?? true,
  });
}

export interface FederatedSearchParams {
  q: string;
  page?: number;
  per_page?: number;
}

export function federatedSearchQueryKey(
  params: FederatedSearchParams,
  tier?: 1 | 2,
) {
  return [...SOURCES_KEY, "search", params, tier ?? null] as const;
}

/**
 * Fold tier 2 into tier 1.
 *
 * Both tiers emit the local-library group, because `groups[0] is the local
 * library` is a contract the clients rely on — so the merge dedupes by source
 * and keeps the first occurrence. The counts SUM: a footer that reported tier
 * 1's four sources as the whole search would be worse than the ten-second wait
 * this replaces.
 */
export function mergeSearchTiers(
  first: GlobalSearchResponse,
  second: GlobalSearchResponse | undefined,
): GlobalSearchResponse {
  if (!second) return first;
  // string | null: the LOCAL group carries a null source, and it is emitted on
  // both tiers, so it is precisely the entry this dedupe exists to catch.
  const seen = new Set<string | null>();
  const groups = [...first.groups, ...second.groups].filter((group) => {
    if (seen.has(group.source)) return false;
    seen.add(group.source);
    return true;
  });
  return {
    ...first,
    groups,
    items: [...first.items, ...second.items],
    sources_queried: first.sources_queried + second.sources_queried,
    sources_failed: first.sources_failed + second.sources_failed,
    sources_deferred: second.sources_deferred ?? 0,
    next_tier: second.next_tier ?? null,
    has_more: first.has_more || second.has_more,
  };
}

/**
 * Federated search across the local library and every enabled remote source.
 * Mirrors the local-library `useSearch`: only runs for a non-empty query, keeps
 * previous results while a new query loads (no flicker), and reuses the same
 * short staleTime as the global default so repeated searches stay cached.
 */
export function useFederatedSearch(params: FederatedSearchParams) {
  // Two requests, not one. The fan-out asks every installed source at once
  // under a 12s budget measured at 10.8s, and nearly every hit the reader
  // wants comes from the few sources they pin or follow — which answer in
  // under two seconds. Tier 1 is those; tier 2 is everything else and arrives
  // behind it, so the screen fills immediately instead of after ten seconds.
  const first = useQuery({
    queryKey: federatedSearchQueryKey(params, 1),
    queryFn: () => sourcesApi.federatedSearch({ ...params, tier: 1 }),
    enabled: params.q.length > 0,
    placeholderData: (previous) => previous,
    staleTime: SEARCH_STALE_MS,
  });

  // Only once tier 1 has said there IS more. A server that does not know the
  // parameter returns the whole search with next_tier undefined, and this
  // second request never fires — which is what keeps an older backend working.
  const rest = useQuery(federatedSearchRestOptions(params, first.data));

  return {
    ...first,
    ...resolveSearchTiers(first.data, rest),
  };
}

/**
 * Tier 2's query options, pulled out so the absence of `placeholderData` can be
 * pinned by a test against a real QueryClient.
 *
 * No `placeholderData` here, unlike tier 1. Tier 2's key changes with every
 * new term, and TanStack serves a placeholder from the observer's last data
 * whatever its key or `enabled` — so the previous term's results from ~87
 * sources were folded into the new term's tier 1 the moment it settled, and
 * shown as the finished answer ("N results found") for the eight seconds until
 * the new tier 2 landed. When the new term had no tier 2 at all, they stayed
 * until the next search. A refetch of the SAME term keeps its own cached data,
 * so dropping the placeholder costs no flicker there.
 */
export function federatedSearchRestOptions(
  params: FederatedSearchParams,
  first: GlobalSearchResponse | undefined,
) {
  return {
    queryKey: federatedSearchQueryKey(params, 2),
    queryFn: () => sourcesApi.federatedSearch({ ...params, tier: 2 }),
    enabled: params.q.length > 0 && first?.next_tier === 2,
    staleTime: SEARCH_STALE_MS,
  };
}

/**
 * Fold what the two tier queries currently hold into what the screen shows.
 *
 * Tier 2 data that is only a placeholder is never merged: it belongs to some
 * other query, and since the tiers ask disjoint sources the source-keyed
 * dedupe in `mergeSearchTiers` cannot catch it. A placeholder also counts as
 * still loading: it reports status 'success', so `isPending` alone read "done"
 * while the real answer was still seconds out.
 *
 * A tier 2 that FAILED, with nothing of its own to show, counts every source
 * it was meant to ask as searched and failed. Otherwise the ~87 deferred
 * sources dropped out without a word: not loading, no groups, and a scope
 * line reading "Searched 4 sources" — which a reader takes to mean nothing
 * else carries the title.
 */
export function resolveSearchTiers(
  first: GlobalSearchResponse | undefined,
  rest: {
    data: GlobalSearchResponse | undefined;
    isPending: boolean;
    isPlaceholderData: boolean;
    isError?: boolean;
  },
): { data: GlobalSearchResponse | undefined; isLoadingRest: boolean } {
  const second = rest.isPlaceholderData ? undefined : rest.data;
  const restFailed =
    first?.next_tier === 2 && rest.isError === true && second === undefined;
  const merged = first ? mergeSearchTiers(first, second) : undefined;
  const missing = restFailed ? (merged?.sources_deferred ?? 0) : 0;
  return {
    data:
      merged && missing > 0
        ? {
            ...merged,
            sources_queried: merged.sources_queried + missing,
            sources_failed: merged.sources_failed + missing,
          }
        : merged,
    // True while the rest is still arriving, so a caller can say "searching
    // 87 more sources" rather than pretending the answer is complete.
    isLoadingRest:
      first?.next_tier === 2 && (rest.isPending || rest.isPlaceholderData),
  };
}

/**
 * Re-query one source whose search section failed, patching that section into
 * the cached federated response.
 *
 * Goes to the source's own browse endpoint instead of re-running
 * `/sources/search`: a second federated call pays for every installed source to
 * fix one, and would also replace the sections the user is already reading.
 * `mutation.variables` names the source currently retrying, so only that
 * section shows a spinner.
 */
export function useRetrySearchSource(params: FederatedSearchParams) {
  const queryClient = useQueryClient();
  // Both tiers, because the group being retried may sit in either and the
  // patch below no-ops when it is not there.
  const keys = [
    federatedSearchQueryKey(params, 1),
    federatedSearchQueryKey(params, 2),
  ];

  const patch = (
    sourceId: string,
    rebuild: (
      previous: GlobalSearchResponse,
      group: GlobalSearchResponse["groups"][number],
    ) => GlobalSearchResponse,
  ) => {
    for (const key of keys) {
      queryClient.setQueryData<GlobalSearchResponse>(key, (previous) => {
        if (!previous) return previous;
        const group = previous.groups.find((entry) => entry.source === sourceId);
        // A newer query already replaced these results, or this tier never held
        // the source; either way the retry answer does not belong here.
        if (!group) return previous;
        return rebuild(previous, group);
      });
    }
  };

  return useMutation({
    mutationFn: (sourceId: string) =>
      sourcesApi.listSeries(sourceId, { query: params.q }),
    onSuccess: (page, sourceId) => {
      patch(sourceId, (previous, group) =>
        replaceSearchGroup(
          previous,
          searchGroupFromSourceSeries(group, page, sourceImageUrl),
        ),
      );
    },
    onError: (error, sourceId) => {
      const message =
        error instanceof ApiError ? error.message : "This source did not answer.";
      patch(sourceId, (previous, group) =>
        replaceSearchGroup(previous, searchGroupWithError(group, message)),
      );
    },
  });
}

export function sourcePinsQueryKey(profileId: number | null) {
  return [...SOURCES_KEY, "pins", profileId] as const;
}

/**
 * The active profile's pinned sources.
 *
 * The profile id is part of the cache key on purpose: pins are stored per
 * `(user_id, profile_id)`, so a switch must never render the previous profile's
 * shortcuts out of cache. The `ProfileCacheBoundary` already drops
 * profile-scoped queries on a switch; keying makes a stale hit structurally
 * impossible rather than dependent on that boundary firing.
 *
 * Disabled without an active profile: the write path requires `X-Profile-Id`,
 * and a profile-less read answers for the account's unscoped bucket, which is a
 * different set that must not be shown as "your pins".
 */
export function useSourcePins() {
  const profileId = useActiveProfileStore((state) => state.activeProfile?.id ?? null);
  return useQuery({
    queryKey: sourcePinsQueryKey(profileId),
    queryFn: () => sourcesApi.listPins(),
    enabled: profileId !== null,
  });
}

/**
 * Replace the pinned set, optimistically. Callers pass the complete next list
 * (see `pins.ts`), which is also the shape the endpoint takes.
 */
export function useReplaceSourcePins() {
  const queryClient = useQueryClient();
  const profileId = useActiveProfileStore((state) => state.activeProfile?.id ?? null);
  const key = sourcePinsQueryKey(profileId);
  return useMutation({
    mutationFn: (next: SourcePin[]) =>
      sourcesApi.replacePins(next.map((pin) => pin.source_id)),
    onMutate: async (next) => {
      await queryClient.cancelQueries({ queryKey: key });
      const previous = queryClient.getQueryData<SourcePin[]>(key);
      queryClient.setQueryData<SourcePin[]>(key, next);
      return { previous };
    },
    onError: (_error, _next, context) => {
      queryClient.setQueryData<SourcePin[] | undefined>(key, context?.previous);
    },
    onSuccess: (server) => {
      // The server resolves each pin's display name, icon and 18+ flag, so its
      // answer supersedes the optimistic rows rather than merely confirming them.
      queryClient.setQueryData<SourcePin[]>(key, server);
    },
  });
}

export function useSourceBrowseModes(sourceId: string) {
  return useQuery({
    queryKey: [...SOURCES_KEY, sourceId, "browse-modes"],
    queryFn: () => sourcesApi.browseModes(sourceId),
    enabled: Boolean(sourceId),
  });
}

export function useSourceGenres(sourceId: string) {
  return useQuery({
    queryKey: [...SOURCES_KEY, sourceId, "genres"],
    queryFn: () => sourcesApi.genres(sourceId),
    enabled: Boolean(sourceId),
  });
}

export function useSourceSeries(
  sourceId: string,
  params: { page?: number; query?: string; sort?: string; genre?: string },
) {
  return useQuery({
    queryKey: [...SOURCES_KEY, sourceId, "series", params],
    queryFn: () => sourcesApi.listSeries(sourceId, params),
    enabled: Boolean(sourceId),
    placeholderData: (previous) => previous,
  });
}

export interface SourceBrowseFacets {
  /** Empty string for a plain browse; anything else is a search. */
  query: string;
  sort?: string;
  genre?: string;
}

/** The facet values as they reach the API — and as they key the cache. */
export function normalizeBrowseFacets(facets: SourceBrowseFacets) {
  return {
    query: facets.query.trim() || undefined,
    sort: facets.sort && facets.sort !== "default" ? facets.sort : undefined,
    genre: facets.genre?.trim() || undefined,
  };
}

export function sourceSeriesInfiniteQueryKey(
  sourceId: string,
  facets: SourceBrowseFacets,
) {
  const normalized = normalizeBrowseFacets(facets);
  return [
    ...SOURCES_KEY,
    sourceId,
    "series",
    "infinite",
    normalized.query ?? "",
    normalized.sort ?? "",
    normalized.genre ?? "",
  ] as const;
}

export function useInfiniteSourceSeries(
  sourceId: string,
  query: string,
  sort?: string,
  genre?: string,
) {
  const normalized = normalizeBrowseFacets({ query, sort, genre });
  return useInfiniteQuery({
    queryKey: sourceSeriesInfiniteQueryKey(sourceId, { query, sort, genre }),
    queryFn: ({ pageParam }) =>
      sourcesApi.listSeries(sourceId, {
        page: pageParam,
        query: normalized.query,
        sort: normalized.sort,
        genre: normalized.genre,
      }),
    initialPageParam: 1,
    getNextPageParam: (lastPage) => (lastPage.has_more ? lastPage.page + 1 : undefined),
    enabled: Boolean(sourceId),
  });
}

/**
 * Replace a browse listing with a freshly refetched first page.
 *
 * Deliberately collapses to ONE page rather than merging: `refresh=true`
 * bypasses the server's browse cache, so re-running it for every page the
 * reader had scrolled through would be N live connector requests to answer one
 * click — and the pages after the first would no longer be guaranteed to line
 * up with a catalog that has just changed underneath them. Dropping back to
 * page 1 is both cheaper and the honest answer to "show me what this source has
 * right now"; `fetchNextPage` re-pages from there as normal.
 */
export function applyRefreshedBrowsePage(
  queryClient: QueryClient,
  key: readonly unknown[],
  page: PaginatedSourceSeries,
): void {
  queryClient.setQueryData(key, { pages: [page], pageParams: [1] });
}

/**
 * Force a source to re-fetch its catalog, bypassing the server's browse cache.
 *
 * A plain `refetch()` would replay the cached request and could legitimately
 * answer from the same cache row the reader is trying to get past, so the
 * refresh goes through the endpoint's own `refresh` flag. Modelled as a
 * mutation (like `useRetrySearchSource`) so the button gets `isPending` without
 * a second piece of state.
 */
export function useRefreshSourceBrowse(
  sourceId: string,
  facets: SourceBrowseFacets,
) {
  const queryClient = useQueryClient();
  const normalized = normalizeBrowseFacets(facets);
  const key = sourceSeriesInfiniteQueryKey(sourceId, facets);

  return useMutation({
    mutationFn: () =>
      sourcesApi.listSeries(sourceId, {
        page: 1,
        query: normalized.query,
        sort: normalized.sort,
        genre: normalized.genre,
        refresh: true,
      }),
    onSuccess: (page) => applyRefreshedBrowsePage(queryClient, key, page),
  });
}

export function useSourceSeriesDetail(sourceId: string, seriesId: string) {
  return useQuery({
    queryKey: [...SOURCES_KEY, sourceId, "series", seriesId],
    queryFn: () => sourcesApi.getSeries(sourceId, seriesId),
    enabled: Boolean(sourceId) && Boolean(seriesId),
  });
}

export function sourceChaptersQueryKey(sourceId: string, seriesId: string) {
  return [...SOURCES_KEY, sourceId, "series", seriesId, "chapters"] as const;
}

export function useSourceChapters(sourceId: string, seriesId: string) {
  return useQuery({
    queryKey: sourceChaptersQueryKey(sourceId, seriesId),
    queryFn: () => sourcesApi.getChapters(sourceId, seriesId),
    enabled: Boolean(sourceId) && Boolean(seriesId),
    // Chapter lists must reflect upstream changes quickly; a stale empty
    // response (e.g. after a transient scrape miss) otherwise sticks for 30s.
    staleTime: 0,
  });
}

/**
 * Connectors only learn a chapter's page_count after its pages have been
 * fetched at least once (the series-chapters HTML has no per-chapter counts
 * up front). The chapters list query has no way to know that fetching a
 * reader chapter just changed its own data server-side, so it kept serving
 * its cached (page_count: 0) response until it happened to go stale on its
 * own, up to 30s (the global default staleTime) later.
 *
 * Call this once the reader chapter succeeds. It patches the cached chapter
 * entry in place via `setQueryData` -- an instant, local update with no
 * extra network request -- so the series page reflects the real count the
 * moment the reader chapter finishes loading. Only when there is no usable
 * cached list to patch (not yet fetched, or the chapter isn't in it) does it
 * fall back to invalidating that one series' chapters query, and only that
 * one: no other cached query is touched.
 */
export function applyReaderPageCountToSourceChapters(
  queryClient: QueryClient,
  sourceId: string,
  seriesId: string,
  chapterId: string,
  pageCount: number,
): void {
  const key = sourceChaptersQueryKey(sourceId, seriesId);
  let patched = false;

  queryClient.setQueryData<SourceChapterSummary[]>(key, (previous) => {
    if (!previous) return previous;
    let changed = false;
    const next = previous.map((chapter) => {
      if (chapter.id === chapterId && chapter.page_count !== pageCount) {
        changed = true;
        return { ...chapter, page_count: pageCount };
      }
      return chapter;
    });
    if (!changed) return previous;
    patched = true;
    return next;
  });

  if (!patched) {
    void queryClient.invalidateQueries({ queryKey: key });
  }
}

export function useSourceReaderChapter(
  sourceId: string,
  seriesId: string,
  chapterId: string,
) {
  const queryClient = useQueryClient();
  return useQuery({
    queryKey: sourceReaderChapterQueryKey(sourceId, seriesId, chapterId),
    queryFn: async () => {
      readerDebug("api-request-started", {
        sourceId,
        seriesId,
        chapterId,
        scope: "source",
      });
      const payload = await sourcesApi.getReaderChapter(sourceId, seriesId, chapterId);
      readerDebug("api-response-received", {
        sourceId,
        seriesId,
        chapterId,
        scope: "source",
        pageCount: payload.page_count,
      });
      applyReaderPageCountToSourceChapters(
        queryClient,
        sourceId,
        seriesId,
        chapterId,
        payload.page_count,
      );
      return payload;
    },
    enabled: Boolean(sourceId) && Boolean(seriesId) && Boolean(chapterId),
    staleTime: SOURCE_READER_STALE_MS,
  });
}
