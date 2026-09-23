/**
 * The novel reader's one waiting progress write, and the moments it has to be
 * SENT rather than dropped.
 *
 * The reader debounces progress so a scroll is one write, not fifty. It used to
 * keep the waiting write in a bare timer and clear that timer on unmount, so
 * the last half second of reading before Back, a link out or closing the tab
 * never reached the server. That is exactly where a chapter read to the end
 * gets its furthest bucket, so the library and the other devices kept showing
 * the reader a little earlier than they stopped. The manga reader already
 * sends its waiting write on leave (`reader/use-strip-progress.ts`); this is
 * the same rule for prose.
 *
 * Pure (no React) so the rule is tested directly; `NovelReader` binds it.
 */

/** A progress write, waiting out the debounce. */
export interface PendingProgress {
  /** Wait `delayMs`, then send `send`. Replaces anything already waiting. */
  schedule: (send: () => void) => void;
  /** Send whatever is waiting now, once. A no-op when nothing is. */
  flush: () => void;
  /** Forget whatever is waiting without sending it: a newer write covers it. */
  cancel: () => void;
}

export function createPendingProgress(delayMs: number): PendingProgress {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let pending: (() => void) | null = null;

  const cancel = () => {
    if (timer) clearTimeout(timer);
    timer = null;
    pending = null;
  };

  const flush = () => {
    const send = pending;
    cancel();
    send?.();
  };

  const schedule = (send: () => void) => {
    cancel();
    pending = send;
    timer = setTimeout(flush, delayMs);
  };

  return { schedule, flush, cancel };
}

/** The slice of `document` / `window` the leave events are bound through. */
interface LeaveEventTarget {
  addEventListener(type: string, listener: () => void): void;
  removeEventListener(type: string, listener: () => void): void;
}

export interface LeaveTargets {
  document: LeaveEventTarget & { readonly visibilityState: DocumentVisibilityState };
  window: LeaveEventTarget;
}

/**
 * Call `flush` whenever the reader is being left, and return the unbind.
 *
 * - `visibilitychange` to hidden fires before a tab closes or the app is
 *   switched away from, while the page can still send;
 * - `pagehide` covers a page put into the back/forward cache without being
 *   hidden first;
 * - the unbind itself flushes, because it runs when the reader unmounts: Back,
 *   the series link and "Back to the book" all unmount it within the debounce
 *   often enough.
 */
export function flushWhenLeaving(
  flush: () => void,
  targets: LeaveTargets = { document, window },
): () => void {
  const flushWhenHidden = () => {
    if (targets.document.visibilityState === "hidden") flush();
  };
  targets.document.addEventListener("visibilitychange", flushWhenHidden);
  targets.window.addEventListener("pagehide", flush);
  return () => {
    targets.document.removeEventListener("visibilitychange", flushWhenHidden);
    targets.window.removeEventListener("pagehide", flush);
    flush();
  };
}
