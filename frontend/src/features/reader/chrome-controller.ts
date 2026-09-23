import {
  installChromeAutohide,
  pageTurnConceals,
  type ChromeAutohide,
  type ReaderViewport,
} from "./chrome-autohide";
import { CINEMA_IDLE_MS, type CinemaEvent, type CinemaState } from "./cinema";

/**
 * What decides, moment to moment, whether the reader chrome is up, with every
 * dependency handed in: the cinema machine, the reader store's setter and the
 * timers. `use-cinema.ts` is only the React glue around this.
 *
 * Two owners of one question. With cinema mode engaged, the `cinemaReduce`
 * machine says whether the chrome is up and an idle timer hides it. Outside
 * cinema mode it is the reader store's `controlsVisible`, which a tap toggles.
 * The rules in `chrome-autohide.ts` call {@link ChromeController.reveal} and
 * {@link ChromeController.conceal}, and those write to whichever owner is in
 * charge.
 */

/** The cinema machine, as far as the controller needs it. */
export interface ChromeMachine {
  get: () => CinemaState;
  send: (event: CinemaEvent) => void;
}

/** `setTimeout` and `clearTimeout`, injectable so tests can run the clock. */
export interface ChromeTimers {
  setTimeout: (callback: () => void, ms: number) => unknown;
  clearTimeout: (handle: unknown) => void;
}

const realTimers: ChromeTimers = {
  // Looked up at call time, so a faked clock installed later still applies.
  setTimeout: (callback, ms) => globalThis.setTimeout(callback, ms),
  clearTimeout: (handle) =>
    globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>),
};

/** Where the chrome's events come from, for {@link ChromeController.install}. */
export interface ChromeEnvironment {
  /** The window. */
  events: EventTarget;
  /** The strip's scroll container, if there is one. */
  scroller: (EventTarget & { scrollTop: number }) | null;
  viewport: () => ReaderViewport;
  /** `document.activeElement`. */
  activeElement: () => Element | null;
}

export interface ChromeController {
  /** Bring the chrome up (a reveal band, Tab, the strip's end, a tap in cinema mode). */
  reveal: () => void;
  /** Put the chrome away (reading on) — unless it is held. */
  conceal: () => void;
  /** A tap on the page in cinema mode: reveals and re-arms the idle timer. */
  notifyActivity: () => void;
  /** Flip cinema mode; returns whether it is now on. Turning it off leaves the chrome up. */
  toggle: () => boolean;
  /** Engage cinema mode from the saved preference, once, when the reader first settles. */
  autoEngage: (persistedEnabled: boolean, active: boolean) => void;
  /** The strip is (or is no longer) at its end. Reaching it reveals; nothing hides it there. */
  setAtEnd: (atEnd: boolean, active: boolean) => void;
  /** The page on screen in a paged mode (`null` in the strip). A change is a page turn, which conceals. */
  showPage: (position: string | null, active: boolean) => void;
  /** Start listening to the reader's events; returns the teardown. */
  install: (environment: ChromeEnvironment) => () => void;
  /** Something holds the chrome up (see `ChromeAutohide.held`). */
  held: () => boolean;
  /** Drop the idle timer (the reader is going away). */
  dispose: () => void;
}

/** Whether the chrome is on screen: the machine's answer in cinema mode, the store's otherwise. */
export function chromeVisible(state: CinemaState, controlsVisible: boolean): boolean {
  return state.enabled ? state.chrome === "shown" : controlsVisible;
}

export function createChromeController({
  machine,
  setControlsVisible,
  timers = realTimers,
  idleMs = CINEMA_IDLE_MS,
}: {
  machine: ChromeMachine;
  /** The reader store's setter, which owns the chrome outside cinema mode. */
  setControlsVisible: (visible: boolean) => void;
  timers?: ChromeTimers;
  idleMs?: number;
}): ChromeController {
  let idleTimer: unknown = null;
  let autohide: ChromeAutohide | null = null;
  let atEnd = false;
  let page: string | null = null;
  let autoEngaged = false;

  const held = () => autohide?.held() ?? false;

  const clearIdle = () => {
    if (idleTimer != null) {
      timers.clearTimeout(idleTimer);
      idleTimer = null;
    }
  };

  const armIdle = () => {
    clearIdle();
    const elapse = () => {
      // Never out from under a resting pointer or a focused control: look
      // again a full idle period later.
      if (held()) {
        idleTimer = timers.setTimeout(elapse, idleMs);
        return;
      }
      idleTimer = null;
      machine.send({ type: "idle" });
    };
    idleTimer = timers.setTimeout(elapse, idleMs);
  };

  const reveal = () => {
    if (machine.get().enabled) {
      // A no-op while the chrome is already up; the idle timer still restarts.
      machine.send({ type: "activity" });
      armIdle();
    } else {
      setControlsVisible(true);
    }
  };

  const conceal = () => {
    if (held()) return;
    if (machine.get().enabled) {
      clearIdle();
      machine.send({ type: "conceal" });
    } else {
      setControlsVisible(false);
    }
  };

  return {
    reveal,
    conceal,
    held,

    notifyActivity() {
      if (machine.get().enabled) reveal();
    },

    toggle() {
      const next = !machine.get().enabled;
      machine.send({ type: "toggle" });
      if (!next) {
        clearIdle();
        // Out of cinema mode the store owns the chrome again, and whatever it
        // was left at, leaving cinema mode shows it.
        setControlsVisible(true);
      }
      return next;
    },

    autoEngage(persistedEnabled, active) {
      if (!active || autoEngaged) return;
      autoEngaged = true;
      if (!persistedEnabled) return;
      machine.send({ type: "enable" });
      armIdle();
    },

    setAtEnd(next, active) {
      atEnd = next;
      // Next is what the reader wants at the end of the strip.
      if (active && next) reveal();
    },

    showPage(position, active) {
      const previous = page;
      page = position;
      if (active && pageTurnConceals(previous, position)) conceal();
    },

    install({ events, scroller, viewport, activeElement }) {
      const handle = installChromeAutohide({
        events,
        scroller,
        viewport,
        activeElement,
        atEnd: () => atEnd,
        reveal,
        conceal,
      });
      autohide = handle;
      return () => {
        handle.teardown();
        if (autohide === handle) autohide = null;
      };
    },

    dispose: clearIdle,
  };
}
