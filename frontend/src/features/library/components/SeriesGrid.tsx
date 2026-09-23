"use client";

import { memo } from "react";
import { Compass, Library, SearchX, SlidersHorizontal, type LucideIcon } from "lucide-react";
import { EmptyState, type EmptyStateAction } from "@/components/ui/empty-state";
import {
  DEFAULT_LIBRARY_DENSITY,
  type LibraryDensity,
  densityGridClassName,
} from "@/features/library/density";
import { useGridNavigation } from "@/lib/keyboard";
import { cn } from "@/lib/cn";
import { SeriesCard, SeriesListItem, type SeriesSelectHandler } from "./SeriesCard";
import type { FollowedSeries } from "../types";

export type SeriesGridEmptyState = "library" | "search" | "filter";

export interface SeriesGridSelection {
  selecting: boolean;
  selectedIds: ReadonlySet<number>;
  onSelect: SeriesSelectHandler;
}

interface SeriesGridProps {
  items: FollowedSeries[];
  isLoading?: boolean;
  emptyState?: SeriesGridEmptyState;
  density?: LibraryDensity;
  /** Omitted by callers that have no multi-select (collections, for now). */
  selection?: SeriesGridSelection;
}

function emptyCopy(state: SeriesGridEmptyState): {
  icon: LucideIcon;
  title: string;
  description: string;
  action?: EmptyStateAction;
} {
  switch (state) {
    case "search":
      return {
        icon: SearchX,
        title: "No results found",
        description: "Try a different search term or clear filters.",
      };
    case "filter":
      return {
        icon: SlidersHorizontal,
        title: "No series match these filters",
        description: "Adjust your filters or favorites toggle to see more series.",
      };
    default:
      return {
        icon: Library,
        title: "Nothing followed yet",
        description:
          "This account has no series yet. Browse a source and follow one to start your library.",
        action: { label: "Browse Sources", href: "/sources", icon: Compass },
      };
  }
}

/** Skeleton count scaled to the density, so the placeholder fills the same space. */
function skeletonCount(density: LibraryDensity): number {
  switch (density) {
    case "compact":
      return 24;
    case "list":
      return 8;
    default:
      return 12;
  }
}

/**
 * Memoised, and hands each card plain values, so a re-render of the view above
 * — a search keystroke, a bulk-progress tick — skips the grid, and a selection
 * click re-renders only the cards whose `selected` changed. Callers keep
 * `selection` referentially stable for this to hold.
 */
export const SeriesGrid = memo(function SeriesGrid({
  items,
  isLoading,
  emptyState = "library",
  density = DEFAULT_LIBRARY_DENSITY,
  selection,
}: SeriesGridProps) {
  // Registered for the grid's lifetime, and only while there is something to
  // move through — the skeleton and empty branches below leave the keys unbound
  // rather than advertising a shortcut that does nothing.
  const gridNavigation = useGridNavigation({
    id: "library.grid",
    group: "Library",
    description: "Move through the series grid (arrows work too)",
    enabled: !isLoading && items.length > 0,
  });

  if (isLoading) {
    return (
      <div
        aria-busy="true"
        aria-label="Loading library"
        className={densityGridClassName(density)}
      >
        {Array.from({ length: skeletonCount(density) }).map((_, index) => (
          <div
            key={index}
            className={cn(
              "animate-pulse rounded-2xl bg-surface-2",
              density === "list" ? "h-20" : "aspect-[2/3]",
            )}
          />
        ))}
      </div>
    );
  }

  if (items.length === 0) {
    const copy = emptyCopy(emptyState);
    return (
      <EmptyState
        icon={copy.icon}
        title={copy.title}
        description={copy.description}
        action={copy.action}
      />
    );
  }

  const selecting = selection?.selecting ?? false;
  const onSelect = selection?.onSelect;

  return (
    <div
      {...gridNavigation}
      className={cn(
        densityGridClassName(density),
        // Cards arrive in a short cascade rather than all in one frame. Not
        // applied while selecting: re-running an entrance every time the
        // selection changes would animate the grid on each click.
        !selecting && "stagger-in",
        // Shift-click drags the browser's own text selection across every card
        // it passes, which looks like a bug and hides the highlight.
        selecting && "select-none",
      )}
    >
      {items.map((series) => {
        const selected = selection?.selectedIds.has(series.id) ?? false;
        return density === "list" ? (
          <SeriesListItem
            key={series.id}
            series={series}
            selecting={selecting}
            selected={selected}
            onSelect={onSelect}
          />
        ) : (
          <SeriesCard
            key={series.id}
            series={series}
            density={density}
            selecting={selecting}
            selected={selected}
            onSelect={onSelect}
          />
        );
      })}
    </div>
  );
});
