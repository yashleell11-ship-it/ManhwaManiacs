"use client";

import { useCallback, useMemo, useRef, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
// Imported directly rather than through the `@/features/novels` barrel, which
// also pulls in the novel reader.
import { useIsNovelSource } from "@/features/novels/hooks";
import { NovelShelf } from "@/features/novels/components/NovelShelf";
import { useLoadMoreOnScroll } from "@/lib/use-load-more-on-scroll";
import { useShortcut } from "@/lib/keyboard";
import { useDebouncedValue } from "@/lib/use-debounced-value";
import {
  useInfiniteSourceSeries,
  useRefreshSourceBrowse,
  useSourceBrowseModes,
  useSourceGenres,
  useSources,
} from "../hooks";
import { SHELF_PLATE_SIZES, coverPath } from "@/features/novels/shelf";
import { sourceImageUrl } from "../api";
import { browsePaging } from "../browse-paging";
import { BrowseFreshness } from "./BrowseFreshness";
import { SourceBrowseLoading } from "./SourceBrowseLoading";
import { SourceLogo } from "./SourceLogo";
import { SourceSeriesGrid } from "./SourceSeriesGrid";

/**
 * How long this box waits before it searches.
 *
 * The same 300 ms the global search box takes, for a much smaller reason: this
 * queries ONE source, so a keystroke here costs a single upstream request
 * rather than a fan-out across the whole registry. The wait is here so holding
 * a key down does not queue a request per character against one site's
 * politeness budget — not because the search is expensive.
 */
const SEARCH_DEBOUNCE_MS = 300;

interface SourceBrowserViewProps {
  sourceId: string;
}

export function SourceBrowserView({ sourceId }: SourceBrowserViewProps) {
  const router = useRouter();
  const searchParams = useSearchParams();
  const sourcesQuery = useSources();
  // `undefined` while the listing loads; the shelf/grid choice waits for it
  // rather than rendering a poster grid of novels for a frame.
  const isNovel = useIsNovelSource(sourceId);
  const browseModesQuery = useSourceBrowseModes(sourceId);
  const genresQuery = useSourceGenres(sourceId);
  const sourceName =
    sourcesQuery.data?.find((source) => source.id === sourceId)?.name ?? sourceId;
  const sourceIconUrl =
    sourcesQuery.data?.find((source) => source.id === sourceId)?.icon_url ?? null;

  const initialGenre = searchParams.get("genre") ?? "";
  const [search, setSearch] = useState("");
  // Searches as it is typed, like every other box in the app. It used to run
  // only on submit, so typing into it and waiting — which is what a search box
  // teaches you to do — showed the unfiltered catalogue indefinitely.
  const [query, searchNow] = useDebouncedValue(search.trim(), SEARCH_DEBOUNCE_MS);
  const [sort, setSort] = useState("default");
  const [genre, setGenre] = useState(initialGenre);
  const [prevInitialGenre, setPrevInitialGenre] = useState(initialGenre);
  const searchRef = useRef<HTMLInputElement>(null);

  // Sync genre state when the URL-derived genre changes (e.g. back/forward
  // navigation). Adjusting state during render is React's recommended pattern
  // and avoids a setState-in-effect.
  if (initialGenre !== prevInitialGenre) {
    setPrevInitialGenre(initialGenre);
    setGenre(initialGenre);
  }

  const browseModes = browseModesQuery.data ?? [{ id: "default", label: "Browse" }];
  const activeSort = browseModes.some((mode) => mode.id === sort) ? sort : browseModes[0]?.id ?? "default";

  const genreOptions = useMemo(() => {
    const options = [...(genresQuery.data ?? [])];
    if (genre && !options.some((item) => item.id === genre || item.label === genre)) {
      options.unshift({ id: genre.toLowerCase().replace(/\s+/g, "-"), label: genre });
    }
    return options;
  }, [genresQuery.data, genre]);

  const selectedGenreValue = useMemo(() => {
    if (!genre) {
      return "";
    }
    const match = genreOptions.find(
      (item) =>
        item.id === genre ||
        item.label === genre ||
        item.label.toLowerCase() === genre.toLowerCase(),
    );
    return match?.id ?? genre;
  }, [genre, genreOptions]);

  const seriesQuery = useInfiniteSourceSeries(
    sourceId,
    query,
    activeSort !== "default" ? activeSort : undefined,
    genre || undefined,
  );

  const items = useMemo(
    () => seriesQuery.data?.pages.flatMap((page) => page.items) ?? [],
    [seriesQuery.data?.pages],
  );
  const total = seriesQuery.data?.pages[0]?.total ?? items.length;
  // Page 1 is the one the server cached; later pages carry their own block but
  // the listing as a whole is only as fresh as where it started.
  const browseCache = seriesQuery.data?.pages[0]?.cache;

  const refreshBrowse = useRefreshSourceBrowse(sourceId, {
    query,
    sort: activeSort,
    genre,
  });

  const updateGenre = useCallback(
    (nextGenreId: string) => {
      const match = genreOptions.find((item) => item.id === nextGenreId);
      const nextLabel = match?.label ?? nextGenreId;
      setGenre(nextLabel);
      const params = new URLSearchParams(searchParams.toString());
      if (nextGenreId) {
        params.set("genre", nextLabel);
      } else {
        params.delete("genre");
      }
      const suffix = params.toString();
      router.replace(suffix ? `/sources/${sourceId}?${suffix}` : `/sources/${sourceId}`, {
        scroll: false,
      });
    },
    [genreOptions, router, searchParams, sourceId],
  );

  // A failed next page stops the scroll loader and keeps what is on screen;
  // see `browse-paging.ts` for what it did before.
  const paging = browsePaging({
    itemCount: items.length,
    hasNextPage: Boolean(seriesQuery.hasNextPage),
    isFetchingNextPage: seriesQuery.isFetchingNextPage,
    isFetchNextPageError: seriesQuery.isFetchNextPageError,
    hasError: Boolean(seriesQuery.error),
  });

  const loadMore = useCallback(() => {
    if (
      seriesQuery.hasNextPage &&
      !seriesQuery.isFetchingNextPage &&
      !seriesQuery.isFetchNextPageError
    ) {
      void seriesQuery.fetchNextPage();
    }
  }, [seriesQuery]);

  const sentinelRef = useLoadMoreOnScroll(
    paging.autoLoad,
    loadMore,
    seriesQuery.isFetchingNextPage || seriesQuery.isLoading,
  );

  const errorMessage =
    paging.showFullError && seriesQuery.error instanceof Error
      ? seriesQuery.error.message
      : undefined;
  const retryFullError = paging.showFullError
    ? () =>
        void (paging.retry === "next-page"
          ? seriesQuery.fetchNextPage()
          : seriesQuery.refetch())
    : undefined;

  useShortcut({
    id: "sources.focus-search",
    keys: "/",
    description: "Focus source search",
    group: "Sources",
    handler: useCallback(() => {
      searchRef.current?.focus();
    }, []),
  });

  return (
    <div className="p-6">
      <div className="mb-6 flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
        <div className="min-w-0">
          <div className="group flex items-center gap-3">
            <SourceLogo
              id={sourceId}
              name={sourceName}
              iconUrl={sourceIconUrl}
              size={48}
            />
            <div className="min-w-0">
              <h1 className="truncate font-display text-3xl text-fg transition-colors group-hover:text-primary">
                {sourceName}
              </h1>
              {!seriesQuery.isLoading && items.length > 0 ? (
                <div className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted">
                  <span>
                    {items.length}
                    {total > items.length ? ` of ${total}` : ""}{" "}
                    {isNovel ? "books" : "series"}
                    {query ? ` · “${query}”` : ""}
                  </span>
                  <BrowseFreshness
                    cache={browseCache}
                    onRefresh={() => refreshBrowse.mutate()}
                    refreshing={refreshBrowse.isPending}
                  />
                </div>
              ) : null}
            </div>
          </div>
        </div>
        <form
          className="flex w-full max-w-2xl flex-col gap-2 sm:flex-row sm:items-center"
          onSubmit={(event) => {
            event.preventDefault();
            // Enter and the button skip the wait: whoever pressed one has
            // plainly finished typing.
            searchNow();
          }}
        >
          <label className="flex w-full min-w-0 flex-1 flex-col gap-1 sm:max-w-[11rem]">
            <span className="text-xs text-muted">Genre</span>
            <select
              value={selectedGenreValue}
              onChange={(event) => updateGenre(event.target.value)}
              className="h-10 w-full rounded-lg border border-border bg-surface-2 px-3 text-sm text-fg"
              aria-label="Filter by genre"
            >
              <option value="">All genres</option>
              {genreOptions.map((option) => (
                <option key={option.id} value={option.id}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label className="flex min-w-0 flex-1 flex-col gap-1">
            <span className="text-xs text-muted">Search</span>
            <div className="flex gap-2">
              <Input
                ref={searchRef}
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="Search this source…"
                aria-label="Search source"
              />
              <Button type="submit" className="shrink-0">
                Search
              </Button>
            </div>
          </label>
        </form>
      </div>

      {!query && browseModes.length > 1 ? (
        <div className="mb-6 flex flex-wrap gap-2">
          {browseModes.map((mode) => (
            <Button
              key={mode.id}
              type="button"
              size="sm"
              variant={activeSort === mode.id ? "primary" : "secondary"}
              onClick={() => setSort(mode.id)}
            >
              {mode.label}
            </Button>
          ))}
        </div>
      ) : null}

      <div className="relative">
        {/* A novel source is a shelf, not a wall of posters: prose catalogues
            have weak cover art and the metadata is what a reader picks by. */}
        {isNovel ? (
          <NovelShelf
            books={items.map((series) => ({
              key: series.id,
              href: `/sources/${encodeURIComponent(sourceId)}/series/${encodeURIComponent(series.id)}`,
              title: series.title,
              author: series.author,
              description: series.description,
              chapterCount: series.chapter_count,
              status: series.status,
              genres: series.genres,
              coverUrl: coverPath(series.cover_url)
                ? sourceImageUrl(series.cover_url, SHELF_PLATE_SIZES)
                : null,
              note: null,
            }))}
            isLoading={seriesQuery.isLoading}
            emptyTitle="No books found"
            emptyDescription={
              query
                ? `No results for “${query}” on this source.`
                : "This source returned no books."
            }
            errorMessage={errorMessage}
            onRetry={retryFullError}
          />
        ) : (
          <SourceSeriesGrid
            sourceId={sourceId}
            items={items}
            isLoading={seriesQuery.isLoading}
            query={query}
            errorMessage={errorMessage}
            onRetry={retryFullError}
          />
        )}
        <SourceBrowseLoading
          active={seriesQuery.isLoading}
          sourceId={sourceId}
          sourceName={sourceName}
          iconUrl={sourceIconUrl}
        />
      </div>

      <div ref={sentinelRef} className="h-8" aria-hidden />

      {seriesQuery.isFetchingNextPage ? (
        <p className="mt-4 text-center text-sm text-muted">Loading more…</p>
      ) : null}

      {paging.showLoadMoreRetry ? (
        <div
          role="status"
          className="mt-4 flex items-center justify-center gap-2 text-sm text-muted"
        >
          <span>Couldn’t load more.</span>
          {/* The one page that failed — never `refetch`, which on an infinite
              query reloads every page already shown. */}
          <Button
            type="button"
            size="sm"
            variant="secondary"
            onClick={() => void seriesQuery.fetchNextPage()}
          >
            Retry
          </Button>
        </div>
      ) : null}

      {!seriesQuery.hasNextPage && items.length > 0 && !seriesQuery.isLoading ? (
        <p className="mt-4 text-center text-sm text-muted">End of results</p>
      ) : null}
    </div>
  );
}
