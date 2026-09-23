/**
 * What a source's browse page does about its next page — load it on scroll,
 * offer to retry it, or show the whole catalogue as failed.
 *
 * A next page that failed used to do all three wrong at once. The infinite
 * query keeps `hasNextPage` from the last page that DID load, so the scroll
 * sentinel went straight back to asking for the page that had just failed —
 * about twice a second, forever, each one a live connector request against the
 * source's politeness budget and the user's own `sources` rate bucket. And
 * because the query's `error` was set, the grid swapped every series already on
 * screen for "Could not load source catalog", which shrank the page and kept the
 * sentinel in view to fire again.
 *
 * Pure and free of React so the vitest gate (node, no DOM) can hold it.
 */

export interface BrowsePagingInput {
  /** Series already on screen, across every page that loaded. */
  itemCount: number;
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
  /** The query's error came from asking for the NEXT page, not the first. */
  isFetchNextPageError: boolean;
  /** Whether the query is in error at all. */
  hasError: boolean;
}

export interface BrowsePaging {
  /** The scroll sentinel may ask for the next page by itself. */
  autoLoad: boolean;
  /** Replace the grid with the error state: there is nothing loaded to keep. */
  showFullError: boolean;
  /** Offer "Couldn't load more · Retry" under the series already shown. */
  showLoadMoreRetry: boolean;
  /**
   * What the full error state's retry does. `next-page` asks for the one page
   * that failed; `refetch` reloads the query — and on an infinite query that
   * is EVERY loaded page, one live request each, so it is only for a query
   * whose first page is what failed.
   */
  retry: "next-page" | "refetch";
}

export function browsePaging({
  itemCount,
  hasNextPage,
  isFetchingNextPage,
  isFetchNextPageError,
  hasError,
}: BrowsePagingInput): BrowsePaging {
  const hasItems = itemCount > 0;
  return {
    // A failed next page stops here until the reader asks again. The error
    // clears only when a retry succeeds, which is what re-arms scrolling.
    autoLoad: hasNextPage && !isFetchNextPageError,
    showFullError: hasError && !hasItems,
    showLoadMoreRetry: hasItems && isFetchNextPageError && !isFetchingNextPage,
    retry: isFetchNextPageError ? "next-page" : "refetch",
  };
}
