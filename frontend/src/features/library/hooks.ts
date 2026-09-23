// Holds React state (`useState`/`useRef`) via `useBulkSeriesAction`, so the
// whole module is client-only. The `@/features/library` barrel re-exports it
// into Server Components, which Turbopack refuses without this directive.
"use client";

import {
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { useCallback, useRef, useState } from "react";
import type { SeriesId } from "@/types/api";
import { libraryApi } from "./api";
import {
  type BulkOutcome,
  type BulkProgress,
  runBulk,
  summarizeBulkOutcome,
} from "./bulk";
import {
  buildFollowedIndex,
  fetchAllFollowed,
  FOLLOWED_PAGE_SIZE,
  type FollowedIndex,
  followedIdFor,
} from "./followed-index";
import {
  clientTimezoneOffsetMinutes,
  DEFAULT_STATISTICS_RANGE,
} from "./reading-stats";
import type { SeriesListParams } from "./url-state";
import type { FollowedSeries } from "./types";

/**
 * Cache roots for the two library namespaces. Exported because the backend
 * filters everything under both by the profile's 18+ gate, so flipping that
 * gate has to invalidate them — see `preferences/mature-gate.ts`.
 */
export const LIBRARY_QUERY_ROOT = "library" as const;
export const LIBRARY_DISCOVERY_QUERY_ROOT = "library-discovery" as const;

const LIBRARY_KEY = [LIBRARY_QUERY_ROOT] as const;
const DISCOVERY_KEY = [LIBRARY_DISCOVERY_QUERY_ROOT] as const;

// --- Followed series ---

export function useSeriesList(params: SeriesListParams) {
  return useQuery({
    queryKey: [...LIBRARY_KEY, "series", params],
    queryFn: () => libraryApi.listSeries(params),
  });
}

export function seriesQueryKey(followedId: number | null) {
  return [...LIBRARY_KEY, "series-detail", followedId] as const;
}

export function useSeries(followedId: number | null) {
  return useQuery({
    queryKey: seriesQueryKey(followedId),
    queryFn: () => libraryApi.getSeries(followedId!),
    enabled: followedId !== null,
  });
}

export function useContinueReading(limit = 10) {
  return useQuery({
    queryKey: [...LIBRARY_KEY, "continue-reading", limit],
    queryFn: () => libraryApi.continueReading(limit),
  });
}

// --- Search over the followed set ---

export function useSearch(params: { q: string; page?: number; per_page?: number }) {
  return useQuery({
    queryKey: [...DISCOVERY_KEY, "search", params],
    queryFn: () => libraryApi.search(params),
    enabled: params.q.length > 0,
  });
}

// --- Follow / unfollow ---

/**
 * Every followed row, by title — all pages of it, not the first 200 (see
 * `followed-index.ts`). The follow index and a collection's screens share
 * this one cache entry.
 */
export function useAllFollowedSeries() {
  return useQuery({
    queryKey: [...LIBRARY_KEY, "followed-index"],
    queryFn: () =>
      fetchAllFollowed((page) =>
        libraryApi.listSeries({ page, per_page: FOLLOWED_PAGE_SIZE, sort: "title" }),
      ),
  });
}

const NO_FOLLOWED: readonly FollowedSeries[] = [];
const followedIndexes = new WeakMap<readonly FollowedSeries[], FollowedIndex>();

/**
 * The index over one fetched followed list, built once and shared by every
 * caller holding that same list. It used to be built per consumer — three Maps
 * over up to 1000 rows, once for each of up to 200 grid cards, at load and
 * again after every library invalidation. Keyed weakly, so a replaced list
 * takes its index with it.
 */
export function followedIndexFor(
  rows: readonly FollowedSeries[] | undefined,
): FollowedIndex {
  const list = rows ?? NO_FOLLOWED;
  let built = followedIndexes.get(list);
  if (!built) {
    built = buildFollowedIndex(list);
    followedIndexes.set(list, built);
  }
  return built;
}

/**
 * Map of `"sourceId:seriesKey" -> followed_id` over the whole followed set, so
 * a `FollowButton` anywhere can tell whether its series is followed and get the
 * id it needs to unfollow. Shared cache. A series page asks through `lookup`
 * with its payload's `series_identity`, which also finds a follow made under
 * an older key of the same series.
 *
 * Returns named fields rather than spreading the query result. React Query
 * re-renders a consumer only for the result fields it reads, and a spread reads
 * every one of them — so each consumer also re-rendered when a fetch started,
 * when it ended and when the data went stale, none of which it shows.
 */
export function useFollowedIndex() {
  const { data, isLoading, isSuccess, isError } = useAllFollowedSeries();
  const followed = followedIndexFor(data);
  const lookup = useCallback(
    (ref: SeriesId, seriesIdentity?: string | null) =>
      followedIdFor(followed, ref, seriesIdentity),
    [followed],
  );
  return { data, isLoading, isSuccess, isError, ...followed, lookup };
}

export function followKey(ref: SeriesId): string {
  return `${ref.sourceId}:${ref.seriesKey}`;
}

export function useFollow() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (ref: SeriesId) => libraryApi.follow(ref),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: LIBRARY_KEY });
    },
  });
}

