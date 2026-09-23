import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  CHROME_BOTTOM_BAND_PX,
  CHROME_HIDE_SCROLL_PX,
  CHROME_TOP_BAND_PX,
  classifyChromeKey,
  followScroll,
  installChromeAutohide,
  pageTurnConceals,
  pointerRevealsChrome,
  revealBand,
  withinChrome,
  type ChromeAutohide,
  type ScrollRun,
} from "./chrome-autohide";

/**
 * The owner's bug: reading with Space left the bottom bar parked over the
 * pages, and one nudge of the mouse brought it back. Every pointer move, key
 * and scroll used to count as "activity" that showed the chrome, and outside
 * cinema mode nothing hid it while reading.
 */

// A reader below a 56px app bar, in an 800px-tall window.
const VIEWPORT = { top: 56, bottom: 800 };

describe("revealBand", () => {
  it("is the bottom band up to 120px above the reader's bottom edge", () => {
    expect(CHROME_BOTTOM_BAND_PX).toBe(120);
    expect(revealBand(800 - 120, VIEWPORT)).toBe("bottom");
    expect(revealBand(799, VIEWPORT)).toBe("bottom");
    expect(revealBand(800 - 121, VIEWPORT)).toBeNull();
  });

  it("is the top band down to 80px below the reader's top edge, not the window's", () => {
    expect(CHROME_TOP_BAND_PX).toBe(80);
    expect(revealBand(56 + 80, VIEWPORT)).toBe("top");
    expect(revealBand(56 + 81, VIEWPORT)).toBeNull();
  });

  it("counts a pointer past either edge as in its band", () => {
    expect(revealBand(20, VIEWPORT)).toBe("top");
    expect(revealBand(900, VIEWPORT)).toBe("bottom");
  });

  it("ignores the whole middle of the page", () => {
    for (let y = 56 + 81; y < 800 - 120; y += 17) expect(revealBand(y, VIEWPORT)).toBeNull();
  });
});

describe("pointerRevealsChrome", () => {
  it("reveals for a mouse or a pen that moves into a band", () => {
    expect(pointerRevealsChrome({ pointerType: "mouse", x: 300, y: 760 }, null, VIEWPORT)).toBe(
      true,
    );
    expect(
      pointerRevealsChrome({ pointerType: "pen", x: 300, y: 70 }, { x: 300, y: 400 }, VIEWPORT),
    ).toBe(true);
  });

  it("ignores a mouse moving anywhere else", () => {
    expect(
      pointerRevealsChrome({ pointerType: "mouse", x: 310, y: 400 }, { x: 300, y: 400 }, VIEWPORT),
    ).toBe(false);
  });

  it("never reveals for touch, even in a band", () => {
    expect(pointerRevealsChrome({ pointerType: "touch", x: 300, y: 790 }, null, VIEWPORT)).toBe(
      false,
    );
  });

  it("ignores a move that did not move (a synthetic event at the same spot)", () => {
    expect(
      pointerRevealsChrome({ pointerType: "mouse", x: 300, y: 760 }, { x: 300, y: 760 }, VIEWPORT),
    ).toBe(false);
  });
});

describe("followScroll", () => {
  function feed(start: number, positions: number[]): boolean[] {
    let run: ScrollRun = { top: start, down: 0 };
    return positions.map((top) => {
      const step = followScroll(run, top);
      run = step.run;
      return step.conceal;
    });
  }

  it("conceals once the strip has gone ~24px down, even in small steps", () => {
    expect(CHROME_HIDE_SCROLL_PX).toBe(24);
    expect(feed(1000, [1008, 1016, 1023, 1024])).toEqual([false, false, false, true]);
  });

  it("conceals on one Space / PageDown jump", () => {
    expect(feed(1000, [1000 + 700])).toEqual([true]);
  });

  it("never conceals, or reveals, on the way up", () => {
    expect(feed(5000, [4900, 4000, 3000, 10])).toEqual([false, false, false, false]);
  });

  it("starts the run over after going up, so jitter does not add up", () => {
    expect(feed(1000, [1020, 1010, 1030])).toEqual([false, false, false]);
    expect(feed(1000, [1020, 1010, 1034])).toEqual([false, false, true]);
  });

  it("needs a fresh 24px after concealing", () => {
    expect(feed(0, [30, 40, 53, 54])).toEqual([true, false, false, true]);
  });

  it("keeps the run through a scroll event that did not move", () => {
    expect(feed(0, [20, 20, 24])).toEqual([false, false, true]);
  });
});

