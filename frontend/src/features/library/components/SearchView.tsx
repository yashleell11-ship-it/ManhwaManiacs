"use client";

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import {
  BookOpen,
  ChevronDown,
  ChevronUp,
  Clock,
  Search,
  SearchX,
  SlidersHorizontal,
  TrendingUp,
  TriangleAlert,
} from "lucide-react";
import { EmptyState } from "@/components/ui/empty-state";
import { OfflineState } from "@/components/ui/offline-state";
import { Input } from "@/components/ui/input";
import { apiErrorMessage, resolveViewState } from "@/lib/view-state";
import { useContentModeFilter } from "@/features/content-mode";
import { useShortcut } from "@/lib/keyboard";
import { useDebouncedValue } from "@/lib/use-debounced-value";
import { cn } from "@/lib/cn";
import { useFederatedSearch, useRetrySearchSource } from "@/features/sources/hooks";
import {
  globalSearchScopeLabel,
  searchGroupKey,
  searchResultCount,
  splitSearchGroups,
} from "@/features/sources/global-search";
import {
  getRecentSearchesServerSnapshot,
  getRecentSearchesSnapshot,
  subscribeRecentSearches,
  writeRecentSearch,
} from "@/features/library/recent-searches";
import { searchResultsHeader } from "@/features/library/search-header";
import { GlobalSearchGroupSection } from "./GlobalSearchGroupSection";
import { SearchResultCardSkeleton } from "./GlobalSearchResultCard";

/**
 * How long the box waits before it searches.
 *
 * Every keystroke used to be its own federated fan-out across all 63 sources.
 * Typing a 13-character query fired 13 of them, and because each source's
 * search-scoped connector is a single shared instance behind a politeness token
 * bucket, those 13 queued up on each other: measured per-search latency went
 * from 2.5s pasted to 7-9s typed, healthy sources were recorded as "Timed out"
 * because they missed a deadline they spent waiting in that queue, and backend
 * RSS went from 78 MB to 588 MB on a 3.8 GB box. One search per word instead of
 * one per letter is the whole fix; 300 ms is what the Flutter client already
 * waits (`search_screen.dart`).
 */
const SEARCH_DEBOUNCE_MS = 300;

const TRENDING_SUGGESTIONS = [
  "fantasy",
  "romance",
  "action",
  "manhwa",
  "manga",
  "webtoon",
  "horror",
  "sci-fi",
] as const;

function SuggestionChip({
  label,
  onSelect,
}: {
  label: string;
  onSelect: (value: string) => void;
}) {
  return (
    <button
      type="button"
      onClick={() => onSelect(label)}
      // `py-1.5` alone gave a 33px chip, which is a mis-tap between neighbours
      // on a touch screen — hence the coarse-pointer floor.
      className="inline-flex shrink-0 items-center whitespace-nowrap rounded-full border border-border/50 bg-white/[0.03] px-3 py-1.5 text-sm text-muted transition-colors hover:border-primary/30 hover:bg-primary/10 hover:text-primary [@media(pointer:coarse)]:min-h-11"
    >
      {label}
    </button>
  );
}

/**
 * One row that scrolls on a phone, the wrapped block it always was above `md`.
 *
 * Eight trending terms of eight different widths inside 327px of phone gutter
 * wrapped into three ragged rows — the same shape the browse toolbar's filter
 * chips made before they became a rail, and the tallest block on an idle
 * `/search`. Recent terms get the same treatment: two neighbouring chip groups
 * where one scrolls and the other wraps would read as two different controls.
 *
 * `max-md:` throughout, so from `md` up this is `flex flex-wrap gap-2` and
 * nothing else, exactly as before. `-mx-6`/`px-6` lets the rail bleed to the
 * gutter edge, which is what makes the cut-off last chip say "scroll me".
 */
function SuggestionRail({ children }: { children: React.ReactNode }) {
  return (
    <div className="max-md:-mx-6 max-md:overflow-x-auto max-md:px-6 max-md:[scrollbar-width:none] max-md:[&::-webkit-scrollbar]:hidden">
      <div className="flex gap-2 max-md:w-max md:flex-wrap">{children}</div>
    </div>
  );
}

function SectionLabel({
  icon: Icon,
  label,
}: {
  icon: React.ComponentType<{ className?: string }>;
  label: string;
}) {
  return (
    <div className="mb-3 flex items-center gap-2">
      <Icon className="size-3.5 text-primary" aria-hidden />
      <span className="text-[11px] font-semibold uppercase tracking-widest text-muted">
        {label}
      </span>
    </div>
  );
}

