"use client";

import Link from "next/link";
import { Globe, ImageOff, Library } from "lucide-react";
import { globalSearchHref } from "@/features/sources/global-search";
import { prettifySourceId } from "@/features/sources/source-branding";
import type { GlobalSearchItem } from "@/features/sources/types";
import { withCoverWidth } from "@/lib/cover-url";
import { CoverImage } from "@/components/ui/cover-image";

/**
 * The result card's cover box, a fixed `w-[80px]`.
 *
 * Applied here rather than in `searchGroupFromSourceSeries`, which builds the
 * retry path's rows: both that path and the federated payload hand over a
 * `cover_url` already resolved against the API base (`resolveSearchCovers`),
 * so the only place that knows the box for BOTH the first response and a
 * retried section is the card that paints them. See `lib/cover-url.ts`.
 */
const COVER_SIZES = "80px";

interface GlobalSearchResultCardProps {
  item: GlobalSearchItem;
  /**
   * Set false inside a per-source section: the section header already names the
   * source, so repeating it on every row is noise.
   */
  showSourceBadge?: boolean;
}

function SourceBadge({ item }: { item: GlobalSearchItem }) {
  if (item.kind === "local") {
    return (
      <span className="inline-flex items-center gap-1 rounded-md border border-cyan-400/30 bg-cyan-400/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-cyan-300">
        <Library className="size-3" aria-hidden />
        Library
      </span>
    );
  }
  const label = prettifySourceId(item.source ?? "source");
  return (
    <span className="inline-flex items-center gap-1 rounded-md border border-primary/30 bg-primary/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-primary">
      <Globe className="size-3" aria-hidden />
      {label}
    </span>
  );
}

/** Loading placeholder matching one federated-search result row. */
export function SearchResultCardSkeleton() {
  return (
    <div className="glass-card flex gap-4 rounded-2xl p-3">
      <div className="h-[120px] w-[80px] shrink-0 animate-pulse rounded-lg bg-surface-2" />
      <div className="flex min-w-0 flex-1 flex-col gap-2 py-1">
        <div className="h-4 w-3/4 animate-pulse rounded bg-surface-2" />
        <div className="h-3 w-1/2 animate-pulse rounded bg-surface-2" />
        <div className="mt-auto h-3 w-1/3 animate-pulse rounded bg-surface-2" />
      </div>
    </div>
  );
}

export function GlobalSearchResultCard({
  item,
  showSourceBadge = true,
}: GlobalSearchResultCardProps) {
  return (
    <Link href={globalSearchHref(item)}>
      <article className="glass-card group flex gap-4 rounded-2xl p-3 transition-all hover:border-primary/30 hover:shadow-glow">
        <div className="relative h-[120px] w-[80px] shrink-0 overflow-hidden rounded-lg bg-surface-2">
          {item.cover_url ? (
            <CoverImage
              src={withCoverWidth(item.cover_url, COVER_SIZES)}
              alt={item.title}
              fill
              className="object-cover transition-transform duration-300 group-hover:scale-105"
              sizes={COVER_SIZES}
              unoptimized
            />
          ) : (
            <div className="flex h-full w-full items-center justify-center text-muted/40">
              <ImageOff className="size-6" aria-hidden />
            </div>
          )}
        </div>

        <div className="flex min-w-0 flex-1 flex-col">
          <h3 className="line-clamp-2 text-base font-semibold text-fg group-hover:text-primary">
            {item.title}
          </h3>

          {item.author ? (
            <p className="mt-0.5 truncate text-sm text-muted">{item.author}</p>
          ) : null}

          <div className="mt-auto flex flex-wrap items-center gap-2 pt-3">
            {showSourceBadge ? <SourceBadge item={item} /> : null}
            {item.chapter_count ? (
              <span className="text-xs text-muted">{item.chapter_count} chapters</span>
            ) : null}
          </div>
        </div>
      </article>
    </Link>
  );
}
