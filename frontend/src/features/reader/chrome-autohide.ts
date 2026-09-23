/**
 * When the reader chrome (bottom control bar, download pill) gets out of the
 * way, and when it comes back.
 *
 * The chrome used to count ANY pointer move, key press or scroll as "activity"
 * that brought it back, and outside cinema mode nothing hid it at all while
 * reading. So Space-to-scroll left it parked over the pages, and one nudge of
 * the mouse popped it up again. The rules now, in both modes:
 *
 * - Reading hides it: a downward scroll of {@link CHROME_HIDE_SCROLL_PX} in the
 *   strip (wheel, Space, PageDown, arrows, touch, auto-scroll all scroll), or a
 *   page turn in the paged modes. Scrolling back up does NOT bring it back.
 * - A mouse or pen reveals it only by moving into the band where the chrome
 *   lives: the bottom {@link CHROME_BOTTOM_BAND_PX} or the top
 *   {@link CHROME_TOP_BAND_PX} of the reader. Touch never reveals by moving.
 * - Scroll and page keys never reveal it; Tab does, and so does focus landing
 *   inside it, so a keyboard can always reach the controls.
 * - Reaching the end of the strip reveals it (the reader wires that).
 * - It never auto-hides from under a pointer resting on it or a control inside
 *   it that has keyboard focus.
 *
 * The decisions are pure functions; {@link installChromeAutohide} wires them to
 * events against plain `EventTarget`s, so all of it runs under node.
 */

/** Downward scroll, in CSS px, that counts as reading on and hides the chrome. */
export const CHROME_HIDE_SCROLL_PX = 24;

/** Height of the band at the reader's bottom edge where the control bar lives. */
export const CHROME_BOTTOM_BAND_PX = 120;

/** Height of the band at the reader's top edge. */
export const CHROME_TOP_BAND_PX = 80;

/**
 * Marks an element (and everything inside it) as reader chrome. Hovering or
 * keyboard-focusing anything under it holds the chrome up; focus arriving in
 * it reveals the chrome.
 */
export const READER_CHROME_SELECTOR = "[data-reader-chrome]";

/** The reader's vertical extent on screen, in client coordinates. */
export interface ReaderViewport {
  top: number;
  bottom: number;
}

/** Which reveal band, if any, a pointer at `clientY` is in. Past an edge counts. */
export function revealBand(
  clientY: number,
  viewport: ReaderViewport,
): "top" | "bottom" | null {
  if (clientY >= viewport.bottom - CHROME_BOTTOM_BAND_PX) return "bottom";
  if (clientY <= viewport.top + CHROME_TOP_BAND_PX) return "top";
  return null;
}

export interface PointerSample {
  pointerType: string;
  x: number;
  y: number;
}

/**
 * Whether a pointer move reveals the chrome: a mouse or pen that really moved
 * (a repeat of the last position is a synthetic move, not the user) and is now
 * in a reveal band. Anywhere else on the page, movement is ignored.
 */
export function pointerRevealsChrome(
  sample: PointerSample,
  previous: { x: number; y: number } | null,
  viewport: ReaderViewport,
): boolean {
  if (sample.pointerType !== "mouse" && sample.pointerType !== "pen") return false;
  if (previous && previous.x === sample.x && previous.y === sample.y) return false;
  return revealBand(sample.y, viewport) != null;
}

/** Where the strip was, and how far it has travelled down since it last went up. */
export interface ScrollRun {
  top: number;
  down: number;
}

/**
 * Feed one scroll position. Downward travel accumulates until it reaches
 * {@link CHROME_HIDE_SCROLL_PX}, which conceals and starts a new run. Any
 * upward movement restarts the run and never conceals — or reveals.
 */
export function followScroll(
  run: ScrollRun,
  scrollTop: number,
): { run: ScrollRun; conceal: boolean } {
  const delta = scrollTop - run.top;
  if (delta < 0) return { run: { top: scrollTop, down: 0 }, conceal: false };
  const down = run.down + delta;
  if (down >= CHROME_HIDE_SCROLL_PX) return { run: { top: scrollTop, down: 0 }, conceal: true };
  return { run: { top: scrollTop, down }, conceal: false };
}

/**
 * What a key press means to the chrome.
 *
 * - `focus`: Tab / Shift+Tab, moving keyboard focus — reveals, so the bar can
 *   take focus (hidden, it is out of the Tab order).
 * - `navigation`: the keys that scroll or turn pages. Never reveal; if they
 *   move the strip, the scroll hides the chrome.
 * - `other`: everything else, reader shortcuts included. Their own action
 *   decides (C toggles cinema, Escape peels it); the key itself is not
 *   activity.
 */
export type ChromeKey = "focus" | "navigation" | "other";

const NAVIGATION_KEYS = new Set([
  " ",
  "Spacebar",
  "PageDown",
  "PageUp",
  "ArrowDown",
  "ArrowUp",
  "ArrowLeft",
  "ArrowRight",
  "Home",
  "End",
]);

