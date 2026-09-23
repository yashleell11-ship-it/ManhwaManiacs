import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CINEMA_IDLE_MS, INITIAL_CINEMA_STATE } from "./cinema";
import {
  chromeVisible,
  createChromeController,
  type ChromeController,
  type ChromeTimers,
} from "./chrome-controller";
import { createCinemaMachine, type CinemaMachine } from "./use-cinema";

/**
 * The glue between the autohide rules and the two owners of the chrome — the
 * cinema machine and the reader store — used to live inside a React hook with
 * nothing but a source regex over it. It is a plain factory now, with the
 * machine, the store's setter and the timers handed in, so every branch of it
 * runs here on a fake clock.
 */

/** An element stand-in: `closest` answers whether it sits in the chrome. */
function element(chrome: boolean) {
  return Object.assign(new EventTarget(), {
    tagName: "BUTTON",
    closest: (selector: string) => (chrome && selector === "[data-reader-chrome]" ? {} : null),
    getAttribute: () => null,
  });
}

describe("createChromeController", () => {
  let machine: CinemaMachine;
  let setControlsVisible: ReturnType<typeof vi.fn<(visible: boolean) => void>>;
  let controller: ChromeController;
  let events: EventTarget;
  let scroller: EventTarget & { scrollTop: number };
  let uninstall: (() => void) | null;

  const timers: ChromeTimers = {
    setTimeout: (callback, ms) => setTimeout(callback, ms),
    clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
  };

  beforeEach(() => {
    vi.useFakeTimers();
    machine = createCinemaMachine();
    setControlsVisible = vi.fn<(visible: boolean) => void>();
    controller = createChromeController({ machine, setControlsVisible, timers });
    events = new EventTarget();
    scroller = Object.assign(new EventTarget(), { scrollTop: 1000 });
    uninstall = null;
  });

  afterEach(() => {
    uninstall?.();
    controller.dispose();
    vi.useRealTimers();
  });

  function install() {
    uninstall = controller.install({
      events,
      scroller,
      viewport: () => ({ top: 0, bottom: 800 }),
      activeElement: () => null,
    });
  }

  function pointerOver(chrome: boolean) {
    const event = Object.assign(new Event("pointerover"), { pointerType: "mouse" });
    Object.defineProperty(event, "target", { value: element(chrome) });
    events.dispatchEvent(event);
  }

  function scrollBy(delta: number) {
    scroller.scrollTop += delta;
    scroller.dispatchEvent(new Event("scroll"));
  }

  function engage() {
    controller.autoEngage(true, true);
    expect(machine.get()).toEqual({ enabled: true, chrome: "hidden" });
  }

  describe("outside cinema mode", () => {
    it("writes reveals and conceals to the reader store, and leaves the machine alone", () => {
      controller.reveal();
      expect(setControlsVisible).toHaveBeenLastCalledWith(true);
      controller.conceal();
      expect(setControlsVisible).toHaveBeenLastCalledWith(false);
      expect(machine.get()).toBe(INITIAL_CINEMA_STATE);
    });

    it("arms no idle timer: only reading hides the chrome there", () => {
      controller.reveal();
      expect(vi.getTimerCount()).toBe(0);
    });

    it("ignores a tap's notifyActivity, since the tap toggles the store itself", () => {
      controller.notifyActivity();
      expect(setControlsVisible).not.toHaveBeenCalled();
    });

    it("does not conceal while held", () => {
      install();
      pointerOver(true);
      controller.conceal();
      expect(setControlsVisible).not.toHaveBeenCalled();
    });
  });

  describe("in cinema mode", () => {
    it("drives the machine and never writes the store", () => {
      engage();
      controller.reveal();
      expect(machine.get().chrome).toBe("shown");
      controller.conceal();
      expect(machine.get().chrome).toBe("hidden");
      expect(setControlsVisible).not.toHaveBeenCalled();
    });

    it("hides the chrome a full idle period after it came up", () => {
      engage();
      controller.reveal();
      vi.advanceTimersByTime(CINEMA_IDLE_MS - 1);
      expect(machine.get().chrome).toBe("shown");
      vi.advanceTimersByTime(1);
      expect(machine.get().chrome).toBe("hidden");
    });

    it("restarts the idle period on every reveal and on a tap", () => {
      engage();
      controller.reveal();
      vi.advanceTimersByTime(CINEMA_IDLE_MS - 100);
      controller.notifyActivity();
      vi.advanceTimersByTime(CINEMA_IDLE_MS - 100);
      expect(machine.get().chrome).toBe("shown");
      vi.advanceTimersByTime(100);
      expect(machine.get().chrome).toBe("hidden");
    });

    it("keeps re-arming the idle timer while held, and hides once let go", () => {
      install();
      engage();
      controller.reveal();
      pointerOver(true);

      for (let period = 0; period < 4; period += 1) {
        vi.advanceTimersByTime(CINEMA_IDLE_MS);
        expect(machine.get().chrome).toBe("shown");
        expect(vi.getTimerCount()).toBe(1);
      }

      pointerOver(false);
      vi.advanceTimersByTime(CINEMA_IDLE_MS);
      expect(machine.get().chrome).toBe("hidden");
      expect(vi.getTimerCount()).toBe(0);
    });

    it("returns early from conceal while held, and keeps the idle timer", () => {
      install();
      engage();
      controller.reveal();
      pointerOver(true);
      controller.conceal();
      expect(machine.get().chrome).toBe("shown");
      expect(vi.getTimerCount()).toBe(1);
    });

    it("drops the idle timer when reading conceals", () => {
      engage();
      controller.reveal();
      controller.conceal();
      expect(vi.getTimerCount()).toBe(0);
    });
  });

  describe("a page turn", () => {
    it("conceals, in either mode", () => {
      controller.showPage("12#1", true);
      expect(setControlsVisible).not.toHaveBeenCalled();
      controller.showPage("12#2", true);
      expect(setControlsVisible).toHaveBeenLastCalledWith(false);

      engage();
      controller.reveal();
      controller.showPage("12#3", true);
      expect(machine.get().chrome).toBe("hidden");
    });

    it("is not the first page, a re-render of the same page, or the strip", () => {
      controller.showPage("12#1", true);
      controller.showPage("12#1", true);
      controller.showPage(null, true);
      controller.showPage("12#4", true);
      expect(setControlsVisible).not.toHaveBeenCalled();
    });

    it("does nothing while the reader is still loading, but is remembered", () => {
      controller.showPage("12#1", false);
      controller.showPage("12#2", false);
      expect(setControlsVisible).not.toHaveBeenCalled();
      controller.showPage("12#3", true);
      expect(setControlsVisible).toHaveBeenLastCalledWith(false);
    });
  });

  describe("the end of the strip", () => {
    it("reveals there, in either mode", () => {
      controller.setAtEnd(true, true);
      expect(setControlsVisible).toHaveBeenLastCalledWith(true);

      controller.setAtEnd(false, true);
      engage();
      controller.setAtEnd(true, true);
      expect(machine.get().chrome).toBe("shown");
    });

    it("does not reveal while the reader is loading, or on leaving the end", () => {
      controller.setAtEnd(true, false);
      controller.setAtEnd(false, true);
      expect(setControlsVisible).not.toHaveBeenCalled();
    });

    it("suppresses the scroll conceal there, and only there", () => {
      install();
      controller.setAtEnd(true, true);
      setControlsVisible.mockClear();
      scrollBy(200);
      expect(setControlsVisible).not.toHaveBeenCalled();

      controller.setAtEnd(false, true);
      scrollBy(200);
      expect(setControlsVisible).toHaveBeenLastCalledWith(false);
    });
  });

  it("stops listening on uninstall, and nothing holds the chrome after", () => {
    install();
    pointerOver(true);
    expect(controller.held()).toBe(true);
    uninstall?.();
    uninstall = null;
    expect(controller.held()).toBe(false);
    scrollBy(200);
    expect(setControlsVisible).not.toHaveBeenCalled();
  });

  describe("toggle", () => {
    it("turns cinema mode on with the chrome hidden, and reports it", () => {
      expect(controller.toggle()).toBe(true);
      expect(machine.get()).toEqual({ enabled: true, chrome: "hidden" });
    });

    it("turning it off shows the chrome through the store, which owns it again", () => {
      // Reading had hidden the chrome before cinema mode went on.
      controller.conceal();
      controller.toggle();
      controller.reveal();
      expect(vi.getTimerCount()).toBe(1);

      expect(controller.toggle()).toBe(false);
      expect(machine.get()).toEqual({ enabled: false, chrome: "shown" });
      expect(setControlsVisible).toHaveBeenLastCalledWith(true);
      expect(vi.getTimerCount()).toBe(0);
    });
  });

  describe("autoEngage", () => {
    it("engages from the saved preference once the reader is active", () => {
      controller.autoEngage(true, false);
      expect(machine.get().enabled).toBe(false);
      controller.autoEngage(true, true);
      expect(machine.get().enabled).toBe(true);
    });

    it("decides once: a preference turned on later does not engage it", () => {
      controller.autoEngage(false, true);
      controller.autoEngage(true, true);
      expect(machine.get().enabled).toBe(false);
    });
  });

  it("drops the idle timer on dispose", () => {
    engage();
    controller.reveal();
    controller.dispose();
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe("chromeVisible", () => {
  it("is the store's flag while cinema mode is off", () => {
    expect(chromeVisible({ enabled: false, chrome: "shown" }, false)).toBe(false);
    expect(chromeVisible({ enabled: false, chrome: "shown" }, true)).toBe(true);
  });

  it("is the machine's answer while cinema mode is on, whatever the store says", () => {
    expect(chromeVisible({ enabled: true, chrome: "hidden" }, true)).toBe(false);
    expect(chromeVisible({ enabled: true, chrome: "shown" }, false)).toBe(true);
  });
});
