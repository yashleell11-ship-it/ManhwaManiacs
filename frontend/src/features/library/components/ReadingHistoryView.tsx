"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { History, Play, TriangleAlert } from "lucide-react";
import { useContentModeFilter } from "@/features/content-mode";
import { useReadingHistory } from "@/features/library/hooks";
import { densityCoverSizes, densityGridClassName } from "@/features/library/density";
import {
  historyChapterLabel,
  historyCoverSrc,
  historyResumePoint,
  historyTitle,
} from "@/features/library/history-continue";
import type { ReadingHistoryItem } from "@/features/library/types";
import { useChapterHref, useChapterLinksReady } from "@/features/novels/use-chapter-href";
import { chapterPercent } from "@/features/novels/progress";
import { seriesPageHref } from "@/features/reader/reader-link";
import { sourcesApi } from "@/features/sources/api";
import { sourceChaptersQueryKey } from "@/features/sources/hooks";
import { CoverImage } from "@/components/ui/cover-image";
import { EmptyState } from "@/components/ui/empty-state";
import { OfflineState } from "@/components/ui/offline-state";
import { cn } from "@/lib/cn";
import { formatUtcDate } from "@/lib/utc-time";
import { apiErrorMessage, resolveViewState } from "@/lib/view-state";

/**
 * Reading history as a shelf of BOOKS — the same shape the phone shows.
 *
 * It used to be one row per chapter position headed by the raw `series_key`,
 * so a novelarchive book read as "69faa859a5f4c7d1b734d496" and forty chapters
 * of one book filled forty rows. The server now collapses to one row per book
 * and names it; this lays those out like the library grid: the cover opens the
 * book's page, and Continue picks up where the reader stopped.
 */
