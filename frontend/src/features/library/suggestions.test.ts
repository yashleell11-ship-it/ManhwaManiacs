import { describe, expect, it } from "vitest";
import {
  canSubmitPrompt,
  droppedNotice,
  MAX_PROMPT_LENGTH,
  MIN_PROMPT_LENGTH,
  suggestionKey,
} from "./suggestions";

describe("spending a request", () => {
  it("refuses a description too short to mean anything", () => {
    // Refused here rather than by a 422, so a stray keystroke costs nothing.
    expect(canSubmitPrompt("", false)).toBe(false);
    expect(canSubmitPrompt("a", false)).toBe(false);
    expect(canSubmitPrompt("   ", false)).toBe(false);
  });

  it("refuses whitespace padding that only looks long enough", () => {
    expect(canSubmitPrompt("  a  ", false)).toBe(false);
  });

  it("allows a real description", () => {
    expect(canSubmitPrompt("murim", false)).toBe(true);
    expect(canSubmitPrompt("a".repeat(MIN_PROMPT_LENGTH), false)).toBe(true);
  });

  it("refuses a second request while one is in flight", () => {
    // One submit is one paid call; double-tapping the button must not be two.
    expect(canSubmitPrompt("a revenge story", true)).toBe(false);
  });

  it("agrees with the server about the bounds", () => {
    expect(MIN_PROMPT_LENGTH).toBe(3);
    expect(MAX_PROMPT_LENGTH).toBe(600);
  });
});

describe("titles nothing carries", () => {
  it("says nothing when nothing was dropped", () => {
    expect(droppedNotice(0)).toBeNull();
    expect(droppedNotice(-1)).toBeNull();
  });

  it("counts one in the singular", () => {
    expect(droppedNotice(1)).toBe(
      "1 more suggestion skipped — no source here carries them.",
    );
  });

  it("counts several in the plural", () => {
    expect(droppedNotice(3)).toContain("3 more suggestions skipped");
  });
});

describe("identity", () => {
  it("keys on the source as well as the series", () => {
    // The same book on two sources is two openable rows, not one.
    const a = suggestionKey({ source: "asurascans", series_id: "nano-machine" });
    const b = suggestionKey({ source: "demonicscans", series_id: "nano-machine" });
    expect(a).not.toBe(b);
  });
});
