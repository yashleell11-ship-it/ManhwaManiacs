import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

/**
 * The library series page's chapter list costs nothing to scroll.
 *
 * Every chapter of the series is a row, with no windowing, inside one panel.
 * As `glass-panel` that panel was a 20px backdrop blur (28px under Cinema) the
 * height of the whole list, sitting on the page's opaque `bg-bg`: it drew the
 * same pixels it was given and re-ran over most of the viewport on every scroll
 * frame. `glass-flat` keeps the fill and the edge and drops the blur, and
 * `cv-row` lets the rows that are out of view skip layout and paint.
 *
 * The suite has no DOM, so this reads the component's source.
 */

const SOURCE = readFileSync(new URL("./SeriesDetailView.tsx", import.meta.url), "utf8");

/** Every string literal that names one of the classes. */
function classStringsWith(name: string): string[] {
  const pattern = new RegExp(`"[^"\\n]*\\b${name}\\b[^"\\n]*"`, "g");
  return SOURCE.match(pattern) ?? [];
}

describe("SeriesDetailView chapter list", () => {
  it("still draws the chapter list on a glass panel", () => {
    expect(classStringsWith("glass-panel").length).toBeGreaterThan(0);
  });

  it("blurs nothing: every glass surface on the page is flat", () => {
    const surfaces = [...classStringsWith("glass-panel"), ...classStringsWith("glass-card")];
    for (const surface of surfaces) {
      expect(surface, surface).toMatch(/\bglass-flat\b/);
    }
  });

  it("marks each chapter row for content-visibility", () => {
    const rows = classStringsWith("cv-row");
    expect(rows).toHaveLength(1);
    // The row is the chapter link: the one whose hover tints the whole row.
    expect(rows[0]).toMatch(/\bgroup flex items-center gap-4 px-4 py-3\.5\b/);
  });
});
