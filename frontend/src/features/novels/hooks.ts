"use client";

import { useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query";
import { useEffect, useMemo, useReducer } from "react";
import { useBootstrapStatus } from "@/features/auth/hooks";
import { useSources } from "@/features/sources/hooks";
import type { SourceSummary } from "@/features/sources/types";
import type { ChapterId, SeriesId } from "@/types/api";
import { novelsApi, toNovelChapter } from "./api";
import { boundedWindow, collectChapterWindow } from "./chapter-window";
import {
  isNovelsEnabled,
  resolveNovelSource,
  resolveNovelsEnabled,
} from "./gate";
import type { NovelChapterPayload } from "./types";

const NOVELS_KEY = ["novels"] as const;
/** Chapter text is immutable in practice; the server caches it for days. */
const NOVEL_CHAPTER_STALE_MS = 30 * 60_000;

export function novelChapterQueryKey(ref: ChapterId) {
  return [
    ...NOVELS_KEY,
    "chapter",
    ref.sourceId,
    ref.seriesKey,
    ref.chapterKey,
  ] as const;
}

export function useNovelChapter(ref: ChapterId | null) {
  return useQuery({
    queryKey: ref ? novelChapterQueryKey(ref) : [...NOVELS_KEY, "chapter", "none"],
    queryFn: () => novelsApi.chapter(ref!),
    enabled: ref !== null,
    staleTime: NOVEL_CHAPTER_STALE_MS,
  });
}

/**
 * Who speaks each line, when the server already knows.
 *
 * Deliberately a SEPARATE query from the chapter text rather than part of its
 * payload. Attribution exists for a fraction of the library and is decoration:
 * folding it into the chapter response would make every reader wait on a join
 * that usually returns nothing, and would invalidate cached chapter text every
 * time a cast correction landed.
 *
 * Long stale time because an attribution only changes when somebody
 * deliberately re-attributes; nothing a reader does moves it.
 */
export function novelAttributionQueryKey(ref: ChapterId) {
  return [
    ...NOVELS_KEY,
    "attribution",
    ref.sourceId,
    ref.seriesKey,
    ref.chapterKey,
  ] as const;
}

export function useNovelAttribution(ref: ChapterId | null) {
  return useQuery({
    queryKey: ref
      ? novelAttributionQueryKey(ref)
      : [...NOVELS_KEY, "attribution", "none"],
    queryFn: () => novelsApi.attribution(ref!),
    enabled: ref !== null,
    staleTime: NOVEL_CHAPTER_STALE_MS,
    // Tinting is decoration. A failure here must never surface as a broken
    // chapter, so it resolves to "no tinting" and the prose renders as it
    // always did.
    retry: false,
  });
}

export function prefetchNovelChapter(queryClient: QueryClient, ref: ChapterId) {
  void queryClient.prefetchQuery({
    queryKey: novelChapterQueryKey(ref),
    queryFn: () => novelsApi.chapter(ref),
    staleTime: NOVEL_CHAPTER_STALE_MS,
  });
}

/**
 * Warm several of one book's chapters through the bulk window.
 *
 * The same result as calling {@link prefetchNovelChapter} once per key — the
 * chapters land in the same per-chapter cache entries, so anything already
 * reading them sees no difference — bought with one request instead of N.
 *
 * That matters less for latency than it sounds: against a warm server cache a
 * window costs about what the same chapters cost individually. It matters for
 * the RATE LIMITER. `GET /novels/chapter` is on the `sources` bucket and each
 * miss is a live scrape, so firing a handful at once is the naive pipelining
 * that trips it and leaves the reader with a 429 on the chapter they actually
 * opened; the window spends the `bulk` bucket once. On a cold cache it is also
 * genuinely faster, because the misses fan out server-side.
 *
 * Best-effort, and silent when it fails. A warm nobody asked for must not
 * raise an error at a reader — every chapter it did not deliver is still
 * fetched on demand by `useNovelChapter`, with the real error handling.
 */
export async function prefetchNovelChapterWindow(
  queryClient: QueryClient,
  ref: SeriesId,
  chapterKeys: readonly string[],
): Promise<void> {
  // Only ask for what is not in hand. Chapter text is immutable in practice,
  // so a cached copy of any age is a copy worth keeping.
  const missing = boundedWindow(chapterKeys).filter(
    (chapterKey) =>
      queryClient.getQueryData(novelChapterQueryKey({ ...ref, chapterKey })) ===
      undefined,
  );
  if (missing.length === 0) return;

  try {
    const payload = await novelsApi.chapterWindow(ref, missing);
    const { chapters } = collectChapterWindow(missing, payload);
    for (const [chapterKey, chapter] of chapters) {
      queryClient.setQueryData(novelChapterQueryKey({ ...ref, chapterKey }), chapter);
    }
  } catch {
    // The gate, the cap or the rate limit refused the whole window. Nothing to
    // recover: these chapters were speculative.
  }
}

/**
 * Whether novel UI may be mounted right now (`/auth/bootstrap-status`).
 *
 * Two-state on purpose: an unanswered probe reads as off, which is the safe
 * answer for MOUNTING — a surface that appears a frame late is recoverable, a
 * novel tab flashed onto a manga-only deployment is not. "Which reader does
 * this chapter open in" is a different question and needs the honest third
 * state; that one goes through `useNovelSourceKinds`.
 */
export function useNovelsEnabled(): boolean {
  const { data: status } = useBootstrapStatus();
  return isNovelsEnabled(status);
}

/**
 * The two facts every "which reader?" decision is made from, each honest about
 * not knowing yet: whether this deployment serves novels, and the listing that
 * says which of its sources are prose.
 *
 * The listing is fetched only once novels are known to be ON — not merely to
 * save a request, but because that is what lets a manga-only deployment answer
 * immediately: `/sources` is never requested from here, so nothing here can
 * ever be waiting on it.
 */
export function useNovelSourceKinds(): {
  novelsEnabled: boolean | undefined;
  sources: SourceSummary[] | undefined;
} {
  const { data: status, isPending } = useBootstrapStatus();
  const novelsEnabled = resolveNovelsEnabled(status, isPending);
  const { data: sources } = useSources({ enabled: novelsEnabled === true });
  return { novelsEnabled, sources };
}

/**
 * Whether a given source serves prose.
 *
 * `undefined` means the answer does not exist yet — the bootstrap probe or the
 * sources listing is still in flight — so a caller can hold a "which reader?"
 * decision for a frame instead of guessing and then swapping the whole screen
 * under the reader. `false` is a real answer: this source serves pages, or this
 * deployment has novels off and none of them do.
 */
export function useIsNovelSource(sourceId: string): boolean | undefined {
  const { novelsEnabled, sources } = useNovelSourceKinds();
  return resolveNovelSource(novelsEnabled, sources, sourceId);
}

/**
 * Word counts for a series' chapters, read out of whatever is already cached.
 *
 * A novel chapter list has no length to show: the connector reports
 * `page_count: 0` (a novel chapter is not made of pages) and there is no bulk
 * word-count endpoint. What there IS is the chapter-text cache — every chapter
 * the reader has opened, plus the handful the series page prefetches and
 * anything hovered — so the list reads its lengths from there and simply says
 * nothing for chapters it has not seen. An honest gap beats a fabricated
 * estimate or a row that claims "0 pages".
 *
 * Subscribes to the query cache once (not one observer per chapter — a novel
 * series can carry two thousand of them) and re-reads on any write under this
 * series' key.
 */
export function useCachedNovelWordCounts(
  ref: SeriesId | null,
): ReadonlyMap<string, number> {
  const queryClient = useQueryClient();
  const [revision, bumpRevision] = useReducer((n: number) => n + 1, 0);
  const sourceId = ref?.sourceId ?? null;
  const seriesKey = ref?.seriesKey ?? null;

  useEffect(() => {
    if (sourceId === null || seriesKey === null) return;
    return queryClient.getQueryCache().subscribe((event) => {
      const key = event.query.queryKey;
      if (
        Array.isArray(key) &&
        key[0] === "novels" &&
        key[1] === "chapter" &&
        key[2] === sourceId &&
        key[3] === seriesKey
      ) {
        // Deferred to a microtask, not called straight through.
        //
        // The query cache notifies SYNCHRONOUSLY, from inside whatever call
        // stack wrote to it — and that stack is sometimes another component's
        // render (opening the reader from this page mounts `useNovelChapter`,
        // which touches the cache while React is rendering `NovelReader`).
        // Updating this component from there is the "Cannot update a component
        // while rendering a different component" violation; a microtask puts
        // the update back outside the render phase, where it belongs.
        queueMicrotask(bumpRevision);
      }
    });
  }, [queryClient, sourceId, seriesKey]);

  return useMemo(() => {
    const counts = new Map<string, number>();
    if (sourceId === null || seriesKey === null) return counts;
    const entries = queryClient.getQueriesData<NovelChapterPayload>({
      queryKey: [...NOVELS_KEY, "chapter", sourceId, seriesKey],
    });
    for (const [key, payload] of entries) {
      const chapterKey = key[4];
      if (typeof chapterKey !== "string" || !payload) continue;
      const chapter = toNovelChapter(payload);
      if (chapter.wordCount > 0) counts.set(chapterKey, chapter.wordCount);
    }
    return counts;
    // `revision` is the subscription's signal that the cache changed; the
    // cache itself is not reactive, so it has to be in the dependency list —
    // which is exactly the "unnecessary dependency" the rule cannot see.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queryClient, sourceId, seriesKey, revision]);
}