describe("classifyChromeKey", () => {
  it("treats Tab and Shift+Tab as moving focus toward the chrome", () => {
    expect(classifyChromeKey({ key: "Tab" })).toBe("focus");
    expect(classifyChromeKey({ key: "Tab", altKey: false, ctrlKey: false })).toBe("focus");
  });

  it("does not treat Ctrl/Cmd/Alt+Tab (switching tabs or windows) as focus", () => {
    expect(classifyChromeKey({ key: "Tab", ctrlKey: true })).toBe("other");
    expect(classifyChromeKey({ key: "Tab", metaKey: true })).toBe("other");
    expect(classifyChromeKey({ key: "Tab", altKey: true })).toBe("other");
  });

  it("knows the scroll and page keys as navigation", () => {
    for (const key of [
      " ",
      "PageDown",
      "PageUp",
      "ArrowDown",
      "ArrowUp",
      "ArrowLeft",
      "ArrowRight",
      "Home",
      "End",
    ]) {
      expect(classifyChromeKey({ key })).toBe("navigation");
    }
  });

  it("leaves the reader's letter shortcuts to their own actions", () => {
    for (const key of ["j", "k", "a", "d", "c", "f", "b", "Escape"]) {
      expect(classifyChromeKey({ key })).toBe("other");
    }
  });
});

describe("pageTurnConceals", () => {
  it("is a change from one page on screen to another", () => {
    expect(pageTurnConceals("12#3", "12#4")).toBe(true);
    expect(pageTurnConceals("12#9", "13#1")).toBe(true);
  });

  it("is not the first page shown, a re-render, or a switch into or out of the strip", () => {
    expect(pageTurnConceals(null, "12#3")).toBe(false);
    expect(pageTurnConceals("12#3", "12#3")).toBe(false);
    expect(pageTurnConceals("12#3", null)).toBe(false);
  });
});

/** A stand-in element: `closest` answers whether it sits in the chrome. */
function element({ chrome, focusVisible = false }: { chrome: boolean; focusVisible?: boolean }) {
  return Object.assign(new EventTarget(), {
    closest: (selector: string) => (chrome && selector === "[data-reader-chrome]" ? {} : null),
    matches: (selector: string) => selector === ":focus-visible" && focusVisible,
  });
}

describe("withinChrome", () => {
  it("finds the chrome marker on an ancestor", () => {
    expect(withinChrome(element({ chrome: true }))).toBe(true);
    expect(withinChrome(element({ chrome: false }))).toBe(false);
  });

  it("is false for targets that are not elements", () => {
    expect(withinChrome(null)).toBe(false);
    expect(withinChrome(new EventTarget())).toBe(false);
  });
});

