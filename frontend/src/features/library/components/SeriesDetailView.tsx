"use client";

import Link from "next/link";
import { useCallback, useMemo, useState } from "react";
import { ArrowLeft, BookOpen, Check, ChevronRight, Play, Star } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { GhostPillButton } from "@/components/premium/GhostPillButton";
import { PrimaryPillButton } from "@/components/premium/PrimaryPillButton";
import { libraryCoverUrl } from "@/features/library/api";
import {
  usePatchSeries,
  useSeries,
  useToggleFavorite,
} from "@/features/library/hooks";
// Direct rather than through the `@/features/novels` barrel, which also pulls
// in the novel reader — this page only links into it, it never renders it.
import { useIsNovelSource } from "@/features/novels/hooks";
import { useChapterHref } from "@/features/novels/use-chapter-href";
import { ApiError } from "@/types/api";
import type { SeriesId } from "@/types/api";
import {
  readScopedString,
  writeScopedString,
} from "@/lib/scoped-storage";
import { cn } from "@/lib/cn";
import {
  ChapterCheckbox,
  ChapterDownloadBar,
  ChapterDownloadTrigger,
  SavedChapterMark,
  useChapterPicker,
} from "@/features/offline";
// Direct rather than through the barrel: the savers pull in the reader API and
// the novels hooks, and the barrel is what the reader itself imports.
import {
  useMangaChapterSaver,
  useNovelChapterSaver,
} from "@/features/offline/chapter-savers";
import { chapterLinksReady } from "../chapter-links";
import { libraryReadingOrder, librarySeriesContinue } from "../history-continue";
import { libraryReadAllHref } from "../read-all-link";
import { READING_STATUSES } from "../url-state";
import type { SeriesDetail } from "../types";
import { CoverImage } from "@/components/ui/cover-image";
import { chapterDateLabel, chapterUploadedAt } from "@/features/sources/chapter-date";

/**
 * The poster: capped at `max-w-[220px]`, and 220px wide from `lg` up. Both a
 * `sizes` hint and the width the cover proxy renders to (`lib/cover-url.ts`).
 */
const POSTER_SIZES = "220px";

interface SeriesDetailViewProps {
  seriesId: number;
}

function statusBadgeStyle(status: string): string {
  switch (status) {
    case "reading":
      return "bg-primary/15 text-primary border-primary/30";
    case "completed":
      return "bg-success/15 text-success border-success/30";
    case "on_hold":
      return "bg-accent/15 text-accent border-accent/30";
    default:
      return "bg-white/5 text-muted border-border/50";
  }
}

type ChapterSort = "newest" | "oldest";

