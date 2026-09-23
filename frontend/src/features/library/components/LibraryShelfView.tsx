"use client";

import { useMemo } from "react";
import Link from "next/link";
import { BookOpen, Compass, Telescope, TriangleAlert } from "lucide-react";
import { EmptyState } from "@/components/ui/empty-state";
import { OfflineState } from "@/components/ui/offline-state";
import { FadeIn } from "@/components/premium/FadeIn";
import { HeroHeading } from "@/components/premium/HeroHeading";
import { PrimaryPillButton } from "@/components/premium/PrimaryPillButton";
import { apiErrorMessage, resolveViewState } from "@/lib/view-state";
import { useContentModeFilter } from "@/features/content-mode";
// Direct rather than through the `@/features/novels` barrel, which also pulls
// in the novel reader.
import { NovelShelf } from "@/features/novels/components/NovelShelf";
import { SHELF_PLATE_SIZES, coverPath, type ShelfBook } from "@/features/novels/shelf";
import { libraryCoverUrl } from "../api";
import { shelfCountLine } from "../count-line";
import { continueReadingSeriesKey } from "../continue-reading";
import { useContinueReading, useSeriesList } from "../hooks";
import { followedShelfNote } from "../read-state";
import { ContinueReadingRail, ContinueReadingStrip } from "./ContinueReading";
import { FollowedSeriesCard } from "./FollowedSeriesCard";

/**
 * The Library tab — the followed series, and nothing else (spec §3.4).
 *
 * Source-native: reads `GET /library/series`, the per-profile `followed_series`
 * set. One heading, one grid of covers. Browse Sources is the single call to
 * action, in the empty state or the small header button.
 *
 * It also carries "where was I", because this is the tab every client opens
 * on: below `md` as the one-row `ContinueReadingStrip`, from `md` up as the
 * hero card and rail (`ContinueReadingRail`). The rail used to live only on
 * `/library/browse`, so a desktop landing here saw covers and a muted
 * "Ch X of Y" and nothing to resume from. Exactly one of the two shows at any
 * width.
 */
export function LibraryShelfView() {
  const seriesQuery = useSeriesList({
    page: 1,
    per_page: 200,
    sort: "recently_updated",
  });
  const continueQuery = useContinueReading(1);

  // Scoped to the active content mode (Manga / Novels). A no-op when the
  // server has novels off — `filterRows` returns the array untouched.
  const { filterRows, ready: modeReady, mode } = useContentModeFilter();
  const isNovelMode = mode === "novel";
  const followed = useMemo(
    () => filterRows(seriesQuery.data?.items, (series) => series.source_id),
    [filterRows, seriesQuery.data],
  );
  const continueItems = useMemo(
    () => filterRows(continueQuery.data, (item) => item.source_id),
    [filterRows, continueQuery.data],
  );
  // The fallback for a progress payload without a title (an older server).
  // The shelf is already holding every followed row, so the join happens here
  // rather than through `useFollowedIndex`, which would refetch the same rows
  // under a second cache key to learn one string.
  const continueTitles = useMemo(() => {
    const map = new Map<string, string>();
    for (const series of followed) {
      if (series.title) map.set(continueReadingSeriesKey(series), series.title);
    }
    return map;
  }, [followed]);

  // A followed row carries no author, blurb or genres — those live on the
  // source — so a shelved novel shows what the library actually knows.
  const shelfBooks = useMemo<ShelfBook[]>(
    () =>
      isNovelMode
        ? followed.map((series) => ({
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
    [followed, isNovelMode],
  );

  const viewState = resolveViewState({
    isLoading: seriesQuery.isLoading || !modeReady,
    error: seriesQuery.error,
    isEmpty: followed.length === 0,
  });

  if (viewState === "loading") {
    return <ShelfSkeleton />;
  }

  if (viewState === "offline") {
    return (
      <div className="px-5 pt-6 md:px-8">
        <OfflineState
          reason="Your library needs a connection to load."
          onRetry={() => void seriesQuery.refetch()}
        />
      </div>
    );
  }

  if (viewState === "error") {
    return (
      <div className="px-5 pt-6 md:px-8">
        <EmptyState
          tone="error"
          icon={TriangleAlert}
          title="Couldn't load your library"
          description={apiErrorMessage(seriesQuery.error, "Something went wrong.")}
          action={{ label: "Try again", onClick: () => void seriesQuery.refetch() }}
        />
      </div>
    );
  }

  if (viewState === "empty") {
    return <ShelfEmpty novels={isNovelMode} />;
  }

  return (
    <div className="px-5 pb-8 pt-6 md:px-8">
      <FadeIn>
        <div className="flex items-start justify-between gap-4">
          <div>
            <HeroHeading className="text-[clamp(1.5rem,6.5vw,3rem)]">Library</HeroHeading>
            <p className="mt-1 text-xs text-muted">{shelfCountLine(followed.length, isNovelMode)}</p>
          </div>
          <Link
            href="/sources"
            title="Browse Sources"
            className="flex size-11 shrink-0 items-center justify-center rounded-full text-muted transition-colors hover:bg-fg/10 hover:text-fg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
          >
            <Telescope className="size-5" aria-hidden />
            <span className="sr-only">Browse Sources</span>
          </Link>
        </div>
      </FadeIn>

      <ContinueReadingStrip
        items={continueItems}
        titles={continueTitles}
        novels={isNovelMode}
        className="mt-5 md:hidden"
      />
      <ContinueReadingRail
        items={continueItems}
        titles={continueTitles}
        novels={isNovelMode}
        className="mb-0 mt-6 hidden md:block"
      />

      {isNovelMode ? (
        <NovelShelf className="mt-6" books={shelfBooks} />
      ) : (
        <div className="stagger-in mt-6 grid grid-cols-3 gap-x-3 gap-y-5 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
          {followed.map((series) => (
            <FollowedSeriesCard key={series.id} series={series} />
          ))}
        </div>
      )}
    </div>
  );
}

function ShelfEmpty({ novels }: { novels: boolean }) {
  return (
    <div className="flex min-h-[70vh] flex-col items-center justify-center px-8 text-center">
      <BookOpen className="size-10 text-muted" aria-hidden />
      <h1 className="mt-4 font-display text-2xl font-bold text-fg">
        {novels ? "Your shelf is empty" : "Your library is empty"}
      </h1>
      <p className="mt-2 max-w-xs text-sm text-muted">
        {novels
          ? "Add a book from a novel source to start your shelf."
          : "Follow series from Sources to build your warm little shelf."}
      </p>
      <PrimaryPillButton
        href="/sources"
        label="Browse Sources"
        icon={<Compass className="size-4" aria-hidden />}
        className="mt-6"
      />
    </div>
  );
}

function ShelfSkeleton() {
  return (
    <div className="px-5 pb-8 pt-6 md:px-8">
      <div className="h-10 w-40 animate-pulse rounded-lg bg-surface-2" />
      <div className="mt-6 grid grid-cols-3 gap-x-3 gap-y-5 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8">
        {Array.from({ length: 12 }).map((_, i) => (
          <div key={i}>
            <div className="aspect-[2/3] w-full animate-pulse rounded-xl bg-surface-2" />
            <div className="mt-2 h-3 w-3/4 animate-pulse rounded bg-surface-2" />
          </div>
        ))}
      </div>
    </div>
  );
}