describe("installChromeAutohide", () => {
  let events: EventTarget;
  let scroller: EventTarget & { scrollTop: number };
  let active: ReturnType<typeof element> | null;
  let atEnd: boolean;
  let reveal: ReturnType<typeof vi.fn<() => void>>;
  let conceal: ReturnType<typeof vi.fn<() => void>>;
  let autohide: ChromeAutohide;

  function pointer(
    type: "pointermove" | "pointerover" | "pointerout",
    init: {
      pointerType?: string;
      x?: number;
      y?: number;
      target?: EventTarget | null;
      relatedTarget?: EventTarget | null;
    },
  ) {
    const event = Object.assign(new Event(type), {
      pointerType: init.pointerType ?? "mouse",
      clientX: init.x ?? 300,
      clientY: init.y ?? 400,
      relatedTarget: init.relatedTarget ?? null,
    });
    // Dispatched at the target and bubbled, the way a window listener sees it.
    Object.defineProperty(event, "target", { value: init.target ?? null });
    events.dispatchEvent(event);
  }

  function key(name: string, modifiers: { ctrlKey?: boolean } = {}) {
    events.dispatchEvent(Object.assign(new Event("keydown"), { key: name, ...modifiers }));
  }

  function focusIn(target: EventTarget) {
    const event = new Event("focusin");
    Object.defineProperty(event, "target", { value: target });
    events.dispatchEvent(event);
  }

  function scrollTo(top: number) {
    scroller.scrollTop = top;
    scroller.dispatchEvent(new Event("scroll"));
  }

  beforeEach(() => {
    events = new EventTarget();
    scroller = Object.assign(new EventTarget(), { scrollTop: 2000 });
    active = null;
    atEnd = false;
    reveal = vi.fn<() => void>();
    conceal = vi.fn<() => void>();
    autohide = installChromeAutohide({
      events,
      scroller,
      viewport: () => VIEWPORT,
      activeElement: () => active as unknown as Element | null,
      atEnd: () => atEnd,
      reveal,
      conceal,
    });
  });

  afterEach(() => autohide.teardown());

  it("does not reveal for mouse movement over the pages", () => {
    for (let x = 100; x < 700; x += 25) pointer("pointermove", { x, y: 400 });
    expect(reveal).not.toHaveBeenCalled();
  });

  it("reveals when the mouse reaches the bottom band, where the bar lives", () => {
    pointer("pointermove", { y: 400 });
    pointer("pointermove", { y: 700 });
    expect(reveal).toHaveBeenCalledTimes(1);
  });

  it("reveals at the top band too", () => {
    pointer("pointermove", { y: 100 });
    expect(reveal).toHaveBeenCalledTimes(1);
  });

  it("does not reveal for a finger dragging through the bottom band", () => {
    pointer("pointermove", { pointerType: "touch", y: 790 });
    expect(reveal).not.toHaveBeenCalled();
  });

  it("does not reveal for Space, PageDown or the arrow keys", () => {
    for (const name of [" ", "PageDown", "ArrowDown", "ArrowUp", "End"]) key(name);
    expect(reveal).not.toHaveBeenCalled();
  });

  it("reveals on Tab, so the hidden bar can take focus", () => {
    key("Tab");
    expect(reveal).toHaveBeenCalledTimes(1);
    key("Tab", { ctrlKey: true });
    expect(reveal).toHaveBeenCalledTimes(1);
  });

  it("reveals when focus lands inside the chrome, and not elsewhere", () => {
    focusIn(element({ chrome: false }));
    expect(reveal).not.toHaveBeenCalled();
    focusIn(element({ chrome: true }));
    expect(reveal).toHaveBeenCalledTimes(1);
  });

  it("conceals on a downward scroll and not on an upward one", () => {
    scrollTo(1500);
    scrollTo(1000);
    expect(conceal).not.toHaveBeenCalled();
    scrollTo(1030);
    expect(conceal).toHaveBeenCalledTimes(1);
    expect(reveal).not.toHaveBeenCalled();
  });

  it("measures from where the strip was when it started listening", () => {
    // A restored reading position is not a scroll the reader made.
    scrollTo(2010);
    expect(conceal).not.toHaveBeenCalled();
  });

  it("keeps the chrome at the end of the strip", () => {
    atEnd = true;
    scrollTo(2100);
    expect(conceal).not.toHaveBeenCalled();
  });

  it("holds the chrome while the mouse rests on it, until it leaves", () => {
    pointer("pointerover", { target: element({ chrome: true }) });
    expect(autohide.held()).toBe(true);
    scrollTo(2100);
    expect(conceal).not.toHaveBeenCalled();

    pointer("pointerover", { target: element({ chrome: false }) });
    expect(autohide.held()).toBe(false);
    scrollTo(2200);
    expect(conceal).toHaveBeenCalledTimes(1);
  });

  it("lets go when the mouse leaves the window from the chrome", () => {
    pointer("pointerover", { target: element({ chrome: true }) });
    pointer("pointerout", { target: element({ chrome: true }), relatedTarget: null });
    expect(autohide.held()).toBe(false);
  });

  it("does not let a tap leave a sticky hold behind", () => {
    pointer("pointerover", { pointerType: "touch", target: element({ chrome: true }) });
    expect(autohide.held()).toBe(false);
  });

  it("holds the chrome while a control in it has keyboard focus", () => {
    active = element({ chrome: true, focusVisible: true });
    expect(autohide.held()).toBe(true);
    scrollTo(2100);
    expect(conceal).not.toHaveBeenCalled();
  });

  it("does not hold for a button a mouse click left focused", () => {
    // Otherwise clicking Next once would pin the bar for the rest of the read.
    active = element({ chrome: true, focusVisible: false });
    expect(autohide.held()).toBe(false);
    scrollTo(2100);
    expect(conceal).toHaveBeenCalledTimes(1);
  });

  it("does not hold for keyboard focus outside the chrome", () => {
    active = element({ chrome: false, focusVisible: true });
    expect(autohide.held()).toBe(false);
  });

  it("stops listening on teardown", () => {
    autohide.teardown();
    pointer("pointermove", { y: 790 });
    key("Tab");
    scrollTo(4000);
    expect(reveal).not.toHaveBeenCalled();
    expect(conceal).not.toHaveBeenCalled();
  });
});

describe("the reader's chrome markers", () => {
  // Code only, so a comment naming the attribute cannot satisfy it.
  const reader = readFileSync(new URL("./components/ChapterReader.tsx", import.meta.url), "utf8")
    .replace(/\{\/\*[\s\S]*?\*\/\}/g, "")
    .replace(/\/\/.*$/gm, "");

  it("marks both the control bar and the download pill as chrome", () => {
    expect(reader).toMatch(/data-reader-chrome[^>]*>\s*<DownloadChapterControl/);
    expect(reader).toMatch(/data-reader-chrome[^>]*>\s*<ReaderControls/);
  });
});
