"use client";

import { useEffect, useLayoutEffect, useRef } from "react";

/**
 * Calls `onLoadMore` when the returned sentinel comes within 480px of view.
 *
 * `enabled` is the only thing that stops it. A caller whose next page failed
 * must pass `false` until the reader retries — this hook cannot tell a failed
 * page from a finished one, and without that gate it asks again on every
 * falling edge of `isLoading` (see `features/sources/browse-paging.ts`).
 */
export function useLoadMoreOnScroll(
  enabled: boolean,
  onLoadMore: () => void,
  isLoading: boolean,
) {
  const sentinelRef = useRef<HTMLDivElement>(null);
  // Callers build `onLoadMore` from a query object that is new on every
  // render; read it through a ref so a re-render alone never rebuilds the
  // observer (a new observer always delivers an entry of its own).
  const onLoadMoreRef = useRef(onLoadMore);
  useLayoutEffect(() => {
    onLoadMoreRef.current = onLoadMore;
  });

  useEffect(() => {
    if (!enabled) {
      return;
    }
    const element = sentinelRef.current;
    if (!element) {
      return;
    }

    // Rebuilt when `isLoading` falls on purpose. An observer only reports a
    // CHANGE in intersection, so after a page lands with the sentinel still
    // inside the margin (a tall window, a short page) nothing new would ever
    // arrive; the fresh observer's first entry is what asks for the next one.
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting && !isLoading) {
          onLoadMoreRef.current();
        }
      },
      { rootMargin: "480px" },
    );

    observer.observe(element);
    return () => observer.disconnect();
  }, [enabled, isLoading]);

  return sentinelRef;
}
