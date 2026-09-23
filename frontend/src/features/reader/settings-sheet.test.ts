import { describe, expect, it } from "vitest";
import { settingsSheetAttributes, settingsSheetFocusTarget } from "./settings-sheet";

describe("settingsSheetAttributes", () => {
  it("takes the closed sheet out of the Tab order, not just the accessibility tree", () => {
    expect(settingsSheetAttributes(false)).toEqual({ inert: true, "aria-hidden": true });
  });

  it("leaves the open sheet fully interactive", () => {
    expect(settingsSheetAttributes(true)).toEqual({ inert: false, "aria-hidden": false });
  });
});

describe("settingsSheetFocusTarget", () => {
  const base = { focusInSheet: false, chromeVisible: true };

  it("moves focus into the sheet when it opens", () => {
    expect(settingsSheetFocusTarget({ ...base, wasOpen: false, open: true })).toBe(
      "close-button",
    );
  });

  it("hands focus back to the gear when the sheet closes around it", () => {
    expect(
      settingsSheetFocusTarget({ ...base, wasOpen: true, open: false, focusInSheet: true }),
    ).toBe("trigger");
  });

  it("leaves focus alone when it was already outside the sheet", () => {
    expect(settingsSheetFocusTarget({ ...base, wasOpen: true, open: false })).toBeNull();
  });

  it("never focuses the gear while the chrome it sits in is hidden", () => {
    expect(
      settingsSheetFocusTarget({
        wasOpen: true,
        open: false,
        focusInSheet: true,
        chromeVisible: false,
      }),
    ).toBeNull();
  });

  it("does nothing when the sheet did not change", () => {
    expect(settingsSheetFocusTarget({ ...base, wasOpen: true, open: true })).toBeNull();
    expect(settingsSheetFocusTarget({ ...base, wasOpen: false, open: false })).toBeNull();
  });
});
