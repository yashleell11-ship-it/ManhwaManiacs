/**
 * The reader's settings sheet, as far as keyboards and screen readers see it.
 *
 * Closed, the sheet only slides off-screen — it stays mounted so it can slide
 * back — and sliding does nothing to focus. Marked `aria-hidden` alone, its
 * twenty-odd controls stayed in the Tab order AHEAD of the bottom bar: a
 * keyboard reader tabbed through invisible Layout / Direction / Fit buttons to
 * reach Next chapter, and a stray Space on one of them switched the layout
 * with nothing on screen to say why. `inert` is what takes a subtree out of
 * the Tab order and the accessibility tree together.
 */
export function settingsSheetAttributes(open: boolean): {
  inert: boolean;
  "aria-hidden": boolean;
} {
  return { inert: !open, "aria-hidden": !open };
}

export type SettingsSheetFocusTarget = "close-button" | "trigger" | null;

/**
 * Where focus goes when the sheet opens or closes, if anywhere.
 *
 * Opening moves it into the sheet, onto its Close button, so the keyboard
 * reader who pressed the gear is inside what they opened. Closing hands it
 * back to the gear — but only when focus was inside the sheet (it is about to
 * go inert, which would drop focus on the page body) and only while the chrome
 * is up: the sheet also closes BECAUSE the chrome hid, and focusing a control
 * that just slid away would be the same invisible-focus problem again.
 */
export function settingsSheetFocusTarget({
  wasOpen,
  open,
  focusInSheet,
  chromeVisible,
}: {
  wasOpen: boolean;
  open: boolean;
  focusInSheet: boolean;
  chromeVisible: boolean;
}): SettingsSheetFocusTarget {
  if (open && !wasOpen) return "close-button";
  if (!open && wasOpen && focusInSheet && chromeVisible) return "trigger";
  return null;
}
