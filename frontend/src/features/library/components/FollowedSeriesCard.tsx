"use client";

import Link from "next/link";
import { libraryCoverUrl } from "../api";
import { followedCardSubtitle, newCountLabel, readStateNewCount } from "../read-state";
import type { FollowedSeries } from "../types";
import { CoverImage } from "@/components/ui/cover-image";

/**
 * The shelf grid's cell: `grid-cols-3 gap-x-3` inside the view's `px-5`, which
 * is `calc(33.33vw - 21px)` — 104px on a 375px phone. The widest it reaches is
 * the 8-up `lg` row. This string is both the browser's `sizes` hint and what
 * the cover proxy renders to (`lib/cover-url.ts`), so it states the real cell
 * rather than a round `vw`.
 */
const COVER_SIZES = "(max-width: 639px) calc(33.33vw - 21px), 180px";

/**
 * A cover-first Library card for one followed series. Cover, title, and a single
 * muted meta line saying where the reader is ("Not started", "Ch 5 of 120"),
 * with an "N new" pill on the cover for chapters past the furthest one read.
 */
export function FollowedSeriesCard({ series }: { series: FollowedSeries }) {
  const subtitle = followedCardSubtitle(series);
  const fresh = newCountLabel(readStateNewCount(series.read_state));

  return (
    <Link
      href={`/library/${series.id}`}
      className="group block rounded-xl outline-none focus-visible:ring-2 focus-visible:ring-primary"
    >
      <div className="relative aspect-[2/3] w-full overflow-hidden rounded-xl bg-surface-2">
        <CoverImage
          src={libraryCoverUrl(series.cover_url, COVER_SIZES)}
          alt={series.title}
          fill
          className="object-cover transition-transform duration-300 group-hover:scale-105"
          sizes={COVER_SIZES}
          unoptimized
        />
        {fresh ? (
          <span className="absolute right-2 top-2 rounded-full bg-primary px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-primary-fg">
            {fresh}
          </span>
        ) : null}
      </div>

      <h3 className="mt-2 line-clamp-2 text-sm font-semibold leading-tight text-fg">
        {series.title}
      </h3>
      {subtitle ? (
        <p className="mt-0.5 truncate text-xs text-muted">{subtitle}</p>
      ) : null}
    </Link>
  );
}
