"use client";

import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { TriangleAlert } from "lucide-react";
import { EmptyState } from "@/components/ui/empty-state";
import { OfflineState } from "@/components/ui/offline-state";
import { apiErrorMessage, resolveViewState } from "@/lib/view-state";
import { useContentModeFilter } from "@/features/content-mode";
// Direct rather than through the `@/features/novels` barrel, which also pulls
// in the novel reader.
import { NovelShelf, type NovelShelfSelection } from "@/features/novels/components/NovelShelf";
import { SHELF_PLATE_SIZES, coverPath, type ShelfBook } from "@/features/novels/shelf";
import { cn } from "@/lib/cn";
import { BulkActionBar } from "./BulkActionBar";
import { ContinueReading } from "./ContinueReading";
import { LibraryToolbar } from "./LibraryToolbar";
import { SeriesGrid } from "./SeriesGrid";
import { libraryCoverUrl } from "../api";
import { followedShelfNote } from "../read-state";
import {
  getLibraryDensityServerSnapshot,
  getLibraryDensitySnapshot,
  type LibraryDensity,
  subscribeLibraryDensity,
  writeLibraryDensity,
} from "../density";
import {
  type BulkAction,
  useBulkSeriesAction,
  useContinueReading,
  useSeriesList,
} from "../hooks";
import {
  EMPTY_SELECTION,
  extendSelection,
  orderedSelection,
  retainSelection,
  selectAll,
  type SelectionState,
  toggleSelection,
} from "../selection";
import {
  type LibraryQuery,
  hasActiveFilters,
  libraryQueryToListParams,
} from "../url-state";
import { useLibraryUrlState } from "../use-library-url-state";
import type { FollowedSeries } from "../types";

/** The server's ceiling (`GET /library/series` `per_page` le 200). */
const PAGE_SIZE = 200;
const SEARCH_DEBOUNCE_MS = 300;

/**
 * The full, filterable view of the profile's library (`/library/browse`).
 * Source-native: the library is the `followed_series` set, so this is the shelf
 * with search, sort, reading-status and favourite filters plus multi-select
 * bulk actions.
 */