export function useUnfollow() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (followedId: number) => libraryApi.unfollow(followedId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: LIBRARY_KEY });
    },
  });
}

// --- Follow-row patches ---

export interface SeriesPatch {
  is_favorite?: boolean;
  reading_status?: string;
  notify?: boolean;
  mature_override?: boolean;
  sort_order?: number;
}

export function usePatchSeries() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ followedId, body }: { followedId: number; body: SeriesPatch }) =>
      libraryApi.patchSeries(followedId, body),
    onSuccess: (data: FollowedSeries) => {
      void queryClient.invalidateQueries({ queryKey: LIBRARY_KEY });
      queryClient.setQueryData(seriesQueryKey(data.id), (prev: unknown) =>
        prev && typeof prev === "object" ? { ...prev, ...data } : prev,
      );
    },
  });
}

export function useToggleFavorite() {
  const patch = usePatchSeries();
  return {
    ...patch,
    mutate: ({ followedId, isFavorite }: { followedId: number; isFavorite: boolean }) =>
      patch.mutate({ followedId, body: { is_favorite: isFavorite } }),
  };
}

// --- Discovery ---

export function useRecommendations(limit = 10) {
  return useQuery({
    queryKey: [...DISCOVERY_KEY, "recommendations", limit],
    queryFn: () => libraryApi.recommendations(limit),
  });
}

/**
 * Whether the AI suggestion box should be shown at all.
 *
 * Free on the server — a config flag and a counter, no network, no spend — so
 * it is safe as a query, unlike the suggestion itself.
 */
export function useSuggestAvailability() {
  return useQuery({
    queryKey: [...DISCOVERY_KEY, "suggest-availability"],
    queryFn: () => libraryApi.suggestAvailability(),
    staleTime: 5 * 60_000,
  });
}

/**
 * Ask for suggestions. A MUTATION, deliberately, not a query: one call is one
 * paid API request, and a query would re-fire on remount, refocus and retry.
 * Nothing here runs until somebody presses the button.
 */
export function useSuggest() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { prompt: string; limit?: number }) => libraryApi.suggest(body),
    onSuccess: () => {
      // The day's allowance just moved, and the box shows what is left.
      void queryClient.invalidateQueries({
        queryKey: [...DISCOVERY_KEY, "suggest-availability"],
      });
    },
  });
}

export function useReadingHistory(limit = 50) {
  return useQuery({
    queryKey: [...DISCOVERY_KEY, "reading-history", limit],
    queryFn: () => libraryApi.readingHistory(limit),
  });
}

/**
 * Reading statistics for one window.
 *
 * The viewer's UTC offset is part of the request (the backend buckets days at
 * it) and therefore part of the cache key — a profile that crosses a timezone
 * must not be served yesterday's buckets. It is read once per render rather
 * than stored, so a laptop opened in another country is right on the next
 * fetch without anything to invalidate.
 */
export function useStatistics(days: number = DEFAULT_STATISTICS_RANGE) {
  const tzOffsetMinutes = clientTimezoneOffsetMinutes();
  return useQuery({
    queryKey: [...DISCOVERY_KEY, "statistics", days, tzOffsetMinutes],
    queryFn: () =>
      libraryApi.statistics({ days, tz_offset_minutes: tzOffsetMinutes }),
  });
}

// --- Collections ---

export function useCollections() {
  return useQuery({
    queryKey: [...DISCOVERY_KEY, "collections"],
    queryFn: () => libraryApi.listCollections(),
  });
}

export function useCollection(collectionId: number | null) {
  return useQuery({
    queryKey: [...DISCOVERY_KEY, "collections", collectionId],
    queryFn: () => libraryApi.getCollection(collectionId!),
    enabled: collectionId !== null,
  });
}

