import type { StripPosition } from "./strip";
import type { ReadingDirection, ReadingMode } from "./types";

/**
 * Page numbers shown together on one screen, in reading order (lowest first).
 * `spreadDisplayOrder` turns a view into DOM order.
 */
export type PageView = number[];

/**
 * Pair pages into double-page spreads.
 *
 * Manga convention: page 1 is a cover and stands alone, so the physical
 * spreads that follow — (2,3), (4,5), … — line up the way the book was drawn.
 * Pairing from page 1 instead puts every spread one page out of phase and
 * splits every drawn double-page illustration down the middle.
 */
export function buildSpreads(pageCount: number, coverAlone = true): PageView[] {
  if (!Number.isFinite(pageCount) || pageCount < 1) return [];
  const total = Math.floor(pageCount);
  const views: PageView[] = [];
  let page = 1;

  if (coverAlone) {
    views.push([1]);
    page = 2;
  }

  for (; page <= total; page += 2) {
    views.push(page + 1 <= total ? [page, page + 1] : [page]);
  }

  return views;
}

/**
 * Every screenful of the chapter for a paged reading mode. `continuous` has no
 * discrete screens; it is treated as one page per view so callers that track a
 * view index (the scrubber, the keyboard) keep working across a mode switch.
 */
export function buildPageViews(
  pageCount: number,
  mode: ReadingMode,
  coverAlone = true,
): PageView[] {
  if (!Number.isFinite(pageCount) || pageCount < 1) return [];
  if (mode === "double") return buildSpreads(pageCount, coverAlone);
  return Array.from({ length: Math.floor(pageCount) }, (_, index) => [index + 1]);
}

/**
 * Reading order → DOM order. A right-to-left spread puts the earlier page on
 * the RIGHT, so the eye lands on it first and travels leftward.
 */
export function spreadDisplayOrder(
  view: readonly number[],
  direction: ReadingDirection,
): number[] {
  return direction === "rtl" ? [...view].reverse() : [...view];
}

/** Index of the view holding `page`, clamped to the ends for out-of-range pages. */
export function findViewIndex(views: readonly PageView[], page: number): number {
  if (views.length === 0) return 0;
  const index = views.findIndex((view) => view.includes(page));
  if (index !== -1) return index;
  return page < views[0][0] ? 0 : views.length - 1;
}

/** The page a view is "on" for navigation: the first one read. */
export function viewLeadPage(view: readonly number[]): number {
  if (view.length === 0) return 1;
  return Math.min(...view);
}

/**
 * What a paged mode reports for progress while `view` is on screen, or `null`
 * when there is nothing to report.
 *
 * The strip reports its own position every scroll frame; the paged modes have
 * no strip, so this is their report — one per screen, fed to the same tracker
 * so furthest-wins and completion apply unchanged. The page is the view's
 * LAST, not its lead: both pages of a spread are on screen, and reporting the
 * lead would leave a chapter that ends on a spread one page short of complete
 * for ever. `continuous` gives `null` because the strip already reports.
 */
export function pagedProgressPosition(
  mode: ReadingMode,
  chapterKey: string | null | undefined,
  view: readonly number[] | undefined,
  pageCount: number,
): StripPosition | null {
  if (mode === "continuous" || !chapterKey || !view || view.length === 0) return null;
  if (!Number.isFinite(pageCount) || pageCount < 1) return null;
  return {
    chapterKey,
    pageNumber: Math.min(pageCount, Math.max(...view)),
    pageCount,
  };
}

/** Clamp a view index into range, so paging past either end is a no-op. */
export function clampViewIndex(views: readonly PageView[], index: number): number {
  if (views.length === 0) return 0;
  return Math.min(views.length - 1, Math.max(0, index));
}