export function LibraryView() {
  const { query, setQuery } = useLibraryUrlState();
  const [selectMode, setSelectMode] = useState(false);
  const [selection, setSelection] = useState<SelectionState>(EMPTY_SELECTION);

  const [searchInput, setSearchInput] = useState(query.search);
  const [committedSearch, setCommittedSearch] = useState(query.search);

  if (query.search !== committedSearch) {
    setCommittedSearch(query.search);
    setSearchInput(query.search);
  }

  useEffect(() => {
    const trimmed = searchInput.trim();
    if (trimmed === query.search) return;
    const timer = setTimeout(() => {
      setCommittedSearch(trimmed);
      setQuery({ ...query, search: trimmed }, { replace: true });
    }, SEARCH_DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [searchInput, query, setQuery]);

  const density = useSyncExternalStore(
    subscribeLibraryDensity,
    getLibraryDensitySnapshot,
    getLibraryDensityServerSnapshot,
  );

  const listParams = useMemo(
    () => libraryQueryToListParams(query, { page: 1, per_page: PAGE_SIZE }),
    [query],
  );
  const seriesQuery = useSeriesList(listParams);
  const continueQuery = useContinueReading(12);
  const bulk = useBulkSeriesAction();

  // Scoped to the active content mode (Manga / Novels). Everything downstream
  // — the id map, the ordering, the selection, the grid — derives from
  // `items`, so this one filter covers the whole screen. A no-op when the
  // server has novels off.
  const { filterRows, ready: modeReady, mode } = useContentModeFilter();
  const isNovelMode = mode === "novel";
  const items = useMemo<FollowedSeries[]>(
    () => filterRows(seriesQuery.data?.items, (series) => series.source_id),
    [filterRows, seriesQuery.data],
  );
  const continueItems = useMemo(
    () => filterRows(continueQuery.data, (item) => item.source_id),
    [filterRows, continueQuery.data],
  );
  const byId = useMemo(() => {
    const map = new Map<number, FollowedSeries>();
    for (const series of items) map.set(series.id, series);
    return map;
  }, [items]);
  const orderedIds = useMemo(() => items.map((series) => series.id), [items]);

  /**
   * The same library, shelved.
   *
   * A followed row carries no author, blurb or genres — those live on the
   * source, not on the follow — so a novel's shelf line is what the library
   * actually knows: how long it is and where the reader has put it. Anything
   * more would have to be invented.
   */
  const shelfBooks = useMemo<ShelfBook[]>(
    () =>
      isNovelMode
        ? items.map((series) => ({
            key: String(series.id),
            href: `/sources/${encodeURIComponent(series.source_id)}/series/${encodeURIComponent(series.series_key)}`,
            title: series.title,
            author: null,
            description: null,
            chapterCount: series.chapter_count,
            status: null,
            genres: [],
            coverUrl: coverPath(series.cover_url)
              ? libraryCoverUrl(series.cover_url, SHELF_PLATE_SIZES)
              : null,
            note: followedShelfNote(series),
          }))
        : [],
    [isNovelMode, items],
  );
  // The server's `total` counts BOTH kinds, so it would over-report the moment
  // the mode filter drops a row. The rendered count is the honest one whenever
  // the filter is actually doing something.
  const seriesCount =
    items.length === (seriesQuery.data?.items.length ?? 0)
      ? seriesQuery.data?.total ?? items.length
      : items.length;

  const [renderedIds, setRenderedIds] = useState(orderedIds);
  if (renderedIds !== orderedIds) {
    setRenderedIds(orderedIds);
    setSelection((current) => retainSelection(current, orderedIds));
  }

  const handleSelect = useCallback(
    (seriesId: number, shiftKey: boolean) => {
      setSelection((current) =>
        shiftKey
          ? extendSelection(current, seriesId, orderedIds)
          : toggleSelection(current, seriesId),
      );
    },
    [orderedIds],
  );

  const selectedCount = selection.ids.size;
  const selecting = selectMode || selectedCount > 0;

  const clearSelection = useCallback(() => {
    setSelection(EMPTY_SELECTION);
    setSelectMode(false);
  }, []);

  const runBulkAction = useCallback(
    async (action: BulkAction) => {
      const ids = orderedSelection(selection, orderedIds);
      const rows = ids
        .map((id) => byId.get(id))
        .filter((row): row is FollowedSeries => row !== undefined);
      if (rows.length === 0) return;
      await bulk.run(action, rows);
      clearSelection();
    },
    [bulk, byId, clearSelection, orderedIds, selection],
  );

  const setDensity = useCallback((next: LibraryDensity) => {
    writeLibraryDensity(next);
  }, []);

  // The shelf addresses rows by their view-model key; the selection is keyed by
  // the numeric follow id, so the translation happens here rather than leaking
  // either shape into the other.
  const shelfSelection = useMemo<NovelShelfSelection>(
    () => ({
      selecting,
      isSelected: (book) => selection.ids.has(Number(book.key)),
      onSelect: (book, shiftKey) => handleSelect(Number(book.key), shiftKey),
    }),
    [handleSelect, selecting, selection.ids],
  );

  const applyQuery = useCallback(
    (next: LibraryQuery) => {
      clearSelection();
      setQuery(next);
    },
    [clearSelection, setQuery],
  );

  const isSearching = query.search.length > 0;
  const filtersActive = hasActiveFilters(query);
  const isLanding = !isSearching && !filtersActive;

  const viewState = resolveViewState({
    isLoading: seriesQuery.isLoading || !modeReady,
    error: seriesQuery.error,
    isEmpty: items.length === 0,
  });

  const emptyState = isSearching ? "search" : filtersActive ? "filter" : "library";

  return (
    <div className="min-h-full bg-bg px-6 py-6 md:px-10">
      <div
        className={cn(
          "mx-auto max-w-[110rem]",
          (selectedCount > 0 || bulk.message !== null) && "pb-24",
        )}
      >
        <LibraryToolbar
          countNoun={isNovelMode ? "novels" : "series"}
          showDensity={!isNovelMode}
          query={query}
          onQueryChange={applyQuery}
          searchInput={searchInput}
          onSearchInputChange={setSearchInput}
          density={density}
          onDensityChange={setDensity}
          selecting={selecting}
          onSelectingChange={(next) => {
            if (next) setSelectMode(true);
            else clearSelection();
          }}
          seriesCount={seriesCount}
        />

        {/* Pointer widths only.

            On a phone this section is a hero card and a horizontal rail under
            their own header — about 400px — sitting between the toolbar and the
            grid, so at 375px the reader scrolled past a heading, a count, three
            controls, a search box, a chip rail, a section header, a hero card
            and a rail before a single cover. The Flutter client shows no
            continue-reading section on EITHER library screen (the
            `ContinueReadingSection` in `dashboard_sections.dart` is defined and
            never built), and this is the catalogue, not the home screen.

            It is not lost: `/library`, the tab a phone opens on, now carries the
            lead item as a one-row `ContinueReadingStrip`. From `md` up, where
            there is room for it above the fold, the full section is unchanged. */}
        {isLanding && viewState !== "offline" && viewState !== "error" ? (
          <div className="hidden md:block">
            <ContinueReading
              items={continueItems}
              isLoading={continueQuery.isLoading}
              novels={isNovelMode}
            />
          </div>
        ) : null}

        {viewState === "offline" ? (
          <OfflineState
            reason="Your library needs a connection to load."
            onRetry={() => void seriesQuery.refetch()}
          />
        ) : viewState === "error" ? (
          <EmptyState
            tone="error"
            icon={TriangleAlert}
            title="Couldn't load your library"
            description={apiErrorMessage(seriesQuery.error, "Something went wrong.")}
            action={{ label: "Try again", onClick: () => void seriesQuery.refetch() }}
          />
        ) : isNovelMode ? (
          <NovelShelf
            books={shelfBooks}
            isLoading={seriesQuery.isLoading}
            emptyTitle={
              emptyState === "search"
                ? "No results found"
                : emptyState === "filter"
                  ? "No novels match these filters"
                  : "No novels yet"
            }
            emptyDescription={
              emptyState === "search"
                ? "Try a different search term or clear filters."
                : emptyState === "filter"
                  ? "Adjust your filters or favourites toggle to see more."
                  : "Browse a novel source and add a book to start your library."
            }
            emptyAction={
              emptyState === "library"
                ? { label: "Browse sources", href: "/sources" }
                : undefined
            }
            selection={shelfSelection}
          />
        ) : (
          <SeriesGrid
            items={items}
            isLoading={seriesQuery.isLoading}
            emptyState={emptyState}
            density={density}
            selection={{
              selecting,
              selectedIds: selection.ids,
              onSelect: handleSelect,
            }}
          />
        )}

        {!seriesQuery.isLoading && items.length < seriesCount ? (
          <p className="mt-6 text-center text-sm text-muted">
            Showing the first {items.length.toLocaleString()} of{" "}
            {seriesCount.toLocaleString()} {isNovelMode ? "novels" : "series"} —
            narrow it with search or a filter.
          </p>
        ) : null}
      </div>

      <BulkActionBar
        count={selectedCount}
        visibleCount={items.length}
        allSelected={selectedCount === items.length && items.length > 0}
        running={bulk.isRunning}
        progress={bulk.progress}
        message={bulk.message}
        onRun={runBulkAction}
        onSelectAll={() => setSelection(selectAll(orderedIds))}
        onClear={clearSelection}
        onCancel={bulk.cancel}
        onDismissMessage={bulk.dismissMessage}
      />
    </div>
  );
}
