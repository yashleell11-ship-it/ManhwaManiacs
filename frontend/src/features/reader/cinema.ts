/**
 * Cinema-mode visibility state machine.
 *
 * Cinema mode hides ALL reader chrome — top bar, scrub bar, page counter, side
 * controls — for an uninterrupted read. It engages two ways: an explicit toggle
 * (control or keyboard shortcut), and on open when the per-profile preference
 * is on. While engaged, a reveal (a tap, the pointer reaching the chrome's
 * edge band, Tab, the end of the strip — see `chrome-autohide.ts`) brings the
 * chrome back, reading on conceals it at once, and otherwise it auto-hides
 * after {@link CINEMA_IDLE_MS}.
 *
 * This module is pure: it owns the transitions only. `use-cinema.ts` drives it
 * with real timers and DOM listeners, and `prefers-reduced-motion` only changes
 * how the view animates the transition, never the transition itself
 * ({@link cinemaTransition}).
 */

/** Idle time before the chrome auto-hides, in milliseconds (~3 s per spec). */
export const CINEMA_IDLE_MS = 3000;

/** Whether the reader chrome is currently on screen. */
export type ChromeVisibility = "shown" | "hidden";

export interface CinemaState {
  /** True once cinema mode has been engaged (toggle or first auto-engage). */
  enabled: boolean;
  chrome: ChromeVisibility;
}

export type CinemaEvent =
  /** User (or the 3 s auto-engage) turns cinema mode on. */
  | { type: "enable" }
  /** User turns cinema mode off — chrome returns and stays. */
  | { type: "disable" }
  /** Toggle control / keyboard shortcut. */
  | { type: "toggle" }
  /** A reveal: a tap, the pointer at the chrome's edge, Tab, the strip's end. */
  | { type: "activity" }
  /** The idle timer elapsed. */
  | { type: "idle" }
  /** Reading moved on — a downward scroll or a page turn. Hides without waiting. */
  | { type: "conceal" };

export const INITIAL_CINEMA_STATE: CinemaState = { enabled: false, chrome: "shown" };

/**
 * Advance the machine. While cinema mode is off, `activity` / `idle` /
 * `conceal` are inert (the reader store's chrome flag takes over). While it is
 * on, `activity` reveals the chrome and `idle` or `conceal` hides it again.
 */
export function cinemaReduce(state: CinemaState, event: CinemaEvent): CinemaState {
  switch (event.type) {
    case "enable":
      return state.enabled ? state : { enabled: true, chrome: "hidden" };
    case "disable":
      return state.enabled ? { enabled: false, chrome: "shown" } : state;
    case "toggle":
      return state.enabled
        ? { enabled: false, chrome: "shown" }
        : { enabled: true, chrome: "hidden" };
    case "activity":
      if (!state.enabled) return state;
      return state.chrome === "shown" ? state : { ...state, chrome: "shown" };
    case "idle":
    case "conceal":
      if (!state.enabled) return state;
      return state.chrome === "hidden" ? state : { ...state, chrome: "hidden" };
    default:
      return state;
  }
}

/** After an `activity` event, does the machine still owe an `idle` transition? */
export function cinemaExpectsIdle(state: CinemaState): boolean {
  return state.enabled && state.chrome === "shown";
}

/**
 * How the view should move the chrome in or out. `prefers-reduced-motion`
 * collapses the fade/slide to an instant swap.
 */
export function cinemaTransition(reducedMotion: boolean): "instant" | "fade" {
  return reducedMotion ? "instant" : "fade";
}
