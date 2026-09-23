"use client";

import Link from "next/link";
import { memo, type KeyboardEvent, type MouseEvent, type ReactNode } from "react";
import { Check } from "lucide-react";
import { libraryCoverUrl } from "@/features/library/api";
import { cardActionVisibility } from "@/features/library/card-actions";
import {
  DEFAULT_LIBRARY_DENSITY,
  type LibraryDensity,
  densityCoverSizes,
} from "@/features/library/density";
import { useToggleFavorite } from "@/features/library/hooks";
import { seriesCardMeta } from "@/features/library/read-state";
import type { FollowedSeries } from "@/features/library/types";
import { GRID_ITEM_ATTRIBUTE } from "@/lib/keyboard";
import { cn } from "@/lib/cn";
import { FollowButton } from "./FollowButton";
import { CoverImage } from "@/components/ui/cover-image";

/**
 * The card's tab stop, and the cell the keyboard grid moves through. It carries
 * the focus ring the card never had — arrow-key movement is only usable if you
 * can see where focus landed.
 */
const LINK_ROOT_CLASS =
  "block rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/70 focus-visible:ring-offset-2 focus-visible:ring-offset-bg";

/** The same element in select mode, where a click toggles instead of opening. */
const SELECTING_ROOT_CLASS =
  "block cursor-pointer select-none rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60";

/**
 * The list row's cover box (`size-16`). Fixed, so unlike the grid it needs no
 * breakpoints — and it is both the browser's `sizes` hint and the width the
 * cover proxy renders to (`lib/cover-url.ts`).
 */
const LIST_COVER_SIZES = "64px";

/** How a card reports a click on its checkbox (or on itself, in select mode). */
export type SeriesSelectHandler = (seriesId: number, shiftKey: boolean) => void;

/**
 * A card's part in multi-select, as plain values. The grid renders up to 200
 * memoised cards; with primitives here a selection click re-renders only the
 * card whose `selected` flipped, where one object per card re-rendered them all.
 */
interface SeriesCardSelectProps {
  /** Present when the grid offers multi-select at all. */
  onSelect?: SeriesSelectHandler;
  selecting?: boolean;
  selected?: boolean;
}

interface SeriesCardProps extends SeriesCardSelectProps {
  series: FollowedSeries;
  density?: LibraryDensity;
}

/** Followed-series detail page, keyed by the follow-row id. */
function detailHref(series: FollowedSeries): string {
  return `/library/${series.id}`;
}

/**
 * The reading-status chip over a cover. It used to frost what was behind it
 * (`backdrop-blur-sm`), one backdrop pass per card redrawn on every scroll
 * frame; the two light tones leaned on that frost for contrast, so over a cover
 * they are now a dark fill that keeps white text legible without it.
 */
function statusBadgeStyle(status: string, overCover: boolean): string {
  switch (status) {
    case "reading":
      return "bg-primary/85 text-primary-fg";
    case "completed":
      return "bg-success/80 text-white";
    case "on_hold":
      return "bg-accent/85 text-white";
    case "plan_to_read":
      return overCover ? "bg-black/55 text-white" : "bg-white/20 text-white";
    default:
      return overCover ? "bg-black/55 text-white" : "bg-white/15 text-white";
  }
}

function statusLabel(status: string): string {
  return status.replace(/_/g, " ");
}

const CHECKBOX_BASE =
  "flex size-6 items-center justify-center rounded-md border transition-[color,background-color,border-color,opacity]";

function checkboxTone(selected: boolean): string {
  return selected
    ? "border-primary bg-primary text-primary-fg"
    : "border-white/50 bg-black/60 text-transparent";
}

function SelectCheckbox({
  seriesId,
  title,
  selected,
  selecting,
  onSelect,
  className,
}: {
  seriesId: number;
  title: string;
  selected: boolean;
  selecting: boolean;
  onSelect: SeriesSelectHandler;
  className?: string;
}) {
  if (selecting) {
    return (
      <span aria-hidden className={cn(CHECKBOX_BASE, checkboxTone(selected), className)}>
        <Check className="size-4" />
      </span>
    );
  }

  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={selected}
      aria-label={`Select ${title}`}
      onClick={(event) => {
        event.preventDefault();
        event.stopPropagation();
        onSelect(seriesId, event.shiftKey);
      }}
      className={cn(
        CHECKBOX_BASE,
        checkboxTone(selected),
        selected
          ? "opacity-100"
          : "opacity-100 hover:border-white sm:opacity-0 sm:focus-visible:opacity-100 sm:group-hover:opacity-100",
        className,
      )}
    >
      <Check className="size-4" />
    </button>
  );
}

