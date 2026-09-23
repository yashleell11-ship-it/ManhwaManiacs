"use client";

import { memo } from "react";
import { SearchX, TriangleAlert } from "lucide-react";
import { EmptyState } from "@/components/ui/empty-state";
import { useGridNavigation } from "@/lib/keyboard";
import { SourceSeriesCard } from "./SourceSeriesCard";
import type { SourceSeriesSummary } from "../types";

interface SourceSeriesGridProps {
  sourceId: string;
  items: SourceSeriesSummary[];
  isLoading?: boolean;
  query?: string;
  errorMessage?: string;
  /** Refetches the browse request. Omitted when there is nothing to retry. */
  onRetry?: () => void;
}

/**
 * Memoised so the browse view can re-render around the grid — its header count,
 * the loader, the "Loading more…" line — without the grid walking every card it
 * has ever loaded. It re-renders when `items` changes, which is a page landing
 * or a new search, and then only the new cards render: `SourceSeriesCard` is
 * memoised too.
 */
export const SourceSeriesGrid = memo(function SourceSeriesGrid({
  sourceId,
  items,
  isLoading,
  query,
  errorMessage,
  onRetry,
}: SourceSeriesGridProps) {
  const gridNavigation = useGridNavigation({
    id: "sources.grid",
    group: "Sources",
    description: "Move through the catalog grid (arrows work too)",
    enabled: !isLoading && !errorMessage && items.length > 0,
  });

  if (errorMessage) {
    return (
      <EmptyState
        tone="error"
        icon={TriangleAlert}
        title="Could not load source catalog"
        description={errorMessage}
        action={onRetry ? { label: "Try again", onClick: onRetry } : undefined}
      />
    );
  }

  if (isLoading) {
    return (
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
        {Array.from({ length: 12 }).map((_, index) => (
          <div
            key={index}
            className="aspect-[2/3] animate-pulse rounded-2xl bg-surface-2"
          />
        ))}
      </div>
    );
  }

  if (items.length === 0) {
    return (
      <EmptyState
        icon={SearchX}
        title="No series found"
        description={
          query
            ? `No results for "${query}" on this source.`
            : "This source returned no series."
        }
      />
    );
  }

  return (
    <div
      {...gridNavigation}
      className="stagger-in grid grid-cols-2 gap-4 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
    >
      {items.map((series) => (
        <SourceSeriesCard key={series.id} sourceId={sourceId} series={series} />
      ))}
    </div>
  );
});
