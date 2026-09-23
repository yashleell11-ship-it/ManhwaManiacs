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
 * - Scroll and page keys never reveal it; they hide it, as reading. Tab reveals
 *   it, and so does focus reaching it from the keyboard, so a keyboard can
 *   always reach the controls.
 * - Reaching the end of the strip reveals it (the reader wires that), and
 *   nothing hides it there.
 * - It never auto-hides from under a pointer resting on it, a control in it
 *   that Tab reached, or its page box while it is being typed in.
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
 * Marks an element (and everything inside it) as reader chrome. Hovering it, or
 * focusing a control in it from the keyboard, holds the chrome up; keyboard
 * focus arriving in it reveals the chrome.
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
 * - `navigation`: the keys that scroll or turn pages. Never reveal. They are
 *   reading, so they let go of any focus hold and hide the chrome.
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

/** Just enough of an element to classify it; duck-typed so node can test it. */
interface ElementLike {
  tagName?: unknown;
  type?: unknown;
  isContentEditable?: unknown;
  getAttribute?: unknown;
}

function tagOf(element: ElementLike): string {
  return typeof element.tagName === "string" ? element.tagName.toUpperCase() : "";
}

function roleOf(target: unknown): string | null {
  const getAttribute = (target as ElementLike).getAttribute;
  if (typeof getAttribute !== "function") return null;
  const role: unknown = getAttribute.call(target, "role");
  return typeof role === "string" ? role : null;
}

/** Widgets whose arrow, Home/End or Space keys work the widget, not the page. */
const KEY_WIDGET_ROLES = new Set([
  "combobox",
  "grid",
  "listbox",
  "menu",
  "menubar",
  "menuitem",
  "menuitemcheckbox",
  "menuitemradio",
  "option",
  "radio",
  "radiogroup",
  "searchbox",
  "slider",
  "spinbutton",
  "tab",
  "tablist",
  "textbox",
  "tree",
  "treeitem",
]);

/**
 * Whether a key pressed on `target` works that control rather than the page:
 * a caret moving in the page box, the scrub bar stepping, a slider sliding.
 * Those keys are not reading, whatever `classifyChromeKey` calls them.
 */
export function ownsKeys(target: unknown): boolean {
  if (target == null || typeof target !== "object") return false;
  const element = target as ElementLike;
  const tag = tagOf(element);
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return true;
  if (element.isContentEditable === true) return true;
  const role = roleOf(target);
  return role != null && KEY_WIDGET_ROLES.has(role);
}

const TEXT_INPUT_TYPES = new Set(["", "text", "search", "url", "tel", "email", "password", "number"]);

/**
 * Whether `target` takes typing: a text field, a textarea, or editable text.
 * The page box is one. Focus in it holds the chrome however it got there, or
 * the bar would slide away from under a page number being typed.
 */
export function isTextEntry(target: unknown): boolean {
  if (target == null || typeof target !== "object") return false;
  const element = target as ElementLike;
  const tag = tagOf(element);
  if (tag === "TEXTAREA" || element.isContentEditable === true) return true;
  if (tag === "INPUT") {
    const type = typeof element.type === "string" ? element.type.toLowerCase() : "";
    return TEXT_INPUT_TYPES.has(type);
  }
  const role = roleOf(target);
  return role === "textbox" || role === "searchbox";
}

export interface ChromeAutohide {
  /**
   * The pointer rests on the chrome, a control in it has focus that Tab put
   * there, or its page box has focus.
   */
  held: () => boolean;
  teardown: () => void;
}

/**
 * Wire the rules to real events. `reveal` and `conceal` are the caller's (they
 * differ by mode); this only decides when to call them, and never calls
 * `conceal` while {@link ChromeAutohide.held}.
 *
 * Whether focus in the chrome came from the keyboard is decided by the input
 * before it — a Tab or a pointer press — and not by `:focus-visible`. After a
 * mouse click on Prev, Next or Save the button keeps focus, and the next key
 * press, Space included, makes browsers call that keyboard focus and match
 * `:focus-visible`: one click and a Space pinned the bar for the rest of the
 * chapter.
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
  // What the reader last did that says where focus came from: a Tab, a
  // pointer press, or a scroll or page key (back to the pages).
  let lastInput: "tab" | "pointer" | "reading" | null = null;
  // Focus came into the chrome on a Tab and has not left it since.
  let keyboardFocus = false;

  const held = () => {
    if (pointerOnChrome) return true;
    const active = activeElement();
    if (!active || !withinChrome(active)) return false;
    return keyboardFocus || isTextEntry(active);
  };

  const onPointerDown = (event: Event) => {
    lastInput = "pointer";
    keyboardFocus = false;
    const { target } = event;
    // Using the bar is activity: in cinema mode it restarts the idle timer.
    // Hidden, the chrome takes no pointer, so this never brings it back.
    if (withinChrome(target)) reveal();
  };

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
    const kind = classifyChromeKey(event as KeyboardEvent);
    if (kind === "focus") {
      lastInput = "tab";
      reveal();
      return;
    }
    if (kind !== "navigation" || ownsKeys(event.target)) return;
    // Reading. Whatever focus is in the chrome, the reader has gone back to
    // the pages.
    lastInput = "reading";
    keyboardFocus = false;
    if (!atEnd() && !held()) conceal();
  };

  const onFocusIn = (event: Event) => {
    if (!withinChrome(event.target)) return;
    if (lastInput === "tab") {
      keyboardFocus = true;
      reveal();
    } else if (lastInput === null) {
      // Nothing says how it got here (a screen reader, say): show the bar it
      // landed in, but do not hold it.
      reveal();
    }
    // After a click, focus in the chrome is the click's, and the pointer has
    // already shown the bar. After a scroll key the reader is on the pages.
    // Either way, the same focus coming back with the window is not a reason
    // to bring the bar up.
  };

  const onFocusOut = (event: Event) => {
    if (!withinChrome((event as FocusEvent).relatedTarget)) keyboardFocus = false;
  };

  const onScroll = () => {
    if (!scroller || !run) return;
    const step = followScroll(run, scroller.scrollTop);
    run = step.run;
    if (step.conceal && !atEnd() && !held()) conceal();
  };

  // Presses and keys in the capture phase: the chrome stops clicks from
  // bubbling out of it, and the reader must still see every one.
  const passive = { passive: true } as const;
  const early = { passive: true, capture: true } as const;
  events.addEventListener("pointerdown", onPointerDown, early);
  events.addEventListener("keydown", onKeyDown, early);
  events.addEventListener("pointermove", onPointerMove, passive);
  events.addEventListener("pointerover", onPointerOver, passive);
  events.addEventListener("pointerout", onPointerOut, passive);
  events.addEventListener("focusin", onFocusIn, passive);
  events.addEventListener("focusout", onFocusOut, passive);
  scroller?.addEventListener("scroll", onScroll, passive);

  return {
    held,
    teardown() {
      events.removeEventListener("pointerdown", onPointerDown, early);
      events.removeEventListener("keydown", onKeyDown, early);
      events.removeEventListener("pointermove", onPointerMove);
      events.removeEventListener("pointerover", onPointerOver);
      events.removeEventListener("pointerout", onPointerOut);
      events.removeEventListener("focusin", onFocusIn);
      events.removeEventListener("focusout", onFocusOut);
      scroller?.removeEventListener("scroll", onScroll);
    },
  };
}
