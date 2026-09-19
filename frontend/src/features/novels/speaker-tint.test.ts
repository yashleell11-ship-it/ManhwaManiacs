import { describe, expect, it } from "vitest";

import { speakerHues, tintParagraph, type SpeakerSpan } from "./speaker-tint";

/**
 * Tinting is only ever as trustworthy as the offsets behind it, and the text
 * those offsets index lives in a seven-day cache that REFETCHES. So most of
 * the behaviour under test is about refusing to tint.
 */

const P = "He paused. “Then we go,” he said, “and we do not stop.”";
const FIRST = "Then we go,";
const SECOND = "and we do not stop.";

/**
 * Offsets derived from the text rather than hand-counted. A miscounted fixture
 * tests the fixture; this produces exactly what the server computes.
 */
function at(text: string, speaker: string | null, head?: string): SpeakerSpan {
  const s = P.indexOf(text);
  if (s < 0) throw new Error(`fixture not in paragraph: ${text}`);
  return { s, e: s + text.length, speaker, head: head ?? text.slice(0, 14) };
}

describe("tintParagraph", () => {
  it("splits narration from speech", () => {
    const runs = tintParagraph(P, [at(FIRST, "Arthur")]);

    expect(runs).not.toBeNull();
    expect(runs!.map((r) => r.speaker)).toEqual([null, "Arthur", null]);
  });

  it("puts every character back, exactly once", () => {
    // The paragraph the reader sees must be the paragraph that was there.
    const runs = tintParagraph(P, [at(FIRST, "Arthur"), at(SECOND, "Arthur")]);

    expect(runs!.map((r) => r.text).join("")).toBe(P);
  });

  it("leaves the quote marks themselves as narration", () => {
    // They sit outside the span, which is what the server stores.
    const text = "“Go.” He turned away.";
    const runs = tintParagraph(text, [{ s: 1, e: 4, speaker: "Tessia", head: "Go." }]);

    expect(runs![0]).toEqual({ text: "“", speaker: null });
    expect(runs![1]).toEqual({ text: "Go.", speaker: "Tessia" });
  });

  it("keeps an unattributed quote as a run with no speaker", () => {
    // It is still speech — it just gets read in the narrator's voice.
    const runs = tintParagraph(P, [at(FIRST, null)]);

    expect(runs!.find((r) => r.text === FIRST)!.speaker).toBeNull();
  });

  it("sorts spans that arrive out of order", () => {
    const runs = tintParagraph(P, [at(SECOND, "Arthur"), at(FIRST, "Arthur")]);

    expect(runs!.map((r) => r.text).join("")).toBe(P);
  });

  it("does not tint a paragraph with no spans", () => {
    expect(tintParagraph(P, [])).toBeNull();
  });
});

describe("tintParagraph refuses offsets it cannot prove", () => {
  it("rejects a head that no longer matches", () => {
    // The chapter cache refetched and the text moved. Tinting here would put
    // one character's colour on somebody else's words.
    const runs = tintParagraph(P, [{ ...at(FIRST, "Arthur"), head: "Something else" }]);

    expect(runs).toBeNull();
  });

  it("rejects offsets shifted by an astral character", () => {
    // The server counts code POINTS, JavaScript counts UTF-16 units. One emoji
    // ahead of the quote slides every later offset by one, silently.
    const shifted = `\u{1F600}${P}`;
    const runs = tintParagraph(shifted, [at(FIRST, "Arthur")]);

    expect(runs).toBeNull();
  });

  it("rejects overlapping spans rather than dropping one", () => {
    const first = at(FIRST, "Arthur");
    const runs = tintParagraph(P, [
      first,
      { s: first.s + 4, e: first.e + 6, speaker: "Tessia", head: "" },
    ]);

    expect(runs).toBeNull();
  });

  it("rejects a span running past the end of the paragraph", () => {
    const runs = tintParagraph(P, [{ ...at(FIRST, "Arthur"), e: 9999, head: "" }]);

    expect(runs).toBeNull();
  });

  it("rejects an empty or inverted span", () => {
    const f = at(FIRST, "A");
    expect(tintParagraph(P, [{ s: f.s, e: f.s, speaker: "A", head: "" }])).toBeNull();
    expect(tintParagraph(P, [{ s: f.e, e: f.s, speaker: "A", head: "" }])).toBeNull();
  });

  it("trusts a span carrying no head on its bounds alone", () => {
    const runs = tintParagraph(P, [{ ...at(FIRST, "Arthur"), head: "" }]);

    expect(runs).not.toBeNull();
  });
});

describe("speakerHues", () => {
  it("gives each speaker their own hue", () => {
    expect(new Set(speakerHues(["Arthur", "Myre", "Tessia"]).values()).size).toBe(3);
  });

  it("puts the two busiest speakers far apart", () => {
    // A hash spreads evenly but can drop the two people in one scene a few
    // degrees apart, where they read as the same colour.
    const [a, b] = [...speakerHues(["Arthur", "Myre"]).values()];

    expect(Math.abs(a - b)).toBeGreaterThan(60);
  });

  it("is stable for the same cast order", () => {
    const cast = ["Arthur", "Myre", "Tessia"];

    expect([...speakerHues(cast)]).toEqual([...speakerHues(cast)]);
  });

  it("ignores a repeated name", () => {
    expect(speakerHues(["Arthur", "Arthur", "Myre"]).size).toBe(2);
  });

  it("wraps rather than running out", () => {
    const many = Array.from({ length: 30 }, (_, i) => `N${i}`);

    expect(speakerHues(many).size).toBe(30);
  });
});
