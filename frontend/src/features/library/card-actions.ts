/**
 * How a library card's corner actions (Follow/Unfollow, favourite) show.
 *
 * From `sm` up they wait for the pointer, so a wall of covers is not a wall of
 * buttons. They used to wait for the pointer ONLY: nothing revealed them to the
 * keyboard, and the global `:focus-visible` ring is drawn on the button itself,
 * so opacity 0 hid the ring too. Every card on the browse grid put two
 * invisible tab stops after its link, the first of them "Unfollow" — Enter,
 * pressed expecting the next card, took the series out of the library.
 *
 * Focus now reveals them exactly as hover does: the focused button itself, and
 * its sibling while focus is anywhere in the card. The select checkbox beside
 * them already did the first half.
 *
 * Pure so the node test environment can hold it.
 */
export function cardActionVisibility(pinned: boolean): string {
  return pinned
    ? "opacity-100"
    : "opacity-100 sm:opacity-0 sm:group-hover:opacity-100 sm:group-focus-within:opacity-100 sm:focus-visible:opacity-100";
}
