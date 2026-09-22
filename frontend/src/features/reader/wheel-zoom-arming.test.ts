import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { installWheelZoomArming, PINCH_IDLE_DISARM_MS } from "./wheel-zoom-arming";

// Node's EventTarget follows the DOM rule the bug hinged on: a listener added
// while an event is being dispatched does not run for that event.
function wheel(modifier: "ctrl" | "meta" | null = "ctrl"): Event {
  return Object.assign(new Event("wheel", { cancelable: true }), {
    ctrlKey: modifier === "ctrl",
    metaKey: modifier === "meta",
  });
}

function key(type: "keydown" | "keyup", name: string): Event {
  return Object.assign(new Event(type), { key: name });
}

let scroller: EventTarget;
let keys: EventTarget;
let zoom: ReturnType<typeof vi.fn<(event: WheelEvent) => boolean>>;
let teardown: () => void;

/** Dispatch one tick; true when something cancelled the browser's own zoom. */
function tick(event: Event = wheel()): boolean {
  scroller.dispatchEvent(event);
  return event.defaultPrevented;
}

beforeEach(() => {
  vi.useFakeTimers();
  scroller = new EventTarget();
  keys = new EventTarget();
  zoom = vi.fn((event: WheelEvent) => event.ctrlKey || event.metaKey);
  teardown = installWheelZoomArming({ scroller, keys, zoom });
});

afterEach(() => {
  teardown();
  vi.useRealTimers();
});

describe("installWheelZoomArming", () => {
  it("keeps a held Ctrl armed across a pause between notches", () => {
    // The regression: a held modifier does not auto-repeat on Linux or macOS,
    // so after half a second the blocking listener came off with Ctrl still
    // down and the next notch zoomed the browser page instead of the strip.
    keys.dispatchEvent(key("keydown", "Control"));

    expect(tick()).toBe(true);
    vi.advanceTimersByTime(1000);
    expect(tick()).toBe(true);
    expect(zoom).toHaveBeenCalledTimes(2);
  });

  it("does the same for a held Meta", () => {
    keys.dispatchEvent(key("keydown", "Meta"));

    expect(tick(wheel("meta"))).toBe(true);
    vi.advanceTimersByTime(1000);
    expect(tick(wheel("meta"))).toBe(true);
    expect(zoom).toHaveBeenCalledTimes(2);
  });

  it("is not disarmed by a pinch's timer still pending when the key goes down", () => {
    tick();
    keys.dispatchEvent(key("keydown", "Control"));
    vi.advanceTimersByTime(1000);

    expect(tick()).toBe(true);
  });

  it("disarms when the key lifts", () => {
    keys.dispatchEvent(key("keydown", "Control"));
    keys.dispatchEvent(key("keyup", "Control"));

    expect(tick()).toBe(false);
    expect(zoom).not.toHaveBeenCalled();
  });

  it("disarms when the window loses focus mid-hold", () => {
    keys.dispatchEvent(key("keydown", "Control"));
    keys.dispatchEvent(new Event("blur"));

    expect(tick()).toBe(false);
  });

  it("arms a pinch on its first tick, which is the one it gives up", () => {
    expect(tick()).toBe(false);
    expect(tick()).toBe(true);
    expect(zoom).toHaveBeenCalledTimes(1);
  });

  it("disarms a pinch once it goes idle", () => {
    tick();
    vi.advanceTimersByTime(PINCH_IDLE_DISARM_MS + 1);

    expect(tick()).toBe(false);
  });

  it("leaves a plain wheel alone even while armed", () => {
    keys.dispatchEvent(key("keydown", "Control"));

    expect(tick(wheel(null))).toBe(false);
  });

  it("stops listening once torn down", () => {
    keys.dispatchEvent(key("keydown", "Control"));
    teardown();

    expect(tick()).toBe(false);
    expect(tick()).toBe(false);
    expect(zoom).not.toHaveBeenCalled();
  });
});
