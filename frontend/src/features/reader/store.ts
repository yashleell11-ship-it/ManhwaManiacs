import { create } from "zustand";

/**
 * Reader chrome state that is the same wherever you read and does NOT need to
 * survive a reload.
 *
 * Reading mode, fit and zoom are per-series (`useReaderPreferences`). The
 * page-gap and cinema-mode preferences are per-profile and persisted
 * (`useReaderSettings`). What is left here is the live show/hide of the chrome
 * outside cinema mode, which is session-only.
 */
interface ReaderUiState {
  controlsVisible: boolean;
  setControlsVisible: (visible: boolean) => void;
  toggleControls: () => void;
}

export const useReaderStore = create<ReaderUiState>((set) => ({
  controlsVisible: true,
  // Reading calls this on every stretch of downward scroll, nearly always with
  // the value the chrome already has. Handing zustand back the same state
  // object is what stops it waking every subscriber for nothing.
  setControlsVisible: (visible) =>
    set((state) => (state.controlsVisible === visible ? state : { controlsVisible: visible })),
  toggleControls: () => set((state) => ({ controlsVisible: !state.controlsVisible })),
}));