export function classifyChromeKey(event: {
  key: string;
  altKey?: boolean;
  ctrlKey?: boolean;
  metaKey?: boolean;
}): ChromeKey {
  if (event.key === "Tab") {
    // Ctrl/⌘/Alt+Tab switch tabs or windows; they never move focus in here.
    return event.altKey || event.ctrlKey || event.metaKey ? "other" : "focus";
  }
  return NAVIGATION_KEYS.has(event.key) ? "navigation" : "other";
}

/** A paged-mode page turn: the page shown changed from one page to another. */
export function pageTurnConceals(previous: string | null, next: string | null): boolean {
  return previous != null && next != null && previous !== next;
}

/** Whether an event target or element sits inside reader chrome. */
export function withinChrome(target: unknown): boolean {
  const closest = (target as { closest?: unknown } | null)?.closest;
  if (typeof closest !== "function") return false;
  return closest.call(target, READER_CHROME_SELECTOR) != null;
}

/**
 * Keyboard focus is inside the chrome. `:focus-visible` rather than any focus:
 * a mouse click leaves focus on the button it clicked, and holding the chrome
 * up for that would bring back the bug this module exists to fix.
 */
function keyboardFocusInChrome(active: Element | null): boolean {
  if (!active || !withinChrome(active)) return false;
  try {
    return active.matches(":focus-visible");
  } catch {
    // No `:focus-visible` support: any focus holds, per the plain rule.
    return true;
  }
}

export interface ChromeAutohide {
  /** The pointer rests on the chrome, or a control in it has keyboard focus. */
  held: () => boolean;
  teardown: () => void;
}

/**
 * Wire the rules to real events. `reveal` and `conceal` are the caller's (they
 * differ by mode); this only decides when to call them, and never calls
 * `conceal` while {@link ChromeAutohide.held}.
 */
export function installChromeAutohide({
  events,
  scroller,
  viewport,
  activeElement,
  atEnd,
  reveal,
  conceal,
}: {
  /** Where pointer, key and focus events arrive — the window. */
  events: EventTarget;
  /** The strip's scroll container, when there is one. */
  scroller: (EventTarget & { scrollTop: number }) | null;
  /** The reader's current vertical extent, for the reveal bands. */
  viewport: () => ReaderViewport;
  /** `document.activeElement`. */
  activeElement: () => Element | null;
  /** At the end of the strip, where the chrome stays up. */
  atEnd: () => boolean;
  reveal: () => void;
  conceal: () => void;
}): ChromeAutohide {
  let pointerOnChrome = false;
  let lastPoint: { x: number; y: number } | null = null;
  let run: ScrollRun | null = scroller ? { top: scroller.scrollTop, down: 0 } : null;

  const held = () => pointerOnChrome || keyboardFocusInChrome(activeElement());

  const onPointerMove = (event: Event) => {
    const { pointerType, clientX, clientY } = event as PointerEvent;
    const sample = { pointerType, x: clientX, y: clientY };
    const reveals = pointerRevealsChrome(sample, lastPoint, viewport());
    if (pointerType !== "touch") lastPoint = { x: clientX, y: clientY };
    if (reveals) reveal();
  };

  // Hover is tracked from boundary events, not `:hover`: a touch leaves a
  // sticky hover on whatever it tapped, which would hold the chrome for good.
  const onPointerOver = (event: Event) => {
    if ((event as PointerEvent).pointerType === "touch") return;
    pointerOnChrome = withinChrome(event.target);
  };
  const onPointerOut = (event: Event) => {
    // No related target: the pointer left the window.
    if ((event as PointerEvent).relatedTarget == null) pointerOnChrome = false;
  };

  const onKeyDown = (event: Event) => {
    if (classifyChromeKey(event as KeyboardEvent) === "focus") reveal();
  };

  const onFocusIn = (event: Event) => {
    if (withinChrome(event.target)) reveal();
  };

  const onScroll = () => {
    if (!scroller || !run) return;
    const step = followScroll(run, scroller.scrollTop);
    run = step.run;
    if (step.conceal && !atEnd() && !held()) conceal();
  };

  const passive = { passive: true } as const;
  events.addEventListener("pointermove", onPointerMove, passive);
  events.addEventListener("pointerover", onPointerOver, passive);
  events.addEventListener("pointerout", onPointerOut, passive);
  events.addEventListener("keydown", onKeyDown, passive);
  events.addEventListener("focusin", onFocusIn, passive);
  scroller?.addEventListener("scroll", onScroll, passive);

  return {
    held,
    teardown() {
      events.removeEventListener("pointermove", onPointerMove);
      events.removeEventListener("pointerover", onPointerOver);
      events.removeEventListener("pointerout", onPointerOut);
      events.removeEventListener("keydown", onKeyDown);
      events.removeEventListener("focusin", onFocusIn);
      scroller?.removeEventListener("scroll", onScroll);
    },
  };
}
