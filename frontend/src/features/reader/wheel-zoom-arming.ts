/**
 * How long a pinch may go without a tick before its blocking listener comes
 * off. A pinch has no keyup to say it ended, so idleness is the only signal.
 */
export const PINCH_IDLE_DISARM_MS = 500;

/**
 * The strip's ctrl/⌘+wheel zoom: a PASSIVE wheel listener that arms a second,
 * non-passive one only while a modifier is down. Why passive matters is told
 * where ChapterReader installs this.
 *
 * Two ways in, and they end differently:
 * - A mouse-wheel zoom arms on the Control/Meta keydown, before its first tick,
 *   and stays armed until that key lifts (or the window loses focus).
 * - A trackpad pinch synthesises ctrlKey with no keydown, so it arms on its
 *   first tick and disarms after `PINCH_IDLE_DISARM_MS` without one.
 *
 * The idle timer used to run for BOTH. On macOS, and on Linux where neither XKB
 * nor Wayland clients repeat modifier keys, a held Ctrl sends one keydown and
 * nothing more — so pausing half a second between notches disarmed the
 * blocking listener with Ctrl still down. The next notch re-armed it from
 * inside its own dispatch, where a newly added listener does not run, so
 * nothing cancelled it: the browser zoomed the whole site (and remembered that
 * per origin) instead of the strip.
 *
 * Returns the teardown.
 */
export function installWheelZoomArming({
  scroller,
  keys,
  zoom,
}: {
  /** The element whose wheel events zoom — the reader's scroll container. */
  scroller: EventTarget;
  /** Where keyboard and focus events arrive — the window. */
  keys: EventTarget;
  /** Apply the zoom for one tick; true when it did, so the tick is cancelled. */
  zoom: (event: WheelEvent) => boolean;
}): () => void {
  let armed = false;
  // Armed by a held key rather than by a pinch: only the key's own keyup may
  // end it, never the idle timer.
  let keyArmed = false;
  let disarmTimer: ReturnType<typeof setTimeout> | undefined;

  // Non-passive: the only listener allowed to cancel the browser's zoom, and
  // only attached while a modifier is actually down.
  const blocking = (event: Event) => {
    if (!zoom(event as WheelEvent)) return;
    event.preventDefault();
  };

  const arm = () => {
    if (armed) return;
    armed = true;
    scroller.addEventListener("wheel", blocking, { passive: false });
  };

  const disarm = () => {
    clearTimeout(disarmTimer);
    keyArmed = false;
    if (!armed) return;
    armed = false;
    scroller.removeEventListener("wheel", blocking);
  };

  const passive = (event: Event) => {
    const wheel = event as WheelEvent;
    if (!(wheel.ctrlKey || wheel.metaKey)) return;
    // A pinch arrives with no keydown to arm us, so arm here and keep the
    // gesture alive on a short idle timer. This tick itself is NOT zoomed:
    // once armed, `blocking` handles every subsequent tick and zooming here
    // too would double-apply it. Losing the first tick of a pinch is the
    // price of not blocking every ordinary scroll in the reader.
    arm();
    if (keyArmed) return;
    clearTimeout(disarmTimer);
    disarmTimer = setTimeout(disarm, PINCH_IDLE_DISARM_MS);
  };

  const onKeyDown = (event: Event) => {
    const { key } = event as KeyboardEvent;
    if (key !== "Control" && key !== "Meta") return;
    keyArmed = true;
    // A pinch's timer may still be pending; left running, it would disarm
    // while this key is held.
    clearTimeout(disarmTimer);
    arm();
  };
  const onKeyUp = (event: Event) => {
    const { key } = event as KeyboardEvent;
    if (key === "Control" || key === "Meta") disarm();
  };

  scroller.addEventListener("wheel", passive, { passive: true });
  keys.addEventListener("keydown", onKeyDown);
  keys.addEventListener("keyup", onKeyUp);
  keys.addEventListener("blur", disarm);

  return () => {
    scroller.removeEventListener("wheel", passive);
    keys.removeEventListener("keydown", onKeyDown);
    keys.removeEventListener("keyup", onKeyUp);
    keys.removeEventListener("blur", disarm);
    disarm();
  };
}