export function SearchView() {
  const [query, setQuery] = useState("");
  const [filtersOpen, setFiltersOpen] = useState(false);
  const [quietOpen, setQuietOpen] = useState(false);
  const searchRef = useRef<HTMLInputElement>(null);
  const lastPersistedRef = useRef<string | null>(null);
  const trimmedQuery = query.trim();
  // The typed value drives the screen's own state — the suggestions panel, the
  // results heading — and the settled one drives the request. See
  // `SEARCH_DEBOUNCE_MS`.
  const [settledQuery, searchNow] = useDebouncedValue(trimmedQuery, SEARCH_DEBOUNCE_MS);
  const searchParams = useMemo(
    () => ({ q: settledQuery, page: 1, per_page: 40 }),
    [settledQuery],
  );
  const searchQuery = useFederatedSearch(searchParams);
  const { filterRows } = useContentModeFilter();
  const retrySource = useRetrySearchSource(searchParams);
  const recentSearches = useSyncExternalStore(
    subscribeRecentSearches,
    getRecentSearchesSnapshot,
    getRecentSearchesServerSnapshot,
  );

  // Keyed on the SETTLED query: a recents list built from every keystroke
  // would fill with the prefixes of one word.
  useEffect(() => {
    if (
      settledQuery.length >= 2 &&
      searchQuery.data &&
      !searchQuery.isLoading &&
      lastPersistedRef.current !== settledQuery
    ) {
      lastPersistedRef.current = settledQuery;
      writeRecentSearch(settledQuery);
    }
  }, [settledQuery, searchQuery.data, searchQuery.isLoading]);

  useShortcut({
    id: "search.focus-input",
    keys: "/",
    description: "Focus search",
    group: "Search",
    handler: useCallback(() => {
      searchRef.current?.focus();
    }, []),
  });

  const applySuggestion = useCallback(
    (value: string) => {
      setQuery(value);
      // A chosen term is a finished query, so it skips the wait entirely.
      searchNow();
      searchRef.current?.focus();
    },
    [searchNow],
  );

  const hasQuery = trimmedQuery.length > 0;
  // The typed query has moved on and the request has not left yet. Counted as
  // searching so the first letter draws skeletons instead of flashing "No
  // results found" for the length of the debounce.
  const debouncePending = trimmedQuery !== settledQuery;
  // `isFetching`, not `isLoading`. `placeholderData` keeps the PREVIOUS query's
  // results on screen while the new one runs, which is right — but `isLoading`
  // is false the whole time it does, so the header used to label those stale
  // rows "N results found" and print the scope line for a query that is no
  // longer the one in the box. On a fan-out that can take twelve seconds, that
  // is the whole of "it doesn't update while I type": the answer on screen is
  // the last word's, and nothing says so.
  const searching = searchQuery.isFetching || debouncePending;
  // The flat `items` list is the backend's legacy view; sections are rendered
  // from `groups` so a source that failed or returned nothing says so itself.
  // Scoped to the active content mode. A group's `source` is null for the
  // local-library section, which `matchesContentMode` resolves to manga —
  // correct, since the local library is whatever the mode says it is and is
  // itself already filtered upstream. A no-op when novels are disabled.
  const groups = useMemo(
    () => filterRows(searchQuery.data?.groups, (group) => group.source),
    [filterRows, searchQuery.data],
  );
  const { visible, quiet } = useMemo(() => splitSearchGroups(groups), [groups]);
  const resultCount = searchResultCount(groups);
  // Per-source failures already render inline via `GlobalSearchGroupSection`'s
  // own retry; this only fires when the request as a whole never came back
  // (most often the backend being unreachable).
  const viewState = resolveViewState({
    // Only the FIRST search waits behind the debounce; once there are results
    // on screen they stay there while the next query settles, which is what
    // `placeholderData` is for.
    isLoading:
      searchQuery.isLoading || (debouncePending && searchQuery.data === undefined),
    error: searchQuery.error,
    isEmpty: visible.length === 0 && quiet.length === 0,
  });
  const scopeLabel = searchQuery.data
    ? globalSearchScopeLabel(
        searchQuery.data.sources_queried,
        searchQuery.data.sources_failed,
      )
    : null;

  const renderGroup = (group: (typeof groups)[number]) => {
    // Null for the local library group — there is no remote call to retry.
    const sourceId = group.source;
    return (
      <GlobalSearchGroupSection
        key={searchGroupKey(group)}
        group={group}
        isRetrying={retrySource.isPending && retrySource.variables === sourceId}
        onRetry={sourceId ? () => retrySource.mutate(sourceId) : undefined}
      />
    );
  };

  return (
    <div className="min-h-full bg-bg px-6 py-8 md:px-10">
      <div className="mx-auto max-w-3xl">
        <header className="mb-8 text-center">
          <h1 className="font-display text-4xl uppercase tracking-wide text-fg md:text-5xl">
            Search
          </h1>
          {/* Pointer widths only. Under a 36px hero reading SEARCH, above a
              field placeheld "Search manga, manhwa, webtoons…", this line told
              a phone reader nothing the two things touching it had not already
              said — and the Flutter search screen has no subtitle at all. */}
          <p className="mt-2 hidden text-sm text-muted md:block md:text-base">
            Find your next favorite series
          </p>
        </header>

        <div className="relative mb-6">
          <Search
            className="pointer-events-none absolute left-5 top-1/2 size-5 -translate-y-1/2 text-muted"
            aria-hidden
          />
          <Input
            ref={searchRef}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") searchNow();
            }}
            placeholder="Search manga, manhwa, webtoons..."
            className="h-14 rounded-2xl border-border/50 bg-white/[0.03] pl-14 text-base focus-visible:ring-primary/40"
            aria-label="Search library and sources"
            autoComplete="off"
          />
        </div>

        {!hasQuery ? (
          <div className="space-y-6">
            {recentSearches.length > 0 ? (
              <section>
                <SectionLabel icon={Clock} label="Recent" />
                <SuggestionRail>
                  {recentSearches.map((term) => (
                    <SuggestionChip key={term} label={term} onSelect={applySuggestion} />
                  ))}
                </SuggestionRail>
              </section>
            ) : null}

            <section>
              <SectionLabel icon={TrendingUp} label="Trending" />
              <SuggestionRail>
                {TRENDING_SUGGESTIONS.map((term) => (
                  <SuggestionChip key={term} label={term} onSelect={applySuggestion} />
                ))}
              </SuggestionRail>
            </section>

            <div className="flex justify-center pt-2">
              <button
                type="button"
                onClick={() => setFiltersOpen((open) => !open)}
                className={cn(
                  "inline-flex items-center gap-2 rounded-full border border-border/50 bg-white/[0.03] px-4 py-2 text-sm text-muted transition-colors hover:border-primary/30 hover:text-fg [@media(pointer:coarse)]:min-h-11",
                  filtersOpen && "border-primary/30 bg-primary/10 text-primary",
                )}
                aria-expanded={filtersOpen}
              >
                <SlidersHorizontal className="size-4" />
                Advanced Filters
              </button>
            </div>

            {filtersOpen ? (
              <div className="glass-panel rounded-xl p-4 text-sm text-muted">
                <p>
                  Search spans your local library and every enabled source
                  connector at once.
                </p>
                <p className="mt-2">
                  Press{" "}
                  <kbd className="rounded bg-white/10 px-1.5 py-0.5 font-mono text-xs">/</kbd> to
                  focus search. Use the Library page for status, sort, and collection filters.
                </p>
              </div>
            ) : null}

            {/* Pointer widths only. "Start typing to search" under a heading
                reading SEARCH, a field already inviting the same, and — one tap
                away — an Advanced Filters panel whose first line is this card's
                description almost word for word. On a phone it was the tallest
                thing on the screen and said the least. */}
            <div className="hidden md:block">
              <EmptyState
                icon={Search}
                title="Start typing to search"
                description="Search your library and every source connector at once."
              />
            </div>
          </div>
        ) : null}

        {hasQuery ? (
          <section>
            <SectionLabel icon={BookOpen} label="Results" />
            {viewState === "content" || viewState === "empty" ? (
              <div className="mb-4">
                <p className="text-sm text-muted">
                  {searchResultsHeader({
                    searching,
                    isLoadingRest: searchQuery.isLoadingRest,
                    resultCount,
                    sourcesDeferred: searchQuery.data?.sources_deferred,
                  })}
                </p>
                {!searching && scopeLabel ? (
                  <p className="mt-0.5 text-xs text-muted/70">{scopeLabel}</p>
                ) : null}
              </div>
            ) : null}

            {viewState === "loading" ? (
              <div className="space-y-3">
                {Array.from({ length: 4 }).map((_, index) => (
                  <SearchResultCardSkeleton key={index} />
                ))}
              </div>
            ) : viewState === "offline" ? (
              <OfflineState
                reason="Search needs a connection to reach your library and sources."
                onRetry={() => void searchQuery.refetch()}
              />
            ) : viewState === "error" ? (
              <EmptyState
                tone="error"
                icon={TriangleAlert}
                title="Search failed"
                description={apiErrorMessage(searchQuery.error, "Something went wrong.")}
                action={{ label: "Try again", onClick: () => void searchQuery.refetch() }}
              />
            ) : viewState === "empty" ? (
              <EmptyState
                icon={SearchX}
                title="No results found"
                description="Try a different search term across your library and sources."
              />
            ) : (
              <>
                {visible.map(renderGroup)}

                {quiet.length > 0 ? (
                  <div className="mt-2">
                    <button
                      type="button"
                      onClick={() => setQuietOpen((open) => !open)}
                      aria-expanded={quietOpen}
                      className="inline-flex items-center gap-2 rounded-full border border-border/50 bg-white/[0.03] px-4 py-2 text-sm text-muted transition-colors hover:border-primary/30 hover:text-fg"
                    >
                      {quietOpen ? (
                        <ChevronUp className="size-4" aria-hidden />
                      ) : (
                        <ChevronDown className="size-4" aria-hidden />
                      )}
                      {quietOpen ? "Hide" : "Show"} {quiet.length}{" "}
                      {quiet.length === 1 ? "source" : "sources"} with no matches
                    </button>
                    {quietOpen ? (
                      <div className="mt-4">{quiet.map(renderGroup)}</div>
                    ) : null}
                  </div>
                ) : null}
              </>
            )}
          </section>
        ) : null}
      </div>
    </div>
  );
}