/**
 * The card's root: the same `<a>` whether the grid is selecting or not.
 *
 * Select mode used to swap it for a `<div role="checkbox">`. A different root
 * element is a different component to React, so entering or leaving select
 * mode unmounted and remounted every card on the page — up to 200 — and every
 * remounted cover faded in again from nothing. Keeping the element and
 * switching its role, handlers and class makes the toggle an ordinary
 * re-render. The click handler's `preventDefault` is what stops the link
 * navigating; `next/link` checks it before routing.
 */
function CardLink({
  series,
  selecting,
  selected,
  onSelect,
  className,
  children,
}: {
  series: FollowedSeries;
  selecting: boolean;
  selected: boolean;
  onSelect?: SeriesSelectHandler;
  className?: string;
  children: ReactNode;
}) {
  const gridItem = { [GRID_ITEM_ATTRIBUTE]: "" };

  if (selecting && onSelect) {
    const select = (
      event: MouseEvent<HTMLAnchorElement> | KeyboardEvent<HTMLAnchorElement>,
    ) => {
      event.preventDefault();
      onSelect(series.id, event.shiftKey);
    };
    return (
      <Link
        href={detailHref(series)}
        {...gridItem}
        role="checkbox"
        aria-checked={selected}
        aria-label={`Select ${series.title}`}
        draggable={false}
        onClick={select}
        onKeyDown={(event) => {
          if (event.key === " " || event.key === "Enter") select(event);
        }}
        className={cn(SELECTING_ROOT_CLASS, className)}
      >
        {children}
      </Link>
    );
  }

  return (
    <Link href={detailHref(series)} {...gridItem} className={cn(LINK_ROOT_CLASS, className)}>
      {children}
    </Link>
  );
}

/**
 * The card's hover glow, as its own layer that fades by opacity.
 *
 * It was `transition-all hover:shadow-glow` on the card itself: a box-shadow
 * cannot be animated by the compositor, so every hover in or out repainted the
 * card, cover included, on each frame for 300ms. Drawn once here, only the
 * opacity animates. It sits before the card so the selection ring still paints
 * over it, as it did when both were one box-shadow.
 *
 * The value is what `hover:shadow-glow` compiled to — Tailwind inlines the
 * `@theme` default rather than reading the runtime `--shadow-glow` token that
 * the global `.shadow-glow` class uses — so the glow looks exactly as before.
 */
const HOVER_GLOW_CLASS =
  "pointer-events-none absolute inset-0 rounded-2xl opacity-0 shadow-[0_0_24px_rgba(88,166,255,0.22)] transition-opacity duration-300 group-hover/card:opacity-100";

function SeriesCardContent({
  series,
  density,
  selecting,
  selected,
  onSelect,
}: {
  series: FollowedSeries;
  density: LibraryDensity;
  selecting: boolean;
  selected: boolean;
  onSelect?: SeriesSelectHandler;
}) {
  const toggleFavorite = useToggleFavorite();
  const showRowActions = density !== "compact";
  const seriesRef = { sourceId: series.source_id, seriesKey: series.series_key };

  return (
    <>
      <span aria-hidden className={HOVER_GLOW_CLASS} />
      <article
        className={cn(
          "group relative overflow-hidden rounded-2xl transition-shadow duration-300",
          selected && "ring-2 ring-primary ring-offset-2 ring-offset-bg",
        )}
      >
        <div className="relative aspect-[2/3] w-full overflow-hidden rounded-2xl bg-surface-2 ring-1 ring-white/5 group-hover:ring-primary/30">
          <CoverImage
            src={libraryCoverUrl(series.cover_url, densityCoverSizes(density))}
            alt={series.title}
            fill
            className={cn(
              "object-cover transition-transform duration-300 group-hover:scale-105",
              selected && "scale-105 brightness-75",
            )}
            sizes={densityCoverSizes(density)}
            unoptimized
          />

          <div className="absolute inset-0 bg-gradient-to-t from-void via-void/20 to-transparent" />

          {series.reading_status && !selecting ? (
            <span
              className={cn(
                "absolute left-2 top-2 rounded-md px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
                statusBadgeStyle(series.reading_status, true),
              )}
            >
              {statusLabel(series.reading_status)}
            </span>
          ) : null}

          <div className="absolute inset-x-0 bottom-0 p-3">
            <h3
              className={cn(
                "line-clamp-2 font-semibold leading-snug text-white",
                density === "compact" ? "text-xs" : "text-sm",
              )}
            >
              {series.title}
            </h3>
            {density === "compact" ? null : (
              <p className="mt-0.5 truncate text-xs text-white/70">
                {seriesCardMeta(series)}
              </p>
            )}
          </div>

          {onSelect || showRowActions ? (
            <div className="absolute right-2 top-2 z-10 flex items-center gap-1.5">
              {onSelect ? (
                <SelectCheckbox
                  seriesId={series.id}
                  title={series.title}
                  selected={selected}
                  selecting={selecting}
                  onSelect={onSelect}
                />
              ) : null}
              {showRowActions && !selecting ? (
                <>
                  {/* Hover and focus reveal both actions through CSS
                      (`group-hover`, `group-focus-within`); a React hover state
                      that re-rendered the card on every enter and leave only
                      duplicated that. */}
                  <FollowButton
                    series={seriesRef}
                    followedId={series.id}
                    compact
                    className={cn("transition-opacity", cardActionVisibility(false))}
                  />
                  <button
                    type="button"
                    onClick={(event) => {
                      event.preventDefault();
                      event.stopPropagation();
                      toggleFavorite.mutate({
                        followedId: series.id,
                        isFavorite: !series.is_favorite,
                      });
                    }}
                    className={cn(
                      "flex size-8 items-center justify-center rounded-full bg-black/60 transition-opacity",
                      cardActionVisibility(series.is_favorite),
                      series.is_favorite ? "text-primary" : "text-white/70 hover:text-white",
                    )}
                    aria-label={
                      series.is_favorite ? "Remove from favorites" : "Add to favorites"
                    }
                    title={
                      series.is_favorite ? "Remove from favorites" : "Add to favorites"
                    }
                  >
                    {series.is_favorite ? "★" : "☆"}
                  </button>
                </>
              ) : null}
            </div>
          ) : null}
        </div>
      </article>
    </>
  );
}

