"use client";

import Link from "next/link";
import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useState } from "react";
import { BookX, CloudDownload, TriangleAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { OfflineState } from "@/components/ui/offline-state";
import { PrimaryPillButton } from "@/components/premium/PrimaryPillButton";
import {
  followKey,
  useFollow,
  useFollowedIndex,
  useUnfollow,
} from "@/features/library/hooks";
import { seriesContinue } from "@/features/library/history-continue";
import { useSeriesProgress } from "@/features/reader/hooks";
import { sourceImageUrl } from "@/features/sources/api";
import { resolveChapterListState } from "@/features/sources/chapter-list-state";
import { useSourceChapters, useSourceSeriesDetail } from "@/features/sources/hooks";
import { resolveSeriesProgress } from "@/features/sources/series-progress";
import { useSourceSeriesProgress } from "@/features/sources/source-progress";
import { cn } from "@/lib/cn";
import { apiErrorMessage, resolveViewState } from "@/lib/view-state";
import { ApiError } from "@/types/api";
import {
  ChapterCheckbox,
  ChapterDownloadBar,
  ChapterDownloadTrigger,
  SavedChapterMark,
  useChapterPicker,
  type ChapterDownloadState,
} from "@/features/offline";
// Direct rather than through the barrel: the savers pull in the reader API and
// the novels hooks, and the barrel is what the reader itself imports.
import { useNovelChapterSaver } from "@/features/offline/chapter-savers";
import {
  byline,
  estimateSeriesLength,
  formatChapterCount,
  formatEstimatedTotal,
  formatEstimatedWords,
  tocEntry,
} from "../book";
import { prefetchNovelChapterWindow, useCachedNovelWordCounts } from "../hooks";
import { novelChapterHref } from "../novel-link";
import { chapterPercent } from "../progress";
import { formatChapterLength } from "../reading-time";
import { coverPath, formatStatus, shelfBlurb, shelfGenres } from "../shelf";
import { BookPlate } from "./BookPlate";

interface NovelSeriesDetailViewProps {
  sourceId: string;
  seriesId: string;
}

/**
 * How many chapters' text to warm on arrival.
 *
 * Two purposes at once: "Start reading" opens instantly, and the whole-book
 * length estimate gets a sample to project from — there is no bulk word-count
 * endpoint, so measured chapters are the only real numbers available. Kept
 * small because each one is a live fetch against the source.
 */
const PREFETCH_CHAPTERS = 3;

/**
 * Chapters rendered before the list asks to be expanded.
 *
 * A novel aggregator will happily list two thousand chapters, and two thousand
 * table-of-contents rows is a second of layout the reader did not ask for. The
 * cap is explicit and says what it is hiding.
 */
const VISIBLE_CHAPTERS = 400;

/**
 * The front-matter plate: `w-[9rem]` (144px), `w-[10.5rem]` (168px) from `sm`.
 * Both a `sizes` hint and the width the cover proxy renders to
 * (`lib/cover-url.ts`).
 */
const FRONT_MATTER_PLATE_SIZES = "(max-width: 639px) 144px, 168px";

type ChapterSortOrder = "newest" | "oldest";

/**
 * A book's front matter, and its table of contents.
 *
 * The manga series page is a poster with a download-style chapter list beside
 * it. This is the other thing: the title and byline set editorially, the blurb
 * in serif at a readable measure, genres as quiet marks rather than chips, and
 * the chapters as a numbered contents table with lengths and reading estimates
 * — the two facts a reader actually weighs before opening one.
 */
export function NovelSeriesDetailView({
  sourceId,
  seriesId,
}: NovelSeriesDetailViewProps) {
  const seriesQuery = useSourceSeriesDetail(sourceId, seriesId);
  const chaptersQuery = useSourceChapters(sourceId, seriesId);
  const queryClient = useQueryClient();

  const followedIndex = useFollowedIndex();
  const followedId =
    followedIndex.index.get(followKey({ sourceId, seriesKey: seriesId })) ?? null;
  const followMutation = useFollow();
  const unfollowMutation = useUnfollow();
  const [feedback, setFeedback] = useState<string | null>(null);
  const [sortOrder, setSortOrder] = useState<ChapterSortOrder>("oldest");
  const [showAll, setShowAll] = useState(false);

  // Reading position is server-owned; the local store only still carries
  // positions adopted from a pre-scoping device. See `series-progress.ts`.
  const localProgress = useSourceSeriesProgress(sourceId, seriesId);
  const seriesProgressQuery = useSeriesProgress({ sourceId, seriesKey: seriesId });
  const { map: progressMap } = useMemo(
    () =>
      resolveSeriesProgress({
        serverRows: seriesProgressQuery.data ?? [],
        localMap: localProgress.map,
      }),
    [seriesProgressQuery.data, localProgress.map],
  );

  const series = seriesQuery.data;
  const chapters = useMemo(() => chaptersQuery.data ?? [], [chaptersQuery.data]);

  /**
   * Reading order, oldest first — a book's contents run forwards. The toggle
   * is still there because a reader following an ongoing serial wants the
   * newest chapter at the top, which is why the manga page defaults that way.
   */
  const orderedChapters = useMemo(() => {
    const copy = [...chapters];
    copy.sort((a, b) => {
      if (a.number == null && b.number == null) return 0;
      if (a.number == null) return 1; // nulls always last
      if (b.number == null) return -1;
      return sortOrder === "newest" ? b.number - a.number : a.number - b.number;
    });
    return copy;
  }, [chapters, sortOrder]);

  // The one Continue rule: the chapter the reader got furthest in, or the one
  // after it once that is finished — see `seriesContinue`.
  const continueTo = useMemo(
    () => seriesContinue(chapters, progressMap),
    [chapters, progressMap],
  );

  // Warm the opening chapters: "Start reading" becomes instant, and the length
  // estimate below gets its sample.
  //
  // As ONE window rather than a chapter at a time. Three simultaneous
  // `GET /novels/chapter` calls are three trips through the `sources` rate
  // limit — the bucket the reader's own chapter fetch shares — so arriving on
  // a book could spend the reader's budget before they opened anything.
  // `POST /novels/chapters` is one call on the `bulk` bucket for the same
  // three chapters, and it fans the cache misses out server-side.
  useEffect(() => {
    const opening = [...chapters]
      .sort((a, b) => (a.number ?? Number.MAX_SAFE_INTEGER) - (b.number ?? Number.MAX_SAFE_INTEGER))
      .slice(0, PREFETCH_CHAPTERS)
      .map((chapter) => chapter.id);
    void prefetchNovelChapterWindow(queryClient, { sourceId, seriesKey: seriesId }, opening);
  }, [chapters, queryClient, seriesId, sourceId]);

  /**
   * Downloading a book — the owner's "add download whole series for novels too".
   *
   * A prose chapter is one JSON GET, so a whole book is a few megabytes of text
   * where the same count of manga chapters is gigabytes of page images. That is
   * why the whole-series helper exists here and not on the manga page, and why
   * "Download book" is a headline action rather than something buried in a
   * selection mode.
   *
   * Nothing new is stored: `buildNovelSaveRequest` produces the same
   * `SaveChapterRequest` the reader's own download sends, with no images and
   * the chapter endpoint as its payload, so the same cache, the same quota
   * reserve and the same retention rules apply. `sw-policy.js` already
   * classifies `/novels/chapter` network-then-saved, which is the rule prose
   * wants: the live copy whenever there is one, the stored copy when the fetch
   * fails.
   */
  const chapterTitles = useMemo(() => {
    const titles = new Map<string, string>();
    for (const chapter of chapters) {
      titles.set(
        chapter.id,
        chapter.title?.trim() ||
          (chapter.number != null ? `Chapter ${chapter.number}` : chapter.id),
      );
    }
    return titles;
  }, [chapters]);

  // Display order, not listing order: shift-click ranges over the rows as they
  // are on screen, and the contents can be flipped last-to-first.
  const pickerRows = useMemo(
    () =>
      orderedChapters.map((chapter) => ({
        key: chapter.id,
        number: chapter.number,
        read: progressMap[chapter.id]?.completed ?? false,
      })),
    [orderedChapters, progressMap],
  );

  const titleOf = useCallback(
    (chapterKey: string) => chapterTitles.get(chapterKey) ?? chapterKey,
    [chapterTitles],
  );
  const saver = useNovelChapterSaver({
    sourceId,
    seriesKey: seriesId,
    seriesTitle: series?.title ?? null,
    titleOf,
  });

  const picker = useChapterPicker({
    sourceId,
    seriesKey: seriesId,
    chapters: pickerRows,
    buildRequest: saver.buildRequest,
    prepare: saver.prepare,
    medium: "novel",
  });

  const wordCounts = useCachedNovelWordCounts(
    series ? { sourceId, seriesKey: seriesId } : null,
  );
  const lengthEstimate = useMemo(
    () => estimateSeriesLength(series?.chapter_count ?? chapters.length, wordCounts.values()),
    [series?.chapter_count, chapters.length, wordCounts],
  );

  const chapterListState = resolveChapterListState({
    isLoading: chaptersQuery.isLoading,
    error: chaptersQuery.error,
    chapterCount: chapters.length,
    reportedChapterCount: series?.chapter_count ?? 0,
  });

  const seriesViewState = resolveViewState({
    isLoading: seriesQuery.isLoading,
    error: seriesQuery.error,
    isEmpty: !series,
  });

  if (seriesViewState === "loading") {
    return <FrontMatterSkeleton />;
  }

  if (seriesViewState === "offline") {
    return (
      <div className="p-6">
        <OfflineState
          reason="This book needs a connection to load."
          onRetry={() => void seriesQuery.refetch()}
        />
      </div>
    );
  }

  if (seriesViewState !== "content" || !series) {
    return (
      <div className="p-6">
        <EmptyState
          tone="error"
          icon={TriangleAlert}
          title="Couldn't load this book"
          description={apiErrorMessage(seriesQuery.error, "The source did not answer.")}
          action={{ label: "Try again", onClick: () => void seriesQuery.refetch() }}
          secondaryAction={{ label: "Back to source", href: `/sources/${sourceId}` }}
        />
      </div>
    );
  }

  const primaryHref =
    continueTo && continueTo.kind !== "caught-up"
      ? novelChapterHref(
          { sourceId, seriesKey: seriesId, chapterKey: continueTo.point.chapterKey },
          continueTo.point.page,
        )
      : null;
  const primaryLabel = continueTo?.kind === "start" ? "Start reading" : "Continue reading";

  const toggleFollow = async () => {
    setFeedback(null);
    try {
      if (followedId !== null) {
        await unfollowMutation.mutateAsync(followedId);
        setFeedback(`Removed ${series.title} from your library.`);
      } else {
        await followMutation.mutateAsync({ sourceId, seriesKey: seriesId });
        setFeedback(`Added ${series.title} to your library. New chapters will notify you.`);
      }
    } catch (error) {
      setFeedback(
        error instanceof ApiError ? error.message : "Failed to update your library.",
      );
    }
  };

  const followBusy = followMutation.isPending || unfollowMutation.isPending;
  const isFollowed = followedId !== null;

  const author = byline(series.author);
  const blurb = shelfBlurb(series.description);
  const genres = shelfGenres(series.genres, 24);
  const status = formatStatus(series.status);
  const chapterCount = formatChapterCount(series.chapter_count || chapters.length);
  const estimatedWords = formatEstimatedWords(lengthEstimate);
  const estimatedTime = formatEstimatedTotal(lengthEstimate);

  const visibleChapters =
    showAll || orderedChapters.length <= VISIBLE_CHAPTERS
      ? orderedChapters
      : orderedChapters.slice(0, VISIBLE_CHAPTERS);

  return (
    <div className="p-6">
      <div className="mx-auto max-w-4xl">
        <Link
          href={`/sources/${sourceId}`}
          className="text-sm text-muted transition-colors hover:text-fg"
        >
          ← Back to source
        </Link>

        {/* --- Front matter --- */}
        <div className="mt-6 flex flex-col gap-8 sm:flex-row-reverse sm:items-start sm:gap-10">
          <BookPlate
            coverUrl={
              coverPath(series.cover_url)
                ? sourceImageUrl(series.cover_url, FRONT_MATTER_PLATE_SIZES)
                : null
            }
            title={series.title}
            alt={series.title}
            className="h-[13rem] w-[9rem] sm:h-[15.5rem] sm:w-[10.5rem]"
            sizes={FRONT_MATTER_PLATE_SIZES}
          />

          <div className="min-w-0 flex-1">
            <h1 className="font-book text-[2rem] font-normal leading-[1.15] text-fg sm:text-[2.5rem]">
              {series.title}
            </h1>
            {author ? (
              <p className="mt-3 font-book text-lg italic text-muted">{author}</p>
            ) : null}

            <div className="mt-6 h-px w-14 bg-border" aria-hidden />

            {/* A plain list, not a `<dl>`: these are four facts of the same
                kind, not term/definition pairs, and a `<dl>` of bare `<dd>`s
                would be invalid markup a screen reader has to guess at. */}
            <ul className="mt-5 flex flex-wrap items-baseline gap-x-5 gap-y-1.5 text-sm text-fg/80">
              {[chapterCount, estimatedWords, estimatedTime, status]
                .filter((fact): fact is string => Boolean(fact))
                .map((fact) => (
                  <li key={fact}>{fact}</li>
                ))}
            </ul>
            {lengthEstimate.minutes != null ? (
              <p className="mt-1.5 text-xs text-muted/80">
                Length estimated from {lengthEstimate.sampleSize}{" "}
                {lengthEstimate.sampleSize === 1 ? "chapter" : "chapters"} read so far.
              </p>
            ) : null}

            {genres.length > 0 ? (
              <p className="mt-5 flex flex-wrap gap-x-3 gap-y-1 text-xs uppercase tracking-[0.16em] text-muted">
                {genres.map((genre) => (
                  <Link
                    key={genre}
                    href={`/sources/${encodeURIComponent(sourceId)}?genre=${encodeURIComponent(genre)}`}
                    className="transition-colors hover:text-primary"
                  >
                    {genre}
                  </Link>
                ))}
              </p>
            ) : null}

            {blurb ? (
              <p className="mt-6 max-w-[62ch] font-book text-[1.0625rem] leading-[1.75] text-fg/85">
                {blurb}
              </p>
            ) : null}

            <div className="mt-8 flex flex-wrap items-center gap-3">
              {primaryHref ? (
                <PrimaryPillButton href={primaryHref}>{primaryLabel}</PrimaryPillButton>
              ) : continueTo?.kind === "caught-up" ? (
                // Everything up to the last chapter is read. Continue's answer
                // everywhere else is "the book's page" — this page — so it has
                // nowhere to send the reader and says why instead.
                <PrimaryPillButton disabled>All caught up</PrimaryPillButton>
              ) : null}
              <Button
                variant={isFollowed ? "ghost" : "secondary"}
                disabled={followBusy}
                onClick={toggleFollow}
              >
                {followBusy
                  ? isFollowed
                    ? "Removing…"
                    : "Adding…"
                  : isFollowed
                    ? "In your library"
                    : "Add to library"}
              </Button>
              {/* The whole book, in one action. Hidden once there is nothing
                  left to fetch rather than shown disabled: "0 chapters" is not
                  a state worth a button. */}
              {!picker.downloads.unavailable &&
              picker.unsaved.length > 0 &&
              !picker.downloads.running ? (
                <Button
                  variant="ghost"
                  disabled={!picker.downloads.scope}
                  onClick={() => picker.startKeys(picker.unsaved)}
                >
                  <CloudDownload className="size-4" aria-hidden />
                  Download book
                  <span className="ml-1 font-mono text-xs tabular-nums text-muted">
                    {picker.unsaved.length}
                  </span>
                </Button>
              ) : null}
            </div>
            {feedback ? <p className="mt-3 text-sm text-muted">{feedback}</p> : null}
          </div>
        </div>

        {/* --- Table of contents --- */}
        <section className="mt-14">
          <div className="flex flex-wrap items-baseline justify-between gap-3 border-b border-border pb-3">
            <h2 className="font-book text-xl text-fg">Contents</h2>
            {chapters.length > 0 && !picker.selecting ? (
              <ChapterDownloadTrigger picker={picker} label="Pick chapters" />
            ) : null}
            {chapters.length > 1 ? (
              <div className="flex items-center gap-3 text-xs">
                {(["oldest", "newest"] as const).map((order) => (
                  <button
                    key={order}
                    type="button"
                    onClick={() => setSortOrder(order)}
                    aria-pressed={sortOrder === order}
                    className={cn(
                      "uppercase tracking-[0.16em] transition-colors",
                      sortOrder === order
                        ? "text-fg"
                        : "text-muted hover:text-fg",
                    )}
                  >
                    {order === "oldest" ? "First → last" : "Last → first"}
                  </button>
                ))}
              </div>
            ) : null}
          </div>

          {chapterListState === "loading" ? (
            <TocSkeleton />
          ) : chapterListState === "offline" ? (
            <div className="pt-6">
              <OfflineState
                reason="The contents need a connection to load."
                onRetry={() => void chaptersQuery.refetch()}
              />
            </div>
          ) : chapterListState === "error" ? (
            <div className="pt-6">
              <EmptyState
                tone="error"
                icon={TriangleAlert}
                title="Couldn't load the contents"
                description={apiErrorMessage(
                  chaptersQuery.error,
                  "The source did not answer.",
                )}
                action={{ label: "Try again", onClick: () => void chaptersQuery.refetch() }}
              />
            </div>
          ) : chapterListState === "unavailable" ? (
            <div className="pt-6">
              <EmptyState
                tone="error"
                icon={TriangleAlert}
                title="Contents didn't come through"
                description={`This source lists ${series.chapter_count.toLocaleString()} chapters for this book but returned none just now — usually the source, not you.`}
                action={{ label: "Try again", onClick: () => void chaptersQuery.refetch() }}
              />
            </div>
          ) : chapterListState === "empty" ? (
            <div className="pt-6">
              <EmptyState
                icon={BookX}
                title="No chapters yet"
                description="This source has not published any chapters for this book."
                action={{ label: "Back to source", href: `/sources/${sourceId}` }}
              />
            </div>
          ) : (
            <>
              <ol className="divide-y divide-border/60">
                {visibleChapters.map((chapter) => (
                  <TocRow
                    key={chapter.id}
                    href={novelChapterHref({
                      sourceId,
                      seriesKey: seriesId,
                      chapterKey: chapter.id,
                    })}
                    entry={tocEntry(chapter)}
                    wordCount={wordCounts.get(chapter.id) ?? null}
                    progress={progressMap[chapter.id] ?? null}
                    download={picker.stateOf(chapter.id)}
                    selecting={picker.selecting}
                    selected={picker.isSelected(chapter.id)}
                    onPick={(shift) => picker.pick(chapter.id, shift)}
                  />
                ))}
              </ol>
              {visibleChapters.length < orderedChapters.length ? (
                <div className="pt-6 text-center">
                  <Button variant="secondary" onClick={() => setShowAll(true)}>
                    Show all {orderedChapters.length.toLocaleString()} chapters
                  </Button>
                </div>
              ) : null}
            </>
          )}
          {picker.selecting || picker.downloads.running || picker.downloads.summary ? (
            <ChapterDownloadBar picker={picker} className="mt-4" />
          ) : null}
        </section>
      </div>
    </div>
  );
}

/** One line of the contents: number, title, and how long it is. */
function TocRow({
  href,
  entry,
  wordCount,
  progress,
  download,
  selecting,
  selected,
  onPick,
}: {
  href: string;
  entry: { ordinal: string | null; title: string | null };
  wordCount: number | null;
  progress: { page: number; pageCount: number; completed: boolean } | null;
  download: ChapterDownloadState;
  selecting: boolean;
  selected: boolean;
  onPick: (shift: boolean) => void;
}) {
  const length = formatChapterLength(wordCount);
  const completed = progress?.completed ?? false;
  const reading = progress != null && !completed;
  const percent =
    reading && progress.pageCount > 0
      ? chapterPercent(progress.page, progress.pageCount)
      : null;

  return (
    <li>
      <Link
        href={href}
        // While the contents are in selection mode the row ticks rather than
        // opens. The whole line stays the hit area either way — a 20px checkbox
        // beside a full-width row would make choosing forty chapters harder
        // than opening one.
        onClick={(event) => {
          if (!selecting) return;
          event.preventDefault();
          onPick(event.shiftKey);
        }}
        aria-pressed={selecting ? selected : undefined}
        className={cn(
          "group flex items-baseline gap-4 py-3 transition-colors hover:bg-fg/[0.03] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50",
          selecting && selected && "bg-primary/10",
        )}
      >
        {selecting ? (
          <ChapterCheckbox checked={selected} disabled={download === "saved"} />
        ) : null}
        <span
          className={cn(
            "w-10 shrink-0 text-right font-book text-sm tabular-nums",
            completed ? "text-muted/60" : "text-muted",
          )}
          aria-hidden={entry.ordinal === null}
        >
          {entry.ordinal ?? "·"}
        </span>
        <span
          className={cn(
            "min-w-0 flex-1 font-book text-[0.975rem] leading-snug transition-colors group-hover:text-primary",
            completed ? "text-fg/45" : "text-fg",
          )}
        >
          {entry.title ?? (entry.ordinal ? `Chapter ${entry.ordinal}` : "Chapter")}
        </span>
        <SavedChapterMark state={download} className="self-center" />
        <span className="shrink-0 text-right text-xs">
          {percent != null ? (
            <span className="block tabular-nums text-primary">{percent}%</span>
          ) : completed ? (
            <span className="block text-muted/70">Read</span>
          ) : null}
          {length ? <span className="block text-muted">{length}</span> : null}
        </span>
      </Link>
    </li>
  );
}

function FrontMatterSkeleton() {
  return (
    <div className="p-6" aria-busy="true" aria-label="Loading book">
      <div className="mx-auto max-w-4xl">
        <div className="mt-6 flex flex-col gap-8 sm:flex-row-reverse sm:items-start sm:gap-10">
          <div className="h-[13rem] w-[9rem] shrink-0 animate-pulse rounded-sm bg-surface-2 sm:h-[15.5rem] sm:w-[10.5rem]" />
          <div className="min-w-0 flex-1 space-y-4">
            <div className="h-10 w-3/4 animate-pulse rounded bg-surface-2" />
            <div className="h-5 w-1/3 animate-pulse rounded bg-surface-2" />
            <div className="h-px w-14 bg-border" />
            <div className="h-4 w-1/2 animate-pulse rounded bg-surface-2" />
            <div className="space-y-2 pt-4">
              <div className="h-4 w-full animate-pulse rounded bg-surface-2" />
              <div className="h-4 w-full animate-pulse rounded bg-surface-2" />
              <div className="h-4 w-2/3 animate-pulse rounded bg-surface-2" />
            </div>
          </div>
        </div>
        <div className="mt-14">
          <div className="h-6 w-32 animate-pulse rounded bg-surface-2" />
          <TocSkeleton />
        </div>
      </div>
    </div>
  );
}

function TocSkeleton() {
  return (
    <div className="divide-y divide-border/60" aria-busy="true">
      {Array.from({ length: 10 }).map((_, index) => (
        <div key={index} className="flex items-center gap-4 py-3">
          <div className="h-3 w-10 shrink-0 animate-pulse rounded bg-surface-2" />
          <div className="h-3 flex-1 animate-pulse rounded bg-surface-2" />
          <div className="h-3 w-24 shrink-0 animate-pulse rounded bg-surface-2" />
        </div>
      ))}
    </div>
  );
}
