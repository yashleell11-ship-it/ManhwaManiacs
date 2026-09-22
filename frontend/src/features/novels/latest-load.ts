/**
 * One audio load at a time, and a way to recognise a load nobody wants any
 * more.
 *
 * Both audio surfaces in the novel reader fetch a file on a press and play it
 * when it arrives: the chapter player (about two megabytes, seconds on a slow
 * link) and the voice picker's previews. In both, the press and the arrival
 * are far enough apart for the reader to do something else in between — leave
 * the chapter, press a second voice, close the picker. Without a way to tell
 * the arrival it is stale, it starts audio anyway, on an element whose
 * controls have already gone, and nothing on the page can stop it.
 *
 * The fetch itself is aborted too (the signal goes to `requestBlob`), but an
 * abort is not enough on its own: the blob may already be in hand when the
 * reader leaves, so the code after the await still has to ask.
 *
 * Kept free of React and the DOM element so the decision can be tested.
 */

export type LatestLoad = {
  /** Start a load, abandoning whichever one is still in flight. */
  begin(): AbortSignal;
  /** Abandon the load in flight: the player left, or the picker closed. */
  cancel(): void;
};

export function createLatestLoad(): LatestLoad {
  let controller: AbortController | null = null;
  return {
    begin() {
      controller?.abort();
      controller = new AbortController();
      return controller.signal;
    },
    cancel() {
      controller?.abort();
      controller = null;
    },
  };
}

/**
 * Whether an object URL that just arrived should be used.
 *
 * When its load was abandoned, the URL is revoked HERE and false comes back,
 * so the caller can simply return. Revoking is not tidiness: the unmount
 * cleanup that normally revokes it has already run by the time this URL
 * exists, so nothing else ever would, and it would pin the whole file in
 * memory for the life of the tab.
 */
export function keepLoadedUrl(
  signal: AbortSignal,
  url: string,
  revoke: (url: string) => void = (value) => URL.revokeObjectURL(value),
): boolean {
  if (!signal.aborted) return true;
  revoke(url);
  return false;
}

/**
 * Whether a rejected `play()` is a failure worth telling the reader about.
 *
 * An `AbortError` is not: it is what `play()` rejects with when a `pause()` or
 * a new source interrupts it, which is the reader pressing pause quickly, not
 * the audio being broken. Anything else — the browser refusing autoplay, a
 * file it cannot decode — is real, and should not be swallowed silently.
 */
export function isPlaybackFailure(error: unknown): boolean {
  return !(
    typeof error === "object" &&
    error !== null &&
    (error as { name?: unknown }).name === "AbortError"
  );
}