/**
 * Memoised: `/library/browse` renders up to 200 of these with no
 * virtualisation, and the view above re-renders on every search keystroke,
 * selection click and bulk-progress tick.
 */
export const SeriesCard = memo(function SeriesCard({
  series,
  density = DEFAULT_LIBRARY_DENSITY,
  selecting = false,
  selected = false,
  onSelect,
}: SeriesCardProps) {
  const selectMode = selecting && onSelect !== undefined;
  return (
    <CardLink
      series={series}
      selecting={selectMode}
      selected={selected}
      onSelect={onSelect}
      // Positions the hover glow, and names the hover it answers to.
      className="group/card relative"
    >
      <SeriesCardContent
        series={series}
        density={density}
        selecting={selectMode}
        selected={selected}
        onSelect={onSelect}
      />
    </CardLink>
  );
});

export const SeriesListItem = memo(function SeriesListItem({
  series,
  selecting = false,
  selected = false,
  onSelect,
}: SeriesCardProps) {
  const toggleFavorite = useToggleFavorite();
  const selectMode = selecting && onSelect !== undefined;
  const seriesRef = { sourceId: series.source_id, seriesKey: series.series_key };

  return (
    <CardLink series={series} selecting={selectMode} selected={selected} onSelect={onSelect}>
      <div
        className={cn(
          // `glass-flat`: the row sits on the flat page background, where a
          // backdrop blur changes nothing on screen but still costs a pass per
          // row on every scroll frame.
          "glass-card glass-flat group flex items-center gap-4 rounded-2xl p-3 transition-colors hover:border-primary/30",
          selected && "border-primary/60 bg-primary/5",
        )}
      >
        {onSelect ? (
          <SelectCheckbox
            seriesId={series.id}
            title={series.title}
            selected={selected}
            selecting={selectMode}
            onSelect={onSelect}
            className="shrink-0"
          />
        ) : null}
        <div className="relative size-16 shrink-0 overflow-hidden rounded-lg bg-surface-2">
          <CoverImage
            src={libraryCoverUrl(series.cover_url, LIST_COVER_SIZES)}
            alt={series.title}
            fill
            className="object-cover"
            sizes={LIST_COVER_SIZES}
            unoptimized
          />
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="truncate font-medium text-fg">{series.title}</h3>
            {series.reading_status ? (
              <span
                className={cn(
                  "rounded-md px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
                  statusBadgeStyle(series.reading_status, false),
                )}
              >
                {statusLabel(series.reading_status)}
              </span>
            ) : null}
          </div>
          <p className="mt-1 text-xs text-muted">{seriesCardMeta(series)}</p>
        </div>
        {selectMode ? null : (
          <div className="flex shrink-0 items-center gap-1.5">
            <FollowButton
              series={seriesRef}
              followedId={series.id}
              compact
              className="size-9 bg-white/5 hover:bg-white/10"
            />
            <button
              type="button"
              onClick={(event) => {
                event.preventDefault();
                event.stopPropagation();
                toggleFavorite.mutate({
                  followedId: series.id,
                  isFavorite: !series.is_favorite,
                });
              }}
              className={cn(
                "flex size-9 items-center justify-center rounded-full bg-white/5 transition-colors hover:bg-white/10",
                series.is_favorite ? "text-primary" : "text-muted",
              )}
              aria-label={series.is_favorite ? "Remove from favorites" : "Add to favorites"}
            >
              {series.is_favorite ? "★" : "☆"}
            </button>
          </div>
        )}
      </div>
    </CardLink>
  );
});
