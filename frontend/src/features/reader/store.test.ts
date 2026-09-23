import { afterEach, describe, expect, it, vi } from "vitest";
import { useReaderStore } from "./store";

/**
 * Outside cinema mode the chrome is this flag, and reading sets it to false on
 * every ~24px of downward scroll. Nearly every one of those finds it false
 * already, and must not wake the reader for it.
 */
describe("useReaderStore", () => {
  afterEach(() => useReaderStore.setState({ controlsVisible: true }));

  it("notifies once when reading hides the chrome, not on every scroll step", () => {
    const listener = vi.fn();
    const unsubscribe = useReaderStore.subscribe(listener);

    for (let stretch = 0; stretch < 50; stretch += 1) {
      useReaderStore.getState().setControlsVisible(false);
    }

    expect(listener).toHaveBeenCalledTimes(1);
    expect(useReaderStore.getState().controlsVisible).toBe(false);
    unsubscribe();
  });

  it("is silent when a reveal finds the chrome already up", () => {
    const listener = vi.fn();
    const unsubscribe = useReaderStore.subscribe(listener);

    useReaderStore.getState().setControlsVisible(true);

    expect(listener).not.toHaveBeenCalled();
    unsubscribe();
  });

  it("still toggles on a tap", () => {
    useReaderStore.getState().toggleControls();
    expect(useReaderStore.getState().controlsVisible).toBe(false);
    useReaderStore.getState().toggleControls();
    expect(useReaderStore.getState().controlsVisible).toBe(true);
  });
});
