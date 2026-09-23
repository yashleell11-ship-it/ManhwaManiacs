"use client";

import Link from "next/link";
import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useState } from "react";
import { BookX, TriangleAlert } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { EmptyState } from "@/components/ui/empty-state";
import { OfflineState } from "@/components/ui/offline-state";
import { GhostPillButton } from "@/components/premium/GhostPillButton";
import { PrimaryPillButton } from "@/components/premium/PrimaryPillButton";
import { browserAllowsPreload } from "@/features/reader/preload";
import { readAllHref } from "@/features/reader/reader-link";
import {
  ChapterCheckbox,
  ChapterDownloadBar,
  ChapterDownloadTrigger,
  SavedChapterMark,
  useChapterPicker,
} from "@/features/offline";
// Direct rather than through the barrel: the savers pull in the reader API and
// the novels hooks, and the barrel is what the reader itself imports.
import { useMangaChapterSaver } from "@/features/offline/chapter-savers";
import {
  followKey,
  useFollow,
  useFollowedIndex,
  useUnfollow,
} from "@/features/library/hooks";
import { useSeriesProgress } from "@/features/reader/hooks";
// Imported directly rather than through the `@/features/novels` barrel: the
// barrel also pulls in the novel reader, and a manga series page has no reason
// to carry it.
import { useIsNovelSource } from "@/features/novels/hooks";
import { NovelSeriesDetailView } from "@/features/novels/components/NovelSeriesDetailView";
import { ApiError } from "@/types/api";
import { apiErrorMessage, resolveViewState } from "@/lib/view-state";
import { cn } from "@/lib/cn";
import { createHoverIntent } from "@/lib/hover-intent";
import { sourceImageUrl } from "../api";
import { chapterLabel } from "../chapter-label";
import { resolveChapterListState } from "../chapter-list-state";
import {
  prefetchSourceReaderChapter,
  sourceReaderChapterPath,
  useSourceChapters,
  useSourceSeriesDetail,
} from "../hooks";
import { seriesContinue } from "@/features/library/history-continue";
import { resolveSeriesProgress } from "../series-progress";
import { useSourceSeriesProgress } from "../source-progress";
import {
  ChapterRowsSkeleton,
  SourceSeriesDetailSkeleton,
} from "./SourceSeriesDetailSkeleton";
import { CoverImage } from "@/components/ui/cover-image";
import { chapterDateLabel, chapterUploadedAt } from "../chapter-date";

/**
 * The poster: capped at `max-w-[200px]` below `lg`, then the 220px grid column.
 * Both the browser's `sizes` hint and the width the cover proxy renders to
 * (`lib/cover-url.ts`).
 */
const POSTER_SIZES = "(max-width: 1023px) 200px, 220px";


type ChapterSortOrder = "newest" | "oldest";

interface SourceSeriesDetailViewProps {
  sourceId: string;
  seriesId: string;
  /** A chapter to open the contents at; only a book's page uses it. */
  focusChapterKey?: string | null;
}

/**
 * One series page, in whichever medium its source serves.
 *
 * The route is shared on purpose: every link into a series — search, updates,
 * the library, a bookmark — points here, and none of them should have to know
 * that two kinds of series page exist. The branch happens once, here.
 *
 * `undefined` means the sources listing has not answered yet, so neither page
 * can be chosen. That renders the skeleton, which is what this screen renders
 * for its own loading state a frame later anyway.
 */
export function SourceSeriesDetailView(props: SourceSeriesDetailViewProps) {
  const isNovel = useIsNovelSource(props.sourceId);
  if (isNovel === undefined) return <SourceSeriesDetailSkeleton />;
  return isNovel ? (
    <NovelSeriesDetailView {...props} />
  ) : (
    <MangaSeriesDetailView {...props} />
  );
}

