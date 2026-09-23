"use client";

import { memo } from "react";
import Link from "next/link";
import { GRID_ITEM_ATTRIBUTE } from "@/lib/keyboard";
import { sourceImageUrl } from "../api";
import type { SourceSeriesSummary } from "../types";
import { CoverImage } from "@/components/ui/cover-image";

/**
 * The catalog grid's cell. `SourceSeriesGrid` is `grid-cols-2 gap-4` inside the
 * view's `p-6`, which is `calc(50vw - 32px)` — 155px on a 375px phone, the box
 * the 1.6 MB covers were being painted into. Above `sm` the grid climbs to six
 * columns, so the wide branch names the widest cell rather than tracking each
 * breakpoint: over-asking on a desktop costs one rung of the server's ladder,
 * under-asking is a blurry catalog.
 *
 * This is both the browser's `sizes` hint and the width the cover proxy renders
 * to — see `lib/cover-url.ts`.
 */
const COVER_SIZES = "(max-width: 639px) calc(50vw - 32px), 260px";

/**
 * The tile behind each cover: the card fill and edge, with no backdrop blur.
 *
 * This used to be `<Card className="… border-transparent bg-transparent …">`.
 * `Card` is `.glass-card`, which is unlayered CSS, and unlayered CSS beats
 * Tailwind's layered utilities, so the transparent classes never applied: every
 * cell painted the translucent card fill and edge, and every cell was also its
 * own `backdrop-filter` surface. A catalog shows eighteen of them at once and
 * infinite scroll only adds more, so the browser re-read and re-blurred the
 * page behind each one on every scroll frame. What sits behind them is the
 * shell's flat or smoothly graded background, which looks the same blurred, so
 * that work bought nothing.
 *
 * These utilities are the declarations `.glass-card` resolved to on this
 * element — fill, edge width, edge colour, `rounded-xl`, the colour transition
 * — minus the blur. Same pixels, one fewer render pass per cell.
 */
const SOURCE_CARD_TILE =
  "group overflow-hidden rounded-xl border-(length:--shape-edge-width) border-(color:--shape-card-edge) bg-(--shape-card-fill) transition-colors duration-200";

interface SourceSeriesCardProps {
  sourceId: string;
  series: SourceSeriesSummary;
}

/**
 * Memoised because the catalog only ever grows: each page that lands re-renders
 * the grid, and TanStack keeps every already-loaded series object by identity,
 * so the cards already on screen can skip the render instead of reconciling
 * their link and cover again.
 */
export const SourceSeriesCard = memo(function SourceSeriesCard({
  sourceId,
  series,
}: SourceSeriesCardProps) {
  return (
    <Link
      href={`/sources/${sourceId}/series/${encodeURIComponent(series.id)}`}
      // Cell of the keyboard-navigable catalog grid; the ring is what makes
      // arrow-key movement legible.
      {...{ [GRID_ITEM_ATTRIBUTE]: "" }}
      // `cv-card`: a cell scrolled well out of view skips layout and paint.
      // The grid is never trimmed, so after a few pages most cells are off
      // screen.
      className="cv-card block rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/70 focus-visible:ring-offset-2 focus-visible:ring-offset-bg"
    >
      <div className={SOURCE_CARD_TILE}>
        <div className="relative aspect-[2/3] w-full overflow-hidden rounded-2xl border border-border bg-surface-2 transition duration-200 group-hover:border-primary/40 group-hover:ring-2 group-hover:ring-primary/20">
          <CoverImage
            src={sourceImageUrl(series.cover_url, COVER_SIZES)}
            alt={series.title}
            fill
            className="object-cover transition-transform duration-200 group-hover:scale-105"
            sizes={COVER_SIZES}
            unoptimized
          />
        </div>
        <p className="mt-2 line-clamp-2 px-0.5 text-sm font-medium leading-snug text-fg">
          {series.title}
        </p>
      </div>
    </Link>
  );
});
