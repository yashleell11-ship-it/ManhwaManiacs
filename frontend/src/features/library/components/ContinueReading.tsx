"use client";

import Link from "next/link";
import { ChevronRight, Play } from "lucide-react";
import { useChapterHref } from "@/features/novels/use-chapter-href";
import { cn } from "@/lib/cn";
import { libraryCoverUrl, seriesCoverUrl } from "../api";
import {
  continueReadingChapterLabel,
  continueReadingKey,
  continueReadingPercent,
  continueReadingRef,
  resolveSeriesTitle,
} from "../continue-reading";
import { useFollowedIndex } from "../hooks";
import type { ContinueReadingItem } from "../types";
import { CoverImage } from "@/components/ui/cover-image";

/**
 * The hero card's cover: `w-28` (112px) below `sm`, `w-40`/`w-44` above — and
 * the rail card's, a fixed `w-[70px]`. Both are `sizes` hints AND the widths
 * the cover proxy renders to (`lib/cover-url.ts`), which is why they name the
 * real boxes rather than a round number.
 */
const HERO_COVER_SIZES = "(max-width: 639px) 112px, 176px";
const RAIL_COVER_SIZES = "70px";
/** The phone strip's cover: a fixed `w-11` (44px) thumbnail. */
const STRIP_COVER_SIZES = "44px";

/**
 * The series title a resume card shows.
 *
 * The server joins the follow row's title into each item. A server older than
 * that field sends none, and then the title comes from the caller's
 * followed-series map exactly as it always did, falling back to the key. The
 * payload's own title wins because it needs no second list to be loaded, and
 * the shelf's list stops at 200 rows, so its map can miss a series.
 */
export function continueItemTitle(
  item: ContinueReadingItem,
  titles: ReadonlyMap<string, string>,
): string {
  const own = item.title?.trim();
  return own ? own : resolveSeriesTitle(item, titles);
}

/**
 * The cover a resume card shows, sized for `sizes`.
 *
 * The follow row's own cover when the server sends it (the one the library
 * card for that series shows), else the source cover proxy for the item's key,
 * which is all an older server's payload can name.
 */
export function continueItemCoverUrl(item: ContinueReadingItem, sizes: string): string {
  const own = item.cover_url?.trim();
  return own ? libraryCoverUrl(own, sizes) : seriesCoverUrl(continueReadingRef(item), sizes);
}

interface ContinueReadingProps {
  items: ContinueReadingItem[];
  isLoading?: boolean;
  /**
   * True when the rail is showing novels, which have no pages: their stored
   * position is a progress bucket, so it reads back as a percentage.
   */
  novels?: boolean;
}

/**
 * The "pick up where you left off" section on `/library/browse`, from `md` up.
 *
 * `ContinueReadingRail` with its fallback titles joined from the whole
 * followed-series index, for a screen that does not already hold the followed
 * rows. `/library` does hold them, so it renders the rail directly with the map
 * it already built.
 */
export function ContinueReading({ items, isLoading, novels }: ContinueReadingProps) {
  const { titles } = useFollowedIndex();
  return (
    <ContinueReadingRail items={items} isLoading={isLoading} novels={novels} titles={titles} />
  );
}

interface ContinueReadingRailProps extends ContinueReadingProps {
  /**
   * `source_id:series_key -> title`, the fallback for an item the server sent
   * without a title (see `continueItemTitle`).
   */
  titles: ReadonlyMap<string, string>;
  className?: string;
}

/**
 * The hero card plus the horizontal rail: the desktop "where was I".
 *
 * Fed by `GET /library/continue-reading` (most recent unfinished chapter per
 * `(source_id, series_key)`). The lead item renders as a large hero card; the
 * rest follow in the horizontal rail. The resume link drops straight onto the
 * last page read.
 *
 * A hero card plus a rail is roughly 400px of vertical space, which is why the
 * phone gets `ContinueReadingStrip` instead (see below) and both screens show
 * this only from `md` up.
 */
