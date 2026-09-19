import { describe, expect, it } from "vitest";

import { __test__ } from "./NovelAudioPlayer";

const { clock } = __test__;

describe("clock", () => {
  it("reads as minutes and seconds", () => {
    expect(clock(0)).toBe("0:00");
    expect(clock(61_000)).toBe("1:01");
    expect(clock(737_263)).toBe("12:17");
  });

  it("shows hours only when there is an hour", () => {
    expect(clock(3_599_000)).toBe("59:59");
    expect(clock(3_600_000)).toBe("1:00:00");
  });

  it("never shows a negative position", () => {
    // Some players report a small negative time while seeking.
    expect(clock(-500)).toBe("0:00");
  });

  it("truncates rather than rounding up", () => {
    // Rounding would show 12:18 while the audio is still at 12:17, so the
    // clock would read one second ahead of the voice.
    expect(clock(1_999)).toBe("0:01");
  });
});
