/**
 * Where keyboard focus goes while a dialog is open — once per open, never per
 * render.
 *
 * The dialog used to set this up in an effect keyed on its `onClose` prop, and
 * every caller passes `onClose` as an inline arrow. So each re-render of the
 * parent tore the trap down and built it again: the teardown sent focus back to
 * the trigger behind the overlay, the rebuild moved it to the first focusable
 * element — the header's × button. In a dialog whose field is controlled by
 * the parent, that is every keystroke: typing "My list" into New collection
 * left "M" in the field, and the space landed on × and closed the dialog.
 *
 * The rule now lives here, free of React, and the dialog runs it exactly once
 * per open/close. The close handler and the focusable list are both read at the
 * moment they are needed, not captured at open: a dialog's content changes
 * while it is open (search results arrive, a button enables), and a trap
 * pinned to the elements present at open wraps Tab against rows that have gone.
 */

export interface Focusable {
  focus: () => void;
}

export interface DialogFocusEnv<T extends Focusable, H> {
  /** What had focus when the dialog opened; it gets focus back on close. */
  previous: T | null;
  /** The panel's focusable elements in tab order, read when asked. */
  focusables: () => readonly T[];
  /** Whatever holds focus right now. */
  active: () => T | null;
  /** The caller's CURRENT close handler, called on Escape. */
  onEscape: () => void;
  /** Defer to the next frame, so the panel has painted before it takes focus. */
  schedule: (run: () => void) => H;
  cancel: (handle: H) => void;
}

export interface DialogKey {
  key: string;
  shiftKey: boolean;
  preventDefault: () => void;
}

export interface DialogFocus {
  onKeyDown: (event: DialogKey) => void;
  /** The dialog closed or unmounted: return focus to where it came from. */
  release: () => void;
}

/**
 * Where Tab must go instead of where the browser would send it, or null to let
 * the browser move focus itself. Wraps from the last element to the first and,
 * with Shift, from the first to the last.
 */
export function tabTrapTarget<T>(
  focusables: readonly T[],
  active: T | null,
  shiftKey: boolean,
): T | null {
  if (focusables.length === 0) return null;
  const first = focusables[0];
  const last = focusables[focusables.length - 1];
  if (shiftKey && active === first) return last;
  if (!shiftKey && active === last) return first;
  return null;
}

/** Start one open dialog's focus handling. Call `release` exactly once. */
export function openDialogFocus<T extends Focusable, H>(
  env: DialogFocusEnv<T, H>,
): DialogFocus {
  let pending: { handle: H } | null = {
    handle: env.schedule(() => {
      pending = null;
      env.focusables()[0]?.focus();
    }),
  };

  return {
    onKeyDown: (event) => {
      if (event.key === "Escape") {
        env.onEscape();
        return;
      }
      if (event.key !== "Tab") return;
      const target = tabTrapTarget(env.focusables(), env.active(), event.shiftKey);
      if (target) {
        event.preventDefault();
        target.focus();
      }
    },
    release: () => {
      // A dialog closed in the same frame it opened must not reach back in and
      // take focus after it has gone.
      if (pending) {
        env.cancel(pending.handle);
        pending = null;
      }
      env.previous?.focus();
    },
  };
}