function MangaSeriesDetailView({
  sourceId,
  seriesId,
}: SourceSeriesDetailViewProps) {
  const seriesQuery = useSourceSeriesDetail(sourceId, seriesId);
  const chaptersQuery = useSourceChapters(sourceId, seriesId);
  const followedIndex = useFollowedIndex();
  const followedId =
    followedIndex.index.get(followKey({ sourceId, seriesKey: seriesId })) ??
    null;
  const followMutation = useFollow();
  const unfollowMutation = useUnfollow();
  const queryClient = useQueryClient();
  const [feedback, setFeedback] = useState<string | null>(null);
  const [sortOrder, setSortOrder] = useState<ChapterSortOrder>("newest");
  // Reading position is server-owned (`POST /reader/progress`); the local store
  // only still carries positions adopted from a pre-scoping device. Reading the
  // local store alone is what left every chapter looking unread — see
  // `series-progress.ts`.
  const localProgress = useSourceSeriesProgress(sourceId, seriesId);
  const seriesProgressQuery = useSeriesProgress({
    sourceId,
    seriesKey: seriesId,
  });
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
  // The one Continue rule — see `seriesContinue`.
  const continueTo = useMemo(
    () => seriesContinue(chapters, progressMap),
    [chapters, progressMap],
  );

  const sortedChapters = useMemo(() => {
    const copy = [...chapters];
    copy.sort((a, b) => {
      if (a.number == null && b.number == null) return 0;
      if (a.number == null) return 1; // nulls always last
      if (b.number == null) return -1;
      return sortOrder === "newest" ? b.number - a.number : a.number - b.number;
    });
    return copy;
  }, [chapters, sortOrder]);

  // Warm the first few chapters so the most likely next tap is instant. Gated
  // on the same connection rule the reader's own next-chapter preload uses:
  // five speculative chapter payloads — each one a live scrape at the source —
  // fired the moment a series page opened, whether or not the phone was on
  // cellular or in data-saver, and competed with the covers and the chapter
  // list for the same connection.
  useEffect(() => {
    if (!browserAllowsPreload()) return;
    for (const chapter of chapters.slice(0, 5)) {
      prefetchSourceReaderChapter(queryClient, sourceId, seriesId, chapter.id);
    }
  }, [chapters, queryClient, seriesId, sourceId]);

  /**
   * Hover/focus prefetch, gated on the pointer actually settling. A `mouseenter`
   * per row meant one chapter fetch per row crossed — sweeping down a long
   * chapter list fired dozens in a second. See `lib/hover-intent.ts`.
   */
  const prefetchChapterPayload = useCallback(
    (chapterId: string) => {
      prefetchSourceReaderChapter(queryClient, sourceId, seriesId, chapterId);
    },
    [queryClient, seriesId, sourceId],
  );
  const hoverIntent = useMemo(
    () => createHoverIntent<string>(prefetchChapterPayload),
    [prefetchChapterPayload],
  );
  useEffect(() => () => hoverIntent.dispose(), [hoverIntent]);

  /**
   * Multi-select downloading, from the list rather than from inside the reader.
   *
   * Until now the only download button on the web lived in `ChapterReader`, so
   * saving ten chapters meant opening ten chapters — and a series page could
   * not say which of them were already on the device. The rows below now read
   * that off the service worker's index, and the bar at the foot of the list
   * stores a whole selection in one action.
   *
   * There is no whole-series helper here, unlike a book: three hundred
   * chapters of page images is gigabytes, and the bounded helpers are the
   * honest offer. `chapter-savers.ts` holds what a manga chapter costs to
   * store and how a window of them is warmed.
   */
  // Display order, not listing order: shift-click ranges over the rows as they
  // are on screen, and this list sorts newest-first by default.
  const pickerRows = useMemo(
    () =>
      sortedChapters.map((chapter) => ({
        key: chapter.id,
        number: chapter.number,
        read: progressMap[chapter.id]?.completed ?? false,
      })),
    [progressMap, sortedChapters],
  );

  const saver = useMangaChapterSaver({
    sourceId,
    seriesKey: seriesId,
    seriesTitle: series?.title ?? null,
  });

  const picker = useChapterPicker({
    sourceId,
    seriesKey: seriesId,
    chapters: pickerRows,
    buildRequest: saver.buildRequest,
    prepare: saver.prepare,
    medium: "manga",
  });

  // An empty answer means something different depending on what the series
  // summary claims the source holds — see `resolveChapterListState`.
  const chapterListState = resolveChapterListState({
    isLoading: chaptersQuery.isLoading,
    error: chaptersQuery.error,
    chapterCount: chapters.length,
    reportedChapterCount: series?.chapter_count ?? 0,
  });

  const seriesViewState = resolveViewState({
    isLoading: seriesQuery.isLoading,
    error: seriesQuery.error,
    // A resolved request with no payload is a failure to load, not an empty
    // series — every branch below needs `series` to render anything at all.
    isEmpty: !series,
  });

  if (seriesViewState === "loading") {
    return <SourceSeriesDetailSkeleton />;
  }

  if (seriesViewState === "offline") {
    return (
      <div className="p-6">
        <OfflineState
          reason="This series page needs a connection to load."
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
          title="Couldn't load this series"
          description={apiErrorMessage(seriesQuery.error, "The source did not answer.")}
          action={{ label: "Try again", onClick: () => void seriesQuery.refetch() }}
          secondaryAction={{ label: "Back to source", href: `/sources/${sourceId}` }}
        />
      </div>
    );
  }

  // "Continue" opens the chapter the reader got furthest in, at its saved
  // page, or the one after it once that is finished; "Read Online" starts
  // from the first chapter. Caught up, there is nothing to open.
  const primaryPoint =
    continueTo && continueTo.kind !== "caught-up" ? continueTo.point : null;
  const primaryChapterId = primaryPoint?.chapterKey ?? null;
  const primaryHref = primaryPoint
    ? `${sourceReaderChapterPath(sourceId, seriesId, primaryPoint.chapterKey)}${
        primaryPoint.page > 1 ? `?page=${primaryPoint.page}` : ""
      }`
    : null;
  const primaryLabel = continueTo?.kind === "start" ? "Read Online" : "Continue";
  const caughtUp = continueTo?.kind === "caught-up";

  /**
   * Read all (spec 2026-09-05 R2): the whole series as one continuous scroll.
   *
   * Beside "Read online", never instead of it — they are different intentions,
   * and a run through thirty chapters is a thing you choose rather than a mode
   * you have to go and find. It starts where the reader left off for the same
   * reason "Continue" does: forty chapters in, nobody means chapter one. There
   * is nothing to read THROUGH in a single-chapter series, so it stays hidden
   * until there are at least two.
   */
  const readAllTarget =
    chapters.length > 1
      ? readAllHref({ sourceId, seriesKey: seriesId }, primaryChapterId)
      : null;

  const prefetchChapter = prefetchChapterPayload;

  const toggleFollow = async () => {
    setFeedback(null);
    try {
      if (followedId !== null) {
        await unfollowMutation.mutateAsync(followedId);
        setFeedback(`Unfollowed ${series.title}.`);
      } else {
        await followMutation.mutateAsync({ sourceId, seriesKey: seriesId });
        setFeedback(`Following ${series.title}. New chapters will notify you.`);
      }
    } catch (error) {
      setFeedback(error instanceof ApiError ? error.message : "Failed to update follow status.");
    }
  };

  const followBusy = followMutation.isPending || unfollowMutation.isPending;
  const isFollowed = followedId !== null;

  return (
    <div className="p-6">
      <div className="mb-6">
        {/* 110x18 as a bare inline link — the way back off this screen should
            not be the hardest thing on it to hit. Height on touch only. */}
        <Link
          href={`/sources/${sourceId}`}
          className="-ml-2 inline-flex items-center px-2 text-sm text-muted hover:text-fg [@media(pointer:coarse)]:min-h-11"
        >
          ← Back to source
        </Link>
      </div>

      <div className="grid gap-6 lg:grid-cols-[220px_1fr]">
        {/* Capped and centred below `lg`, exactly as the library's own series
            page already does it (`SeriesDetailView`). Left uncapped, a 2:3
            cover at the full width of a 375px phone is ~490px tall — the entire
            first screen is the cover, and the title, the buttons and the
            chapter list all start below the fold. */}
        <Card className="mx-auto w-full max-w-[200px] overflow-hidden rounded-3xl lg:mx-0 lg:max-w-none lg:sticky lg:top-24 lg:self-start">
          <div className="relative aspect-[2/3] w-full bg-surface-2">
            <CoverImage
              src={sourceImageUrl(series.cover_url, POSTER_SIZES)}
              alt={series.title}
              fill
              className="object-cover"
              sizes={POSTER_SIZES}
              unoptimized
            />
          </div>
        </Card>

        <div>
          {/* `text-4xl` on a phone gives a long title four lines of display
              face. Same ramp the library's series page uses. */}
          <h1 className="font-display text-3xl leading-tight text-fg md:text-4xl">
            {series.title}
          </h1>
          {series.author && <p className="mt-2 text-muted">Author: {series.author}</p>}
          {series.artist && <p className="mt-1 text-muted">Artist: {series.artist}</p>}
          {series.status && (
            <Badge variant="primary" className="mt-3 capitalize">
              {series.status}
            </Badge>
          )}
          {series.genres.length > 0 && (
            <div className="mt-3 flex flex-wrap gap-2">
              {series.genres.map((genre) => (
                <Link
                  key={genre}
                  href={`/sources/${encodeURIComponent(sourceId)}?genre=${encodeURIComponent(genre)}`}
                  // The badge itself is 24px and there are four of them in a
                  // row. Height goes on the link, not on `Badge`, so the
                  // non-interactive badges elsewhere keep their size.
                  className="inline-flex items-center [@media(pointer:coarse)]:min-h-11"
                >
                  <Badge
                    variant="default"
                    className="cursor-pointer transition-colors hover:border-primary/50 hover:bg-primary/10"
                  >
                    {genre}
                  </Badge>
                </Link>
              ))}
            </div>
          )}
          {series.description && (
            <p className="mt-4 max-w-3xl text-sm leading-6 text-muted">{series.description}</p>
          )}

          <div className="mt-6 flex flex-wrap gap-2">
            {primaryHref && (
              <span
                className="inline-flex"
                onMouseEnter={() => primaryChapterId && prefetchChapter(primaryChapterId)}
                onFocus={() => primaryChapterId && prefetchChapter(primaryChapterId)}
              >
                <PrimaryPillButton href={primaryHref}>{primaryLabel}</PrimaryPillButton>
              </span>
            )}
            {caughtUp && <PrimaryPillButton disabled>All caught up</PrimaryPillButton>}
            {readAllTarget && (
              <span
                className="inline-flex"
                title="Every chapter in one continuous scroll"
              >
                <GhostPillButton href={readAllTarget}>Read all</GhostPillButton>
              </span>
            )}
            <Button
              variant={isFollowed ? "ghost" : "secondary"}
              disabled={followBusy}
              onClick={toggleFollow}
            >
              {followBusy
                ? isFollowed
                  ? "Unfollowing…"
                  : "Following…"
                : isFollowed
                  ? "Unfollow"
                  : "Follow"}
            </Button>
          </div>
          {feedback && <p className="mt-3 text-sm text-muted">{feedback}</p>}
        </div>
      </div>

      <Card className="mt-8">
        <CardHeader className="flex-row flex-wrap items-center justify-between gap-3">
          <CardTitle>Chapters</CardTitle>
          {chapters.length > 0 && !picker.selecting && (
            <ChapterDownloadTrigger picker={picker} />
          )}
          {chapters.length > 1 && (
            <div className="inline-flex overflow-hidden rounded-lg border border-border/50">
              {(["newest", "oldest"] as const).map((order) => (
                <button
                  key={order}
                  type="button"
                  onClick={() => setSortOrder(order)}
                  className={cn(
                    // Two 24px segments; the pair is the only control in the
                    // chapter-list header and a thumb has to land in one.
                    "inline-flex items-center justify-center px-3 py-1 text-xs font-medium capitalize transition-colors",
                    "[@media(pointer:coarse)]:min-h-11 [@media(pointer:coarse)]:px-4",
                    sortOrder === order
                      ? "bg-primary text-primary-fg"
                      : "text-muted hover:bg-white/5 hover:text-fg",
                  )}
                >
                  {order}
                </button>
              ))}
            </div>
          )}
        </CardHeader>
        <CardContent className="divide-y divide-border">
          {chapterListState === "loading" ? (
            <ChapterRowsSkeleton />
          ) : chapterListState === "offline" ? (
            <OfflineState
              reason="The chapter list needs a connection to load."
              onRetry={() => void chaptersQuery.refetch()}
            />
          ) : chapterListState === "error" ? (
            <EmptyState
              tone="error"
              icon={TriangleAlert}
              title="Couldn't load the chapter list"
              description={apiErrorMessage(
                chaptersQuery.error,
                "The source did not answer.",
              )}
              action={{ label: "Try again", onClick: () => void chaptersQuery.refetch() }}
            />
          ) : chapterListState === "unavailable" ? (
            <EmptyState
              tone="error"
              icon={TriangleAlert}
              title="Chapters didn't come through"
              description={`This source lists ${series.chapter_count.toLocaleString()} chapters for this series but returned none just now — usually the source, not you.`}
              action={{ label: "Try again", onClick: () => void chaptersQuery.refetch() }}
            />
          ) : chapterListState === "empty" ? (
            <EmptyState
              icon={BookX}
              title="No chapters yet"
              description="This source has not published any chapters for this series."
              action={{ label: "Back to source", href: `/sources/${sourceId}` }}
            />
          ) : (
            sortedChapters.map((chapter) => {
              const label = chapterLabel(chapter);
              const progress = progressMap[chapter.id] ?? null;
              const completed = progress?.completed ?? false;
              const reading = progress != null && !completed;
              const pageCount = progress?.pageCount || chapter.page_count;
              // When the source says this chapter went up. Serialized as
              // `release_date` on this live listing; the followed-series list
              // normalises the same value to `published_at`.
              const uploaded = chapterDateLabel(chapterUploadedAt(chapter));
              let progressText: string | null;
              if (progress && completed) {
                progressText = pageCount > 0 ? `${pageCount}/${pageCount} pages` : "Read";
              } else if (progress && reading) {
                progressText =
                  pageCount > 0 ? `${progress.page}/${pageCount} pages` : `Page ${progress.page}`;
              } else {
                progressText = pageCount > 0 ? `${pageCount} pages` : null;
              }
              const downloadState = picker.stateOf(chapter.id);
              const picked = picker.isSelected(chapter.id);
              return (
                // The WHOLE row is the link, not the "Read" button at its end.
                // A 90px-tall row whose only target was a 62x32 button meant a
                // thumb aiming at the chapter title hit nothing — the novel
                // side has always linked the whole row (`NovelSeriesDetailView`)
                // and this brings the manga side into line. The button keeps its
                // look as a plain span: it is the affordance, the row is the hit
                // area, and nesting a real button inside a link would be two
                // controls where the reader sees one.
                //
                // In selection mode the same hit area ticks instead of opening.
                // A separate checkbox column would put a 20px target inside a
                // 90px row and make selecting ten chapters harder than opening
                // them, which is the opposite of the point.
                <Link
                  key={chapter.id}
                  href={sourceReaderChapterPath(sourceId, seriesId, chapter.id)}
                  onClick={(event) => {
                    if (!picker.selecting) return;
                    event.preventDefault();
                    picker.pick(chapter.id, event.shiftKey);
                  }}
                  aria-pressed={picker.selecting ? picked : undefined}
                  onMouseEnter={() => hoverIntent.enter(chapter.id)}
                  onMouseLeave={hoverIntent.leave}
                  onFocus={() => hoverIntent.enter(chapter.id)}
                  onBlur={hoverIntent.leave}
                  className={cn(
                    "group flex flex-wrap items-center justify-between gap-3 px-2 py-3 transition-colors first:pt-0 hover:bg-surface-2/60",
                    "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary/60",
                    completed && "bg-void/40",
                    picker.selecting && picked && "bg-primary/10",
                  )}
                >
                  {picker.selecting ? (
                    <ChapterCheckbox checked={picked} disabled={downloadState === "saved"} />
                  ) : null}
                  <div className="min-w-0 flex-1">
                    <div>
                      <p className={cn("font-medium text-fg", completed && "text-fg/50")}>
                        {label.primary}
                      </p>
                      {label.secondary != null && (
                        <p className={cn("text-sm text-fg/80", completed && "text-fg/40")}>
                          {label.secondary}
                        </p>
                      )}
                      {progressText != null && (
                        <p className={cn("text-sm", reading ? "text-primary" : "text-muted")}>
                          {progressText}
                        </p>
                      )}
                      {uploaded != null && (
                        <p className="text-xs text-muted">{uploaded}</p>
                      )}
                    </div>
                  </div>
                  <SavedChapterMark state={downloadState} />
                  {picker.selecting ? null : (
                    <span
                      aria-hidden
                      className="inline-flex h-8 shrink-0 items-center justify-center rounded-lg px-3 text-sm font-medium text-muted transition-colors group-hover:bg-white/5 group-hover:text-fg"
                    >
                      Read
                    </span>
                  )}
                </Link>
              );
            })
          )}
        </CardContent>
        {picker.selecting || picker.downloads.running || picker.downloads.summary ? (
          <div className="px-4 pb-4">
            <ChapterDownloadBar picker={picker} />
          </div>
        ) : null}
      </Card>
    </div>
  );
}
