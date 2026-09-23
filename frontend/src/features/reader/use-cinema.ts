"use client";

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { usePrefersReducedMotion } from "@/components/premium/use-prefers-reduced-motion";
import {
  installChromeAutohide,
  pageTurnConceals,
  type ChromeAutohide,
  type ReaderViewport,
} from "./chrome-autohide";
import {
  CINEMA_IDLE_MS,
  cinemaReduce,
  INITIAL_CINEMA_STATE,
  type CinemaEvent,
  type CinemaState,
} from "./cinema";
import { useReaderStore } from "./store";

export interface CinemaController {
  /** Cinema mode is engaged (chrome auto-hides). */
  enabled: boolean;
  /**
   * The chrome is currently on screen: the cinema machine's answer while cinema
   * mode is engaged, the reader store's `controlsVisible` otherwise.
   */
  chromeVisible: boolean;
  /** Animate transitions, or swap instantly (`prefers-reduced-motion`). */
  reducedMotion: boolean;
  /** Toggle cinema mode (control / keyboard shortcut). */
  toggle: () => void;
  /** A tap in cinema mode — reveals the chrome and re-arms the idle timer. */
  notifyActivity: () => void;
}

interface UseCinemaInput {
  /** Persisted per-profile preference: auto-engage cinema mode on open. */
  persistedEnabled: boolean;
  /** The reader scroll container: its scroll hides the chrome, its box places the reveal bands. */
  scrollElement: HTMLElement | null;
  /** False while the reader is still loading — no point arming timers yet. */
  active: boolean;
  /** Called when the toggle flips, so the preference can be persisted. */
  onEnabledChange: (enabled: boolean) => void;
  /** The strip is at its end: the chrome comes up there, and scrolling there does not hide it. */
  atEnd: boolean;
  /** The page on screen in a paged mode, `null` in the strip. A change is a page turn. */
  pagedPosition: string | null;
}

/** The {@link cinemaReduce} machine as an external store for `useSyncExternalStore`. */
export interface CinemaMachine {
  /** The current state; the same object until a transition really happens. */
  get: () => CinemaState;
  /** Run an event through the machine. Listeners hear only real changes. */
  send: (event: CinemaEvent) => void;
  /** Subscribe to changes; returns the unsubscribe. */
  subscribe: (listener: () => void) => () => void;
}

/**
 * Holds the cinema state outside React, so an event that changes nothing
 * costs nothing.
 *
 * The chrome listeners fire about once a frame — a pointer moving along a
 * reveal band, a strip scrolling on and on — and nearly all of those land while
 * the chrome is already where they want it (or cinema mode is off) and so
 * change nothing. As a `useReducer` each one still scheduled a render of the
 * whole reader: React 19's reducer dispatch has no early bail-out and only
 * finds the state unchanged after running the component. Here `send` compares
 * first and notifies only when {@link cinemaReduce} returns a new state, so the
 * reader renders on a hide or a reveal and at no other time.
 */
