import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { cardActionVisibility } from "./card-actions";

describe("cardActionVisibility", () => {
  it("shows a pinned action (an existing favourite) outright", () => {
    expect(cardActionVisibility(true)).toBe("opacity-100");
  });

  it("hides the rest from sm up until hover — or keyboard focus — reaches them", () => {
    const classes = cardActionVisibility(false).split(" ");
    expect(classes).toContain("sm:opacity-0");
    expect(classes).toContain("sm:group-hover:opacity-100");
    // The focused button shows itself and its ring…
    expect(classes).toContain("sm:focus-visible:opacity-100");
    // …and its sibling shows while focus is anywhere in the card.
    expect(classes).toContain("sm:group-focus-within:opacity-100");
  });

  it("stays visible on a phone, where there is no hover to wait for", () => {
    expect(cardActionVisibility(false).split(" ")).toContain("opacity-100");
  });
});

describe("SeriesCard", () => {
  // The bug was a class string written inline twice without the focus half.
  // Anything on the card that is hidden until hover must also show on focus.
  const source = readFileSync(
    join(process.cwd(), "src/features/library/components/SeriesCard.tsx"),
    "utf8",
  );

  it("hides nothing from sm up that focus cannot reveal", () => {
    const hiddenWithoutFocus = [...source.matchAll(/"[^"]*sm:opacity-0[^"]*"/g)]
      .map(([classes]) => classes)
      .filter((classes) => !classes.includes("focus"));
    expect(hiddenWithoutFocus).toEqual([]);
  });

  it("routes both corner actions through the shared rule", () => {
    expect(source.match(/cardActionVisibility\(/g)).toHaveLength(2);
  });
});
