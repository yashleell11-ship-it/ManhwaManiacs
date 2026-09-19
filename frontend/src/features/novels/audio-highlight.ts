/**
 * Light up the sentence being spoken, without re-rendering the page.
 *
 * `timeupdate` fires about four times a second. Driving that through React
 * state would re-render a page of prose — several hundred nodes — four times a
 * second, on the one screen where a stutter is least acceptable and where a
 * scroll-jank fix was already needed once. So the element is found by
 * `data-segment` and its class is toggled directly. React owns the text; this
 * owns one attribute on one node at a time.
 */

const ACTIVE = "novel-speaking";

export type HighlightHandle = {
  /** Move the highlight, or clear it with null. */
  set(segment: number | null): void;
  /** Remove the highlight and forget the node. */
  dispose(): void;
};

export function createHighlighter(
  root: () => HTMLElement | null,
  options: { scroll?: boolean } = {},
): HighlightHandle {
  let current: HTMLElement | null = null;
  let currentIndex: number | null = null;

  const clear = () => {
    if (current) current.classList.remove(ACTIVE);
    current = null;
    currentIndex = null;
  };

  return {
    set(segment) {
      if (segment === null) {
        clear();
        return;
      }
      // Cheapest possible no-op: the playhead reports the same segment many
      // times before it moves on, and re-querying the DOM each time would be
      // the whole cost of this feature.
      if (segment === currentIndex) return;

      const container = root();
      if (!container) return;
      const next = container.querySelector<HTMLElement>(
        `[data-segment="${segment}"]`,
      );
      if (!next) {
        // The text no longer has this segment — a refetched chapter, or a
        // timing map from a different render. Clearing beats lighting up
        // whatever happens to sit there now.
        clear();
        return;
      }
      if (current) current.classList.remove(ACTIVE);
      next.classList.add(ACTIVE);
      current = next;
      currentIndex = segment;

      if (options.scroll) {
        // "nearest" so a reader who has scrolled ahead is not yanked back on
        // every sentence; it only moves when the line has actually left view.
        next.scrollIntoView({ block: "nearest", behavior: "smooth" });
      }
    },
    dispose: clear,
  };
}

export const ACTIVE_CLASS = ACTIVE;