export function SeriesDetailView({ seriesId }: SeriesDetailViewProps) {
  const seriesQuery = useSeries(seriesId);
  const series = seriesQuery.data;

  const toggleFavorite = useToggleFavorite();
  const patchSeries = usePatchSeries();
  // One question, asked once, and every reader link on this page hangs off the
  // answer: prose opens in the novel reader, pages in the page strip, and
  // "Read all" is offered for pages alone.
  const isNovel = useIsNovelSource(series?.source_id ?? "");
  const chapterHref = useChapterHref();

  const sortKey = series ? `mm.chapter-sort:${series.source_id}:${series.series_key}` : null;
  const [sort, setSort] = useState<ChapterSort>(() => {
    if (!sortKey) return "newest";
    return readScopedString(sortKey) === "oldest" ? "oldest" : "newest";
  });
  const setSortPersisted = (next: ChapterSort) => {
    setSort(next);
    if (sortKey) writeScopedString(sortKey, next);
  };

  const orderedChapters = useMemo(() => {
    if (!series) return [];
    const asc = libraryReadingOrder(series);
    return sort === "newest" ? asc.reverse() : asc;
  }, [series, sort]);

  // The one Continue rule — the source and novel pages ask it too — see
  // `seriesContinue`.
  const continueTo = useMemo(
    () => (series ? librarySeriesContinue(series) : null),
    [series],
  );

  /**
   * Downloads, on the series page a follower actually opens.
   *
   * This screen serves both media, so both savers are built and the one this
   * series calls for is handed to the picker — `useIsNovelSource` is already
   * the single question every other link on this page hangs off. Until it
   * answers, `linksReady` is false and the chapter list renders its skeleton,
   * so nothing downloadable is on screen to be wired wrongly.
   */
  const sourceId = series?.source_id ?? "";
  const seriesKey = series?.series_key ?? "";
  const chapterTitles = useMemo(() => {
    const titles = new Map<string, string>();
    for (const chapter of series?.chapters ?? []) {
      titles.set(
        chapter.key,
        chapter.title?.trim() ||
          (chapter.number != null ? `Chapter ${chapter.number}` : chapter.key),
      );
    }
    return titles;
  }, [series]);
  const titleOf = useCallback(
    (chapterKey: string) => chapterTitles.get(chapterKey) ?? chapterKey,
    [chapterTitles],
  );
  const mangaSaver = useMangaChapterSaver({
    sourceId,
    seriesKey,
    seriesTitle: series?.title ?? null,
  });
  const novelSaver = useNovelChapterSaver({
    sourceId,
    seriesKey,
    seriesTitle: series?.title ?? null,
    titleOf,
  });
  const saver = isNovel === true ? novelSaver : mangaSaver;
  // Display order, not listing order: shift-click ranges over the rows as they
  // are on screen, and this list's sort is remembered per series.
  const pickerRows = useMemo(
    () =>
      orderedChapters.map((chapter) => ({
        key: chapter.key,
        number: chapter.number,
        read: series?.progress[chapter.key]?.is_completed ?? false,
      })),
    [orderedChapters, series],
  );
  const picker = useChapterPicker({
    sourceId,
    seriesKey,
    chapters: pickerRows,
    buildRequest: saver.buildRequest,
    prepare: saver.prepare,
    medium: isNovel === true ? "novel" : "manga",
  });

  if (seriesQuery.isLoading) {
    return (
      <div className="min-h-full bg-bg" aria-busy="true" aria-label="Loading series">
        <div className="h-[280px] animate-pulse bg-surface-2" />
        <div className="mx-auto max-w-6xl px-6 py-8 md:px-10">
          <div className="grid gap-8 lg:grid-cols-[220px_1fr]">
            <div className="aspect-[2/3] animate-pulse rounded-2xl bg-surface-2" />
            <div className="space-y-4">
              <div className="h-10 w-2/3 animate-pulse rounded bg-surface-2" />
              <div className="h-4 w-full animate-pulse rounded bg-surface-2" />
              <div className="h-24 animate-pulse rounded-xl bg-surface-2" />
            </div>
          </div>
        </div>
      </div>
    );
  }

  if (seriesQuery.error || !series) {
    const message =
      seriesQuery.error instanceof ApiError
        ? seriesQuery.error.message
        : "Failed to load series.";
    return (
      <div className="flex min-h-[40vh] flex-col items-center justify-center gap-3 p-6 text-center">
        <p className="text-danger">{message}</p>
        <Link
          href="/library"
          className="mt-4 inline-flex h-10 items-center justify-center rounded-full bg-primary px-5 text-sm font-medium text-primary-fg transition-colors hover:bg-primary-hover"
        >
          Back to library
        </Link>
      </div>
    );
  }

  const detail: SeriesDetail = series;
  const seriesRef: SeriesId = {
    sourceId: detail.source_id,
    seriesKey: detail.series_key,
  };
  // One URL for both the poster and the blurred backdrop behind it, which is
  // one fetch rather than two: the backdrop is `blur-sm` at 35% brightness
  // under a gradient, so it has no detail to lose from being painted at the
  // poster's width, and a second `100vw` request for it would be the largest
  // cover download on the page.
  const cover = libraryCoverUrl(detail.cover_url, POSTER_SIZES);
  const linksReady = chapterLinksReady(isNovel);
  /**
   * Continue, in whichever reader this series calls for.
   *
   * The point's `page` is the stored `last_page` either way: a novel has no
   * pages, so its position rides in that same field as a progress bucket
   * (`features/novels/progress.ts`) and `useChapterHref` hands it to the novel
   * route's `?page=`. Neither medium's position is translated on the way out.
   * Caught up, there is nothing to open, and the button says so instead.
   */
  const continuePoint =
    continueTo && continueTo.kind !== "caught-up" ? continueTo.point : null;
  const resumeHref =
    linksReady && continuePoint
      ? chapterHref({ ...seriesRef, chapterKey: continuePoint.chapterKey }, continuePoint.page)
      : null;
  const caughtUp = continueTo?.kind === "caught-up";
  /**
   * Read all, beside Continue and never instead of it. The source series page
   * has offered it since the run reader shipped, and this is the series page a
   * reader who already follows the series actually opens.
   *
   * It starts at the chapter Continue opens, for the reason Continue exists:
   * forty chapters in, nobody means chapter one.
   */
  const readAllTarget = libraryReadAllHref(
    seriesRef,
    detail.chapters.length,
    continueTo?.kind === "resume" ? continueTo.point.chapterKey : null,
    isNovel,
  );

  return (
    <div className="min-h-full bg-bg">
      <section className="relative h-[280px] overflow-hidden md:h-[320px]">
        <CoverImage
          src={cover}
          alt=""
          fill
          className="object-cover brightness-[0.35] blur-sm"
          sizes="100vw"
          unoptimized
          aria-hidden
        />
        <div className="absolute inset-0 bg-gradient-to-b from-void/60 via-void/80 to-bg" />
        <div className="absolute inset-x-0 top-0 px-6 py-4 md:px-10">
          <Link
            href="/library"
            className="inline-flex items-center gap-1.5 text-sm text-white/70 transition-colors hover:text-white"
          >
            <ArrowLeft className="size-4" />
            Back to library
          </Link>
        </div>
      </section>

      <div className="relative mx-auto max-w-6xl px-6 pb-10 md:px-10">
        <div className="-mt-36 grid gap-8 lg:grid-cols-[220px_1fr] lg:gap-10">
          <div className="mx-auto w-full max-w-[220px] lg:mx-0 lg:sticky lg:top-24 lg:self-start">
            <div className="relative aspect-[2/3] overflow-hidden rounded-3xl shadow-glow ring-1 ring-white/10">
              <CoverImage
                src={cover}
                alt={detail.title}
                fill
                className="object-cover"
                sizes={POSTER_SIZES}
                unoptimized
                priority
              />
            </div>
          </div>

          <div className="pt-2 lg:pt-16">
            <div className="flex flex-wrap items-start justify-between gap-4">
              <div className="min-w-0 flex-1">
                <h1 className="text-3xl font-bold tracking-tight text-fg md:text-4xl">
                  {detail.title}
                </h1>
              </div>
              <div className="flex shrink-0 flex-wrap items-start gap-2">
                <Button
                  variant={detail.is_favorite ? "primary" : "secondary"}
                  onClick={() =>
                    toggleFavorite.mutate({
                      followedId: detail.id,
                      isFavorite: !detail.is_favorite,
                    })
                  }
                  aria-label={
                    detail.is_favorite ? "Remove from favorites" : "Add to favorites"
                  }
                  className={cn(
                    "rounded-full",
                    detail.is_favorite
                      ? "bg-primary/20 text-primary hover:bg-primary/30"
                      : "border border-border/50 bg-white/5 hover:bg-white/10",
                  )}
                >
                  <Star className={cn("size-4", detail.is_favorite && "fill-primary")} />
                  {detail.is_favorite ? "Favorited" : "Add Favorite"}
                </Button>
              </div>
            </div>

            {detail.author ? (
              <p className="mt-3 text-base text-muted">by {detail.author}</p>
            ) : null}

            <div className="mt-4 flex flex-wrap items-center gap-2">
              <label className="sr-only" htmlFor="reading-status">
                Reading status
              </label>
              <select
                id="reading-status"
                value={detail.reading_status}
                onChange={(event) =>
                  patchSeries.mutate({
                    followedId: detail.id,
                    body: { reading_status: event.target.value },
                  })
                }
                className={cn(
                  "rounded-full border px-3 py-1 text-xs font-medium uppercase tracking-wide",
                  statusBadgeStyle(detail.reading_status),
                )}
              >
                {READING_STATUSES.map((status) => (
                  <option key={status} value={status}>
                    {status.replace(/_/g, " ")}
                  </option>
                ))}
              </select>
              <button
                type="button"
                onClick={() =>
                  patchSeries.mutate({
                    followedId: detail.id,
                    body: { notify: !detail.notify },
                  })
                }
                className={cn(
                  "rounded-full border px-3 py-1 text-xs font-medium",
                  detail.notify
                    ? "border-primary/30 bg-primary/10 text-primary"
                    : "border-border/50 bg-white/5 text-muted",
                )}
              >
                {detail.notify ? "Notifications on" : "Notifications off"}
              </button>
            </div>

            <div className="mt-4 flex flex-wrap gap-4 text-sm text-muted">
              <span>{detail.chapters.length} chapters</span>
              {detail.genres && detail.genres.length > 0 ? (
                <span>{detail.genres.slice(0, 4).join(", ")}</span>
              ) : null}
            </div>

            {resumeHref || caughtUp || readAllTarget ? (
              <div className="mt-6 flex flex-wrap items-center gap-2">
                {resumeHref ? (
                  <PrimaryPillButton
                    href={resumeHref}
                    className="shadow-glow"
                    icon={<Play className="size-4 fill-current" />}
                  >
                    {continueTo?.kind === "start" ? "Read" : "Continue"}
                  </PrimaryPillButton>
                ) : null}
                {caughtUp ? <PrimaryPillButton disabled>All caught up</PrimaryPillButton> : null}
                {readAllTarget ? (
                  <span
                    className="inline-flex"
                    title="Every chapter in one continuous scroll"
                  >
                    <GhostPillButton href={readAllTarget}>Read all</GhostPillButton>
                  </span>
                ) : null}
              </div>
            ) : null}

            {detail.description ? (
              <p className="mt-6 max-w-3xl text-sm leading-relaxed text-fg/80">
                {detail.description}
              </p>
            ) : null}
          </div>
        </div>

        <section className="mt-10">
          <div className="mb-4 flex flex-wrap items-center gap-2">
            <BookOpen className="size-4 text-primary" aria-hidden />
            <h2 className="text-sm font-semibold uppercase tracking-wider text-fg">
              Chapters
            </h2>
            <span className="text-xs text-muted">({detail.chapters.length})</span>
            {linksReady && detail.chapters.length > 0 && !picker.selecting ? (
              <ChapterDownloadTrigger picker={picker} />
            ) : null}
            <div className="ml-auto flex gap-1 text-xs">
              {(["newest", "oldest"] as const).map((option) => (
                <button
                  key={option}
                  type="button"
                  onClick={() => setSortPersisted(option)}
                  className={cn(
                    "rounded-full px-3 py-1 capitalize transition-colors",
                    sort === option
                      ? "bg-primary/15 text-primary"
                      : "text-muted hover:text-fg",
                  )}
                >
                  {option}
                </button>
              ))}
            </div>
          </div>

          {/* `glass-flat`: the panel's fill and edge without its blur. The list
              sits on the page's opaque `bg-bg`, so the blur drew the pixels it
              was given, and with every chapter inside it, it re-ran over most
              of the viewport on each scroll frame. */}
          <div
            className="glass-panel glass-flat divide-y divide-border/60 overflow-hidden rounded-3xl border border-border"
            aria-busy={!linksReady}
          >
            {!linksReady ? (
              // The chapters are known; which reader they open in is not yet.
              Array.from({ length: Math.min(detail.chapters.length, 6) }).map(
                (_, index) => (
                  <div
                    key={index}
                    className="flex items-center gap-4 px-4 py-3.5"
                    aria-hidden
                  >
                    <div className="size-9 shrink-0 animate-pulse rounded-xl bg-surface-2" />
                    <div className="h-4 w-1/3 animate-pulse rounded bg-surface-2" />
                  </div>
                ),
              )
            ) : orderedChapters.length === 0 ? (
              <p className="p-6 text-sm text-muted">No chapters found for this series.</p>
            ) : (
              orderedChapters.map((chapter, index) => {
                const progress = detail.progress[chapter.key];
                const isCompleted = progress?.is_completed ?? false;
                const inProgress = progress != null && !isCompleted;
                const downloadState = picker.stateOf(chapter.key);
                // What the source said about when this went up. Present on the
                // cached chapter list as `published_at`; absent for the sources
                // that publish no date at all, in which case the row simply
                // does not carry one.
                const uploaded = chapterDateLabel(chapterUploadedAt(chapter));
                const picked = picker.isSelected(chapter.key);
                return (
                  <Link
                    key={chapter.key}
                    href={chapterHref(
                      { ...seriesRef, chapterKey: chapter.key },
                      progress?.last_page,
                    )}
                    // In selection mode the row ticks instead of opening; the
                    // whole row stays the hit area either way.
                    onClick={(event) => {
                      if (!picker.selecting) return;
                      event.preventDefault();
                      picker.pick(chapter.key, event.shiftKey);
                    }}
                    aria-pressed={picker.selecting ? picked : undefined}
                    // `cv-row`: a row scrolled out of view skips layout and
                    // paint. The list is every chapter, with no windowing.
                    className={cn(
                      "cv-row group flex items-center gap-4 px-4 py-3.5 transition-colors hover:bg-primary/[0.06]",
                      isCompleted && "bg-black/25",
                      picker.selecting && picked && "bg-primary/10",
                    )}
                  >
                    {picker.selecting ? (
                      <ChapterCheckbox
                        checked={picked}
                        disabled={downloadState === "saved"}
                      />
                    ) : null}
                    <span className="flex size-9 shrink-0 items-center justify-center rounded-xl bg-white/5 font-mono text-xs tabular-nums text-muted transition-colors group-hover:bg-primary/20 group-hover:text-primary">
                      {chapter.number ?? index + 1}
                    </span>
                    <div className="min-w-0 flex-1">
                      <p
                        className={cn(
                          "truncate font-medium transition-colors group-hover:text-primary",
                          isCompleted ? "text-muted" : "text-fg",
                        )}
                      >
                        {chapter.title ??
                          (chapter.number != null
                            ? `Chapter ${chapter.number}`
                            : chapter.key)}
                      </p>
                      <div className="mt-0.5 flex flex-wrap items-center gap-2 text-xs text-muted">
                        {uploaded ? <span>{uploaded}</span> : null}
                        {inProgress && chapter.page_count ? (
                          <span>
                            {progress!.last_page}/{chapter.page_count} pages
                          </span>
                        ) : chapter.page_count ? (
                          <span>{chapter.page_count} pages</span>
                        ) : null}
                        {isCompleted ? (
                          <span className="inline-flex items-center gap-1 rounded-full border border-border/50 bg-white/5 px-1.5 py-0.5">
                            <Check className="size-3" aria-hidden />
                            Read
                          </span>
                        ) : null}
                      </div>
                    </div>
                    <SavedChapterMark state={downloadState} />
                    {inProgress ? (
                      <Badge
                        variant="primary"
                        className="shrink-0 bg-primary/20 text-primary"
                      >
                        In progress
                      </Badge>
                    ) : picker.selecting ? null : (
                      <ChevronRight className="size-4 shrink-0 text-muted opacity-0 transition-opacity group-hover:opacity-100" />
                    )}
                  </Link>
                );
              })
            )}
          </div>
          {picker.selecting || picker.downloads.running || picker.downloads.summary ? (
            <ChapterDownloadBar picker={picker} className="mt-4" />
          ) : null}
        </section>
      </div>
    </div>
  );
}