export function ContinueReadingRail({
  items,
  isLoading,
  novels,
  titles,
  className,
}: ContinueReadingRailProps) {
  // Resolves to whichever reader the row's source calls for.
  const chapterHref = useChapterHref();

  if (isLoading) {
    return (
      <section
        className={cn("mb-8", className)}
        aria-busy="true"
        aria-label="Loading continue reading"
      >
        <div className="mb-3 h-4 w-40 animate-pulse rounded bg-surface-2" />
        <div className="mb-4 h-[220px] w-full animate-pulse rounded-3xl bg-surface-2 sm:h-[260px]" />
        <div className="flex gap-4 overflow-hidden">
          {Array.from({ length: 4 }).map((_, index) => (
            <div
              key={index}
              className="h-[120px] w-[280px] shrink-0 animate-pulse rounded-2xl bg-surface-2"
            />
          ))}
        </div>
      </section>
    );
  }

  if (items.length === 0) {
    return null;
  }

  const [hero, ...rest] = items;
  const heroPercent = continueReadingPercent(hero);
  const heroTitle = continueItemTitle(hero, titles);

  return (
    <section className={cn("mb-8", className)}>
      <h2 className="mb-3 text-sm font-semibold uppercase tracking-wide text-muted">
        Continue Reading
      </h2>

      <Link
        href={chapterHref(continueReadingRef(hero), hero.last_page)}
        className="group mb-4 block focus-visible:outline-none"
      >
        <article className="glass-card relative flex gap-4 overflow-hidden rounded-3xl p-3 transition-colors group-hover:border-primary/40 group-focus-visible:border-primary/60 sm:gap-6 sm:p-4">
          <div className="relative aspect-[2/3] w-28 shrink-0 overflow-hidden rounded-2xl bg-surface-2 sm:w-40 md:w-44">
            <CoverImage
              src={continueItemCoverUrl(hero, HERO_COVER_SIZES)}
              alt={heroTitle}
              fill
              className="object-cover"
              sizes={HERO_COVER_SIZES}
              unoptimized
            />
            <div className="absolute inset-0 flex items-center justify-center bg-void/40 opacity-0 transition-opacity group-hover:opacity-100">
              <Play className="size-8 fill-white text-white" aria-hidden />
            </div>
          </div>

          <div className="flex min-w-0 flex-1 flex-col justify-center gap-2 py-1 pr-1 sm:gap-3">
            <p className="text-[11px] font-semibold uppercase tracking-widest text-primary">
              Jump back in
            </p>
            <h3 className="line-clamp-2 text-lg font-semibold text-fg sm:text-2xl">{heroTitle}</h3>
            <p className="text-sm text-muted">
              {continueReadingChapterLabel(hero)} &middot;{" "}
              {novels
                ? `${heroPercent}% in`
                : `page ${hero.last_page}${hero.page_count > 0 ? ` of ${hero.page_count}` : ""}`}
            </p>
            <div className="mt-1 max-w-sm">
              <div className="h-1.5 w-full overflow-hidden rounded-full bg-white/10">
                <div
                  className="h-full rounded-full bg-primary"
                  style={{ width: `${heroPercent}%` }}
                />
              </div>
              {heroPercent > 0 ? (
                <p className="mt-1 text-[11px] tabular-nums text-muted">
                  {heroPercent}% through this chapter
                </p>
              ) : null}
            </div>
          </div>
        </article>
      </Link>

      {rest.length > 0 ? (
        <div className="flex snap-x snap-mandatory gap-4 overflow-x-auto scroll-smooth pb-2">
          {rest.map((item) => {
            const percent = continueReadingPercent(item);
            const title = continueItemTitle(item, titles);
            return (
              <Link
                key={continueReadingKey(item)}
                href={chapterHref(continueReadingRef(item), item.last_page)}
                className="group w-[280px] shrink-0 snap-start"
              >
                <article className="glass-card flex h-full gap-3 overflow-hidden rounded-2xl p-2 transition-colors hover:border-primary/40">
                  <div className="relative h-[104px] w-[70px] shrink-0 overflow-hidden rounded-lg bg-surface-2">
                    <CoverImage
                      src={continueItemCoverUrl(item, RAIL_COVER_SIZES)}
                      alt={title}
                      fill
                      className="object-cover"
                      sizes={RAIL_COVER_SIZES}
                      unoptimized
                    />
                    <div className="absolute inset-0 flex items-center justify-center bg-void/40 opacity-0 transition-opacity group-hover:opacity-100">
                      <Play className="size-6 fill-white text-white" aria-hidden />
                    </div>
                  </div>

                  <div className="flex min-w-0 flex-1 flex-col justify-between py-1 pr-1">
                    <div className="min-w-0">
                      <p className="truncate text-sm font-medium text-fg">{title}</p>
                      <p className="mt-0.5 truncate text-xs text-muted">
                        {continueReadingChapterLabel(item)}
                      </p>
                    </div>

                    <div>
                      <div className="flex items-center justify-between text-[11px] text-muted">
                        <span>{novels ? "In progress" : `Page ${item.last_page}`}</span>
                        {percent > 0 ? (
                          <span className="tabular-nums text-primary">{percent}%</span>
                        ) : null}
                      </div>
                      <div className="mt-1 h-1 w-full overflow-hidden rounded-full bg-white/10">
                        <div
                          className="h-full rounded-full bg-primary"
                          style={{ width: `${percent}%` }}
                        />
                      </div>
                    </div>
                  </div>
                </article>
              </Link>
            );
          })}
        </div>
      ) : null}
    </section>
  );
}

