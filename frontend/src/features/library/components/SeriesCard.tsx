"use client";

import Link from "next/link";
import { useState } from "react";
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
 * Marks a card as a cell of the keyboard-navigable grid, and gives it the focus
 * ring it never had — arrow-key movement is only usable if you can see where
 * focus landed. Spread onto whichever element is the card's tab stop.
 */
const gridItemProps = {
  [GRID_ITEM_ATTRIBUTE]: "",
  className:
    "block rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/70 focus-visible:ring-offset-2 focus-visible:ring-offset-bg",
} as const;

/**
 * The list row's cover box (`size-16`). Fixed, so unlike the grid it needs no
 * breakpoints — and it is both the browser's `sizes` hint and the width the
 * cover proxy renders to (`lib/cover-url.ts`).
 */
const LIST_COVER_SIZES = "64px";

/** How a card reports a click on its checkbox (or on itself, in select mode). */
export type SeriesSelectHandler = (seriesId: number, shiftKey: boolean) => void;

export interface SeriesCardSelection {
  selecting: boolean;
  selected: boolean;
  onSelect: SeriesSelectHandler;
}

interface SeriesCardProps {
  series: FollowedSeries;
  density?: LibraryDensity;
  selection?: SeriesCardSelection;
}

/** Followed-series detail page, keyed by the follow-row id. */
function detailHref(series: FollowedSeries): string {
  return `/library/${series.id}`;
}

function statusBadgeStyle(status: string): string {
  switch (status) {
    case "reading":
      return "bg-primary/85 text-primary-fg";
    case "completed":
      return "bg-success/80 text-white";
    case "on_hold":
      return "bg-accent/85 text-white";
    case "plan_to_read":
      return "bg-white/20 text-white";
    default:
      return "bg-white/15 text-white";
  }
}

function statusLabel(status: string): string {
  return status.replace(/_/g, " ");
}

const CHECKBOX_BASE =
  "flex size-6 items-center justify-center rounded-md border backdrop-blur-sm transition-all";

function checkboxTone(selected: boolean): string {
  return selected
    ? "border-primary bg-primary text-primary-fg"
    : "border-white/50 bg-black/50 text-transparent";
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

function SeriesCardContent({
  series,
  isHovered,
  density,
  selection,
}: {
  series: FollowedSeries;
  isHovered: boolean;
  density: LibraryDensity;
  selection?: SeriesCardSelection;
}) {
  const toggleFavorite = useToggleFavorite();
  const selected = selection?.selected ?? false;
  const showRowActions = density !== "compact";
  const seriesRef = { sourceId: series.source_id, seriesKey: series.series_key };

  return (
    <article
      className={cn(
        "group relative overflow-hidden rounded-2xl transition-all duration-300 hover:shadow-glow",
        selected && "ring-2 ring-primary ring-offset-2 ring-offset-bg",
      )}
    >
      <div className="relative aspect-[2/3] w-full overflow-hidden rounded-2xl bg-surface-2 ring-1 ring-white/5 transition-all duration-300 group-hover:ring-primary/30">
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

        {series.reading_status && !selection?.selecting ? (
          <span
            className={cn(
              "absolute left-2 top-2 rounded-md px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide backdrop-blur-sm",
              statusBadgeStyle(series.reading_status),
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

        {selection || showRowActions ? (
          <div className="absolute right-2 top-2 z-10 flex items-center gap-1.5">
            {selection ? (
              <SelectCheckbox
                seriesId={series.id}
                title={series.title}
                selected={selected}
                selecting={selection.selecting}
                onSelect={selection.onSelect}
              />
            ) : null}
            {showRowActions && !selection?.selecting ? (
              <>
                <FollowButton
                  series={seriesRef}
                  followedId={series.id}
                  compact
                  className={cn("transition-opacity", cardActionVisibility(isHovered))}
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
                    "flex size-8 items-center justify-center rounded-full bg-black/50 backdrop-blur-sm transition-opacity",
                    cardActionVisibility(isHovered || series.is_favorite),
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
  );
}

export function SeriesCard({
  series,
  density = DEFAULT_LIBRARY_DENSITY,
  selection,
}: SeriesCardProps) {
  const href = detailHref(series);
  const [isHovered, setIsHovered] = useState(false);
  const content = (
    <SeriesCardContent
      series={series}
      isHovered={isHovered}
      density={density}
      selection={selection}
    />
  );

  const hoverProps = {
    onMouseEnter: () => setIsHovered(true),
    onMouseLeave: () => setIsHovered(false),
  };

  if (selection?.selecting) {
    return (
      <div
        role="checkbox"
        aria-checked={selection.selected}
        aria-label={`Select ${series.title}`}
        tabIndex={0}
        onClick={(event) => selection.onSelect(series.id, event.shiftKey)}
        onKeyDown={(event) => {
          if (event.key === " " || event.key === "Enter") {
            event.preventDefault();
            selection.onSelect(series.id, event.shiftKey);
          }
        }}
        {...{ [GRID_ITEM_ATTRIBUTE]: "" }}
        className="cursor-pointer select-none rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60"
        {...hoverProps}
      >
        {content}
      </div>
    );
  }

  return (
    <Link href={href} {...gridItemProps} {...hoverProps}>
      {content}
    </Link>
  );
}

export function SeriesListItem({ series, selection }: SeriesCardProps) {
  const href = detailHref(series);
  const toggleFavorite = useToggleFavorite();
  const selected = selection?.selected ?? false;
  const seriesRef = { sourceId: series.source_id, seriesKey: series.series_key };

  const row = (
    <div
      className={cn(
        "glass-card group flex items-center gap-4 rounded-2xl p-3 transition-colors hover:border-primary/30",
        selected && "border-primary/60 bg-primary/5",
      )}
    >
      {selection ? (
        <SelectCheckbox
          seriesId={series.id}
          title={series.title}
          selected={selected}
          selecting={selection.selecting}
          onSelect={selection.onSelect}
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
                statusBadgeStyle(series.reading_status),
              )}
            >
              {statusLabel(series.reading_status)}
            </span>
          ) : null}
        </div>
        <p className="mt-1 text-xs text-muted">{seriesCardMeta(series)}</p>
      </div>
      {selection?.selecting ? null : (
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
  );

  if (selection?.selecting) {
    return (
      <div
        role="checkbox"
        aria-checked={selected}
        aria-label={`Select ${series.title}`}
        tabIndex={0}
        onClick={(event) => selection.onSelect(series.id, event.shiftKey)}
        onKeyDown={(event) => {
          if (event.key === " " || event.key === "Enter") {
            event.preventDefault();
            selection.onSelect(series.id, event.shiftKey);
          }
        }}
        {...{ [GRID_ITEM_ATTRIBUTE]: "" }}
        className="cursor-pointer select-none rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60"
      >
        {row}
      </div>
    );
  }

  return (
    <Link href={href} {...gridItemProps}>
      {row}
    </Link>
  );
}