export function useCreateCollection() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { name: string; description?: string }) =>
      libraryApi.createCollection(body),
    onSuccess: () => {
      void queryClient.invalidateQueries({
        queryKey: [...DISCOVERY_KEY, "collections"],
      });
    },
  });
}

export function useUpdateCollection() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      collectionId,
      body,
    }: {
      collectionId: number;
      body: { name?: string; description?: string; sort_order?: number };
    }) => libraryApi.updateCollection(collectionId, body),
    onSuccess: () => {
      void queryClient.invalidateQueries({
        queryKey: [...DISCOVERY_KEY, "collections"],
      });
    },
  });
}

export function useDeleteCollection() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (collectionId: number) => libraryApi.deleteCollection(collectionId),
    onSuccess: () => {
      void queryClient.invalidateQueries({
        queryKey: [...DISCOVERY_KEY, "collections"],
      });
    },
  });
}

export function useAddSeriesToCollection() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ collectionId, ref }: { collectionId: number; ref: SeriesId }) =>
      libraryApi.addSeriesToCollection(collectionId, ref),
    onSuccess: (_, variables) => {
      void queryClient.invalidateQueries({
        queryKey: [...DISCOVERY_KEY, "collections", variables.collectionId],
      });
      void queryClient.invalidateQueries({
        queryKey: [...DISCOVERY_KEY, "collections"],
      });
    },
  });
}

export function useRemoveSeriesFromCollection() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ collectionId, ref }: { collectionId: number; ref: SeriesId }) =>
      libraryApi.removeSeriesFromCollection(collectionId, ref),
    onSuccess: (_, variables) => {
      void queryClient.invalidateQueries({
        queryKey: [...DISCOVERY_KEY, "collections", variables.collectionId],
      });
      void queryClient.invalidateQueries({
        queryKey: [...DISCOVERY_KEY, "collections"],
      });
    },
  });
}

// --- Bulk actions over the followed grid ---

/**
 * What a bulk action does to one followed series. Membership means unfollow —
 * bulk re-follow is not offered (it needs the `(source, series_key)` pair per
 * row, which the grid has, but the undo path is a later slice).
 */
export type BulkAction =
  | { kind: "favorite"; value: boolean }
  | { kind: "reading_status"; value: string }
  | { kind: "unfollow" };

function bulkActionVerb(action: BulkAction): string {
  switch (action.kind) {
    case "favorite":
      return action.value ? "favourited" : "unfavourited";
    case "reading_status":
      return action.value === "completed" ? "marked read" : `marked ${action.value}`;
    case "unfollow":
      return "unfollowed";
  }
}

function bulkActionRequest(
  action: BulkAction,
  series: FollowedSeries,
): Promise<unknown> {
  switch (action.kind) {
    case "favorite":
      return libraryApi.patchSeries(series.id, { is_favorite: action.value });
    case "reading_status":
      return libraryApi.patchSeries(series.id, { reading_status: action.value });
    case "unfollow":
      return libraryApi.unfollow(series.id);
  }
}

export interface BulkActionState {
  run: (
    action: BulkAction,
    series: readonly FollowedSeries[],
  ) => Promise<BulkOutcome<FollowedSeries>>;
  cancel: () => void;
  progress: BulkProgress | null;
  isRunning: boolean;
  message: string | null;
  dismissMessage: () => void;
}

export function useBulkSeriesAction(): BulkActionState {
  const queryClient = useQueryClient();
  const [progress, setProgress] = useState<BulkProgress | null>(null);
  const [isRunning, setIsRunning] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const cancel = useCallback(() => abortRef.current?.abort(), []);
  const dismissMessage = useCallback(() => setMessage(null), []);

  const run = useCallback(
    async (action: BulkAction, series: readonly FollowedSeries[]) => {
      const controller = new AbortController();
      abortRef.current = controller;
      setIsRunning(true);
      setMessage(null);
      setProgress({ completed: 0, failed: 0, total: series.length });

      try {
        const outcome = await runBulk(
          series,
          (row) => bulkActionRequest(action, row),
          { onProgress: setProgress, signal: controller.signal },
        );
        await queryClient.invalidateQueries({ queryKey: LIBRARY_KEY });
        setMessage(summarizeBulkOutcome(outcome, bulkActionVerb(action)));
        return outcome;
      } finally {
        abortRef.current = null;
        setIsRunning(false);
        setProgress(null);
      }
    },
    [queryClient],
  );

  return { run, cancel, progress, isRunning, message, dismissMessage };
}