export function createCinemaMachine(initial: CinemaState = INITIAL_CINEMA_STATE): CinemaMachine {
  let state = initial;
  const listeners = new Set<() => void>();

  return {
    get: () => state,
    send(event) {
      const next = cinemaReduce(state, event);
      if (next === state) return;
      state = next;
      for (const listener of listeners) listener();
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}

/**
 * Shows and hides the reader chrome in both modes, by the rules in
 * `chrome-autohide.ts`: reading on hides it; the pointer at the chrome's edge,
 * Tab, focus inside it or the end of the strip brings it back; nothing hides
 * it from under the pointer or keyboard focus. Outside cinema mode that drives
 * the reader store's `controlsVisible` (a tap still toggles it). With cinema
 * mode engaged it drives the {@link cinemaReduce} machine, which also hides
 * the chrome after {@link CINEMA_IDLE_MS} standing idle. Cinema auto-engages
 * once the reader settles when the per-profile preference is on.
 */
export function useCinema({
  persistedEnabled,
  scrollElement,
  active,
  onEnabledChange,
  atEnd,
  pagedPosition,
}: UseCinemaInput): CinemaController {
  const reducedMotion = usePrefersReducedMotion();
  const [machine] = useState(() => createCinemaMachine());
  // `machine.get` doubles as the server snapshot: the reader starts with the
  // chrome up on both sides of hydration.
  const state = useSyncExternalStore(machine.subscribe, machine.get, machine.get);
  const controlsVisible = useReaderStore((store) => store.controlsVisible);
  const idleTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const autohide = useRef<ChromeAutohide | null>(null);

  const clearIdle = useCallback(() => {
    if (idleTimer.current) {
      clearTimeout(idleTimer.current);
      idleTimer.current = null;
    }
  }, []);

  const armIdle = useCallback(() => {
    clearIdle();
    const elapse = () => {
      // Never out from under a resting pointer or a focused control: look
      // again a full idle period later.
      if (autohide.current?.held()) {
        idleTimer.current = setTimeout(elapse, CINEMA_IDLE_MS);
        return;
      }
      idleTimer.current = null;
      machine.send({ type: "idle" });
    };
    idleTimer.current = setTimeout(elapse, CINEMA_IDLE_MS);
  }, [clearIdle, machine]);

  const reveal = useCallback(() => {
    if (machine.get().enabled) {
      // A no-op while the chrome is already up; the idle timer still restarts.
      machine.send({ type: "activity" });
      armIdle();
    } else {
      useReaderStore.getState().setControlsVisible(true);
    }
  }, [armIdle, machine]);

  const conceal = useCallback(() => {
    if (autohide.current?.held()) return;
    if (machine.get().enabled) {
      clearIdle();
      machine.send({ type: "conceal" });
    } else {
      useReaderStore.getState().setControlsVisible(false);
    }
  }, [clearIdle, machine]);

  const notifyActivity = useCallback(() => {
    if (machine.get().enabled) reveal();
  }, [machine, reveal]);

  const toggle = useCallback(() => {
    const next = !machine.get().enabled;
    machine.send({ type: "toggle" });
    onEnabledChange(next);
    if (next) armIdle();
    else clearIdle();
  }, [armIdle, clearIdle, machine, onEnabledChange]);

  // Auto-engage from the persisted preference, once the reader has settled.
  const autoEngagedRef = useRef(false);
  useEffect(() => {
    if (!active || autoEngagedRef.current) return;
    autoEngagedRef.current = true;
    if (persistedEnabled) {
      machine.send({ type: "enable" });
      armIdle();
    }
  }, [active, persistedEnabled, armIdle, machine]);

  // The end of the strip brings the chrome up (Next is what you want there),
  // and the scroll rule reads this so the last few pixels do not take it away.
  const atEndRef = useRef(atEnd);
  useEffect(() => {
    atEndRef.current = atEnd;
    if (active && atEnd) reveal();
  }, [active, atEnd, reveal]);

  // A page turn in a paged mode is reading on, like a downward scroll.
  const pagedPositionRef = useRef(pagedPosition);
  useEffect(() => {
    const previous = pagedPositionRef.current;
    pagedPositionRef.current = pagedPosition;
    if (active && pageTurnConceals(previous, pagedPosition)) conceal();
  }, [active, conceal, pagedPosition]);

  // Pointer, key, focus and scroll listeners. A tap on the page stays the
  // reader's own: its toggle, or notifyActivity in cinema mode.
  useEffect(() => {
    if (!active) return;
    // Measured now and on resize, not on every pointer move: the reader's box
    // only moves when the window does.
    let viewport = measureReaderViewport(scrollElement);
    const remeasure = () => {
      viewport = measureReaderViewport(scrollElement);
    };
    window.addEventListener("resize", remeasure, { passive: true });
    const handle = installChromeAutohide({
      events: window,
      scroller: scrollElement,
      viewport: () => viewport,
      activeElement: () => document.activeElement,
      atEnd: () => atEndRef.current,
      reveal,
      conceal,
    });
    autohide.current = handle;
    return () => {
      handle.teardown();
      window.removeEventListener("resize", remeasure);
      autohide.current = null;
    };
  }, [active, conceal, reveal, scrollElement]);

  useEffect(() => clearIdle, [clearIdle]);

  return useMemo(
    () => ({
      enabled: state.enabled,
      chromeVisible: state.enabled ? state.chrome === "shown" : controlsVisible,
      reducedMotion,
      toggle,
      notifyActivity,
    }),
    [state.enabled, state.chrome, controlsVisible, reducedMotion, toggle, notifyActivity],
  );
}

/** The reader's vertical extent: the scroll container's box, or the window. */
function measureReaderViewport(element: HTMLElement | null): ReaderViewport {
  if (!element) return { top: 0, bottom: window.innerHeight };
  const { top, bottom } = element.getBoundingClientRect();
  return { top, bottom };
}