interface ContinueReadingStripProps {
  items: ContinueReadingItem[];
  /**
   * `source_id:series_key -> title`, built by the caller, for an item the
   * server sent without a title. The strip's caller (the shelf) already holds
   * the whole followed set, so passing the map keeps the phone's landing
   * screen from refetching 200 rows to render one title.
   */
  titles: ReadonlyMap<string, string>;
  novels?: boolean;
  className?: string;
}

/**
 * The same "where was I", in one row, for the phone.
 *
 * `ContinueReadingRail` (a hero card plus a horizontal rail under a section
 * header) pushed the first cover on `/library/browse` below the fold at 375px,
 * and the Flutter client shows no continue-reading section on either library
 * screen at all (`ContinueReadingSection` in `dashboard_sections.dart` is
 * defined and never built). But resuming is the single most useful thing on a
 * reading app's home screen, so below `md` it is this strip: the most recent
 * unfinished chapter, one tap, on the tab a phone actually opens on.
 *
 * Only the lead item. The rail's job was breadth; a strip's is the one answer.
 */
export function ContinueReadingStrip({
  items,
  titles,
  novels,
  className,
}: ContinueReadingStripProps) {
  const chapterHref = useChapterHref();

  if (items.length === 0) {
    return null;
  }

  const [item] = items;
  const percent = continueReadingPercent(item);
  const title = continueItemTitle(item, titles);

  return (
    <Link
      href={chapterHref(continueReadingRef(item), item.last_page)}
      className={cn("group block focus-visible:outline-none", className)}
    >
      <article className="glass-card flex items-center gap-3 overflow-hidden rounded-2xl p-2 transition-colors group-hover:border-primary/40 group-focus-visible:border-primary/60">
        <div className="relative aspect-[2/3] w-11 shrink-0 overflow-hidden rounded-lg bg-surface-2">
          <CoverImage
            src={continueItemCoverUrl(item, STRIP_COVER_SIZES)}
            alt=""
            fill
            className="object-cover"
            sizes={STRIP_COVER_SIZES}
            unoptimized
          />
        </div>

        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-medium text-fg">{title}</p>
          <p className="mt-0.5 truncate text-xs text-muted">
            {continueReadingChapterLabel(item)} &middot;{" "}
            {novels
              ? `${percent}% in`
              : `page ${item.last_page}${item.page_count > 0 ? ` of ${item.page_count}` : ""}`}
          </p>
          <div className="mt-1.5 h-1 w-full overflow-hidden rounded-full bg-white/10">
            <div className="h-full rounded-full bg-primary" style={{ width: `${percent}%` }} />
          </div>
        </div>

        <ChevronRight className="size-5 shrink-0 text-muted" aria-hidden />
        <span className="sr-only">Continue reading {title}</span>
      </article>
    </Link>
  );
}