export function ReadingHistoryView() {
  const historyQuery = useReadingHistory(50);
  // Scoped to the active content mode, and linked through `useChapterHref` so a
  // novel row opens the novel reader. A no-op when novels are disabled.
  const { filterRows, ready: modeReady, mode } = useContentModeFilter();
  // A novel row linked before the source kinds arrive would name the page
  // strip, so the shelf waits for them (see `useChapterHref`).
  const linksReady = useChapterLinksReady();
  const history = filterRows(historyQuery.data, (entry) => entry.source_id);
  const viewState = resolveViewState({
    isLoading: historyQuery.isLoading || !modeReady || !linksReady,
    error: historyQuery.error,
    isEmpty: history.length === 0,
  });
  const density = "comfortable" as const;

  return (
    <div className="page-shell">
      <div className="page-container">
        <div className="mb-8">
          <h1 className="page-title">Reading History</h1>
          <p className="page-subtitle">Books you have been reading, most recent first.</p>
        </div>

        {viewState === "loading" ? (
          <div aria-busy="true" className={densityGridClassName(density)}>
            {Array.from({ length: 10 }).map((_, index) => (
              <div key={index} className="aspect-[2/3] animate-pulse rounded-2xl bg-surface-2" />
            ))}
          </div>
        ) : viewState === "offline" ? (
          <OfflineState
            reason="Reading history needs a connection to load."
            onRetry={() => void historyQuery.refetch()}
          />
        ) : viewState === "error" ? (
          <EmptyState
            tone="error"
            icon={TriangleAlert}
            title="Couldn't load reading history"
            description={apiErrorMessage(historyQuery.error, "Something went wrong.")}
            action={{ label: "Try again", onClick: () => void historyQuery.refetch() }}
          />
        ) : viewState === "empty" ? (
          <EmptyState
            icon={History}
            title="Nothing read yet"
            description="Open a chapter from your library and it will show up here as you go."
            action={{ label: "Go to library", href: "/library" }}
          />
        ) : (
          <div className={densityGridClassName(density)}>
            {history.map((entry) => (
              <HistoryTile
                key={entry.id}
                entry={entry}
                isNovel={mode === "novel"}
                sizes={densityCoverSizes(density)}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function HistoryTile({
  entry,
  isNovel,
  sizes,
}: {
  entry: ReadingHistoryItem;
  isNovel: boolean;
  sizes: string;
}) {
  const title = historyTitle(entry);
  const cover = historyCoverSrc(entry, sizes);
  const seriesHref = seriesPageHref({ sourceId: entry.source_id, seriesKey: entry.series_key });
  const progress =
    !entry.is_completed && entry.page_count > 0
      ? chapterPercent(entry.last_page, entry.page_count)
      : null;
  const subtitle = [
    entry.is_completed
      ? `${historyChapterLabel(entry)} · done`
      : historyChapterLabel(entry),
    entry.last_read_at ? formatUtcDate(entry.last_read_at) : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <article className="content-in group min-w-0">
      <div className="relative aspect-[2/3] w-full overflow-hidden rounded-2xl bg-surface-2 ring-1 ring-white/5 transition-all duration-300 group-hover:ring-primary/30">
        {/* The cover opens the book's page, exactly as a library cover does.
            Continue sits beside it rather than inside it: a link inside a
            link is invalid markup and swallows the inner click. */}
        <Link href={seriesHref} aria-label={title} className="absolute inset-0">
          {cover ? (
            <CoverImage
              src={cover}
              alt={title}
              fill
              className="object-cover transition-transform duration-300 group-hover:scale-105"
              sizes={sizes}
              unoptimized
            />
          ) : (
            <div className="flex size-full items-center justify-center text-muted">
              <History className="size-8" aria-hidden="true" />
            </div>
          )}
        </Link>
        {/* How far through the chapter, along the bottom edge. A number would
            compete with the title; a line does not. */}
        {progress != null ? (
          <div className="pointer-events-none absolute inset-x-0 bottom-0 h-1 bg-black/40">
            <div className="h-full bg-primary" style={{ width: `${progress}%` }} />
          </div>
        ) : null}
        <ContinueControl entry={entry} isNovel={isNovel} title={title} />
      </div>
      <Link
        href={seriesHref}
        className={cn(
          "mt-2 line-clamp-2 text-sm font-medium leading-snug hover:text-primary",
          entry.series_title?.trim() ? "text-fg" : "text-muted",
        )}
      >
        {title}
      </Link>
      <p className="mt-0.5 truncate text-xs text-muted">{subtitle}</p>
    </article>
  );
}

const CONTINUE_CLASS =
  "absolute bottom-2 right-2 inline-flex items-center gap-1 rounded-full bg-black/60 px-2.5 py-1 text-xs font-medium text-white backdrop-blur-sm transition-colors hover:bg-primary hover:text-primary-fg disabled:opacity-60 [@media(pointer:coarse)]:min-h-11 [@media(pointer:coarse)]:px-3.5";

/**
 * Continue, by the one rule `historyResumePoint` states: an unfinished chapter
 * reopens at its stored position, a finished one moves on to the next chapter.
 *
 * An unfinished row is a plain link — its target is known from the row alone.
 * A finished row needs the chapter list to name the next chapter, so it is a
 * button that fetches the list on press (through the same query key the series
 * page uses, so the book's page opens warm afterwards) and falls back to the
 * book's page when there is no next chapter or the list cannot be had.
 */
function ContinueControl({
  entry,
  isNovel,
  title,
}: {
  entry: ReadingHistoryItem;
  isNovel: boolean;
  title: string;
}) {
  const chapterHref = useChapterHref();
  const queryClient = useQueryClient();
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const series = { sourceId: entry.source_id, seriesKey: entry.series_key };

  if (!entry.is_completed) {
    const point = historyResumePoint(entry);
    // Mid-chapter rows always resolve; the guard only satisfies the type.
    if (point == null) return null;
    return (
      <Link
        href={chapterHref({ ...series, chapterKey: point.chapterKey }, point.page)}
        aria-label={`Continue ${title}`}
        className={CONTINUE_CLASS}
      >
        <Play className="size-3.5" aria-hidden="true" />
        {/* A novel has no pages: its position is a progress bucket, so it
            reads back as a percentage. */}
        {isNovel
          ? `${chapterPercent(entry.last_page, entry.page_count)}%`
          : `p. ${entry.last_page}`}
      </Link>
    );
  }

  const openNext = async () => {
    setPending(true);
    let chapters: Awaited<ReturnType<typeof sourcesApi.getChapters>> = [];
    try {
      chapters = await queryClient.fetchQuery({
        queryKey: sourceChaptersQueryKey(entry.source_id, entry.series_key),
        queryFn: () => sourcesApi.getChapters(entry.source_id, entry.series_key),
      });
    } catch {
      // The book's page below lists every chapter and says why it cannot.
    }
    const point = historyResumePoint(entry, chapters);
    router.push(
      point == null
        ? seriesPageHref(series)
        : chapterHref({ ...series, chapterKey: point.chapterKey }, point.page),
    );
  };

  return (
    <button
      type="button"
      onClick={() => void openNext()}
      disabled={pending}
      aria-busy={pending}
      aria-label={`Continue ${title} from the next chapter`}
      className={CONTINUE_CLASS}
    >
      <Play className="size-3.5" aria-hidden="true" />
      Next
    </button>
  );
}
