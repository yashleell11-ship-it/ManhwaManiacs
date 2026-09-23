"use client";

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { usePrefersReducedMotion } from "@/components/premium/use-prefers-reduced-motion";
import {
  CINEMA_IDLE_MS,
  cinemaReduce,
  INITIAL_CINEMA_STATE,
  type CinemaEvent,
  type CinemaState,
} from "./cinema";

export interface CinemaController {
  /** Cinema mode is engaged (chrome auto-hides). */
  enabled: boolean;
  /** The chrome is currently on screen. */
  chromeVisible: boolean;
  /** Animate transitions, or swap instantly (`prefers-reduced-motion`). */
  reducedMotion: boolean;
  /** Toggle cinema mode (control / keyboard shortcut). */
  toggle: () => void;
  /** Register user activity — reveals the chrome and re-arms the idle timer. */
  notifyActivity: () => void;
}

interface UseCinemaInput {
  /** Persisted per-profile preference: auto-engage cinema mode on open. */
  persistedEnabled: boolean;
  /** The reader scroll container, for the scroll / pointer activity listeners. */
  scrollElement: HTMLElement | null;
  /** False while the reader is still loading — no point arming timers yet. */
  active: boolean;
  /** Called when the toggle flips, so the preference can be persisted. */
  onEnabledChange: (enabled: boolean) => void;
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
 * The activity listeners fire on every `pointermove`, `keydown` and strip
 * `scroll`, which is about once a frame, and nearly all of those land while the
 * chrome is already up (or cinema mode is off) and so change nothing. As a
 * `useReducer` each one still scheduled a render of the whole reader: React
 * 19's reducer dispatch has no early bail-out and only finds the state
 * unchanged after running the component. Here `send` compares first and
 * notifies only when {@link cinemaReduce} returns a new state, so the reader
 * renders on a hide or a reveal and at no other time.
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
 * Drives the cinema-mode {@link cinemaReduce} machine with a real idle timer and
 * pointer / scroll / key activity listeners. Auto-engages ~3 s after the reader
 * settles when the per-profile preference is on; either way, once engaged the
 * chrome hides on idle and returns on any activity.
 */
export function useCinema({
  persistedEnabled,
  scrollElement,
  active,
  onEnabledChange,
}: UseCinemaInput): CinemaController {
  const reducedMotion = usePrefersReducedMotion();
  const [machine] = useState(() => createCinemaMachine());
  // `machine.get` doubles as the server snapshot: the reader starts with the
  // chrome up on both sides of hydration.
  const state = useSyncExternalStore(machine.subscribe, machine.get, machine.get);
  const idleTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const clearIdle = useCallback(() => {
    if (idleTimer.current) {
      clearTimeout(idleTimer.current);
      idleTimer.current = null;
    }
  }, []);

  const armIdle = useCallback(() => {
    clearIdle();
    idleTimer.current = setTimeout(() => {
      idleTimer.current = null;
      machine.send({ type: "idle" });
    }, CINEMA_IDLE_MS);
  }, [clearIdle, machine]);

  const notifyActivity = useCallback(() => {
    if (!machine.get().enabled) return;
    // A no-op while the chrome is already up; the idle timer still restarts.
    machine.send({ type: "activity" });
    armIdle();
  }, [armIdle, machine]);

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

  // Activity listeners. Pointer-move and scroll reveal the chrome; a plain tap
  // is handled by the reader's own toggle, which also calls notifyActivity.
  useEffect(() => {
    if (!active) return;
    const targets: Array<[EventTarget, string]> = [
      [window, "pointermove"],
      [window, "keydown"],
    ];
    if (scrollElement) targets.push([scrollElement, "scroll"]);

    const handler = () => notifyActivity();
    for (const [target, event] of targets) {
      target.addEventListener(event, handler, { passive: true });
    }
    return () => {
      for (const [target, event] of targets) {
        target.removeEventListener(event, handler);
      }
    };
  }, [active, scrollElement, notifyActivity]);

  useEffect(() => clearIdle, [clearIdle]);

  return useMemo(
    () => ({
      enabled: state.enabled,
      chromeVisible: !state.enabled || state.chrome === "shown",
      reducedMotion,
      toggle,
      notifyActivity,
    }),
    [state.enabled, state.chrome, reducedMotion, toggle, notifyActivity],
  );
}
