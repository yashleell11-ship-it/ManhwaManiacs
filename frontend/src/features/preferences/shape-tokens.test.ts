import { describe, expect, it } from "vitest";
import { THEME_CSS_SOURCES } from "./theme-css.testkit";
import {
  GLOBALS_CSS,
  containsColourLiteral,
  declarationsIn,
  referenceCount,
  shapeBaseBlock,
  shapeRuleBody,
} from "./shape-css.testkit";

/**
 * The colour / shape split, asserted rather than remembered.
 *
 * The design system has two orthogonal halves. A THEME says what colour the
 * app is (`--mm-*`, ~42 palettes). A PRESET says what shape it is
 * (`--shape-*`, plus the Tailwind scale tokens). Every combination has to be
 * coherent — Nord + Compact and Nord + Editorial are both real choices a
 * viewer can make — and the only way that stays true as either half grows is
 * if neither can reach into the other.
 *
 * Two rules do the whole job, and they are mechanical:
 *
 *   1. a `--shape-*` value is a length, a number, a keyword or a `var()`
 *      pointing at a theme role — never a colour literal;
 *   2. a `:root[data-theme=…]` block never declares a `--shape-*`.
 *
 * Everything else here guards the wiring that makes rule 1 possible: the
 * surfaces, the page frame and the type scale have to READ the roles, or a
 * preset would be a set of variables nothing consumes.
 */

const SHAPE_ROLES = shapeBaseBlock();

describe("shape role vocabulary", () => {
  it("declares a non-trivial set of shape roles", () => {
    const names = Object.keys(SHAPE_ROLES);
    expect(names.length).toBeGreaterThan(10);
    for (const name of names) {
      expect(name, `${name} is not in the shape namespace`).toMatch(/^--shape-/);
    }
  });

  it("hard-codes no colour in any shape role", () => {
    // The load-bearing rule. `--shape-panel-fill: var(--mm-glass-panel)` is
    // fine and is the entire point: the preset picks WHICH role paints the
    // panel, the theme decides what colour that role is.
    for (const [name, value] of Object.entries(SHAPE_ROLES)) {
      expect(containsColourLiteral(value), `${name}: ${value}`).toBe(false);
    }
  });

  it("routes every colour-bearing shape role through a theme role", () => {
    // The three roles that carry paint rather than geometry. Each has to be a
    // bare `var(--mm-…)` — anything else would be a preset inventing a colour
    // by a longer route (a gradient, a color-mix with a literal).
    for (const role of [
      "--shape-panel-fill",
      "--shape-panel-edge",
      "--shape-card-fill",
      "--shape-card-edge",
      "--shape-glow",
      "--shape-panel-shadow",
    ] as const) {
      expect(SHAPE_ROLES[role], role).toMatch(/^var\(--mm-[a-z-]+\)$/);
    }
  });

  it("reads every shape role it declares", () => {
    // A token nothing consumes is a preset knob wired to nothing — which is
    // how a design system quietly stops describing the app it ships with.
    for (const name of Object.keys(SHAPE_ROLES)) {
      expect(referenceCount(name), `${name} is declared but never read`).toBeGreaterThan(
        0,
      );
    }
  });
});

describe("themes stay out of the shape namespace", () => {
  it("declares no shape role in any palette block", () => {
    // Both stylesheets: the four hand-written palettes in globals.css and the
    // thirty-eight generated ones. A palette has no opinion about padding.
    for (const [name, css] of Object.entries(THEME_CSS_SOURCES)) {
      for (const match of css.matchAll(
        /:root(?:\[data-theme="[a-z0-9-]+"\]|:not\(\[data-theme\]\))\s*\{([^}]*)\}/gi,
      )) {
        const declared = Object.keys(declarationsIn(match[1]));
        expect(
          declared.filter((token) => token.startsWith("--shape-")),
          `${name}: ${match[0].slice(0, 40)} declares shape tokens`,
        ).toEqual([]);
      }
    }
  });

  it("keeps the colour base and the shape base in separate :root blocks", () => {
    // `theme-css.testkit.ts` reads the FIRST `:root {` as the palette base, so
    // the two must not be merged — and the colour base must stay first.
    const first = GLOBALS_CSS.indexOf(":root {");
    const second = GLOBALS_CSS.indexOf(":root {", first + 1);
    expect(second).toBeGreaterThan(first);
    const colourBase = Object.keys(
      declarationsIn(
        GLOBALS_CSS.slice(
          GLOBALS_CSS.indexOf("{", first) + 1,
          GLOBALS_CSS.indexOf("}", first),
        ),
      ),
    );
    expect(colourBase.some((token) => token.startsWith("--mm-"))).toBe(true);
    expect(colourBase.some((token) => token.startsWith("--shape-"))).toBe(false);
  });
});

describe("the rules a preset moves", () => {
  it("builds both app surfaces out of shape roles only", () => {
    // Fill, blur and edge weight are the surface-treatment axis — the single
    // most visible thing a preset changes. All three have to be indirect, or
    // `Matte` could not exist without a second stylesheet. The blur is read
    // as a whole filter value so a preset can say `none` rather than a zero
    // radius, which would still cost a backdrop pass (`glass-cost.test.ts`);
    // the base derives that value from the radius role.
    for (const [selector, fill, backdrop, blur, edge] of [
      [
        ".glass-panel",
        "--shape-panel-fill",
        "--shape-panel-backdrop",
        "--shape-panel-blur",
        "--shape-panel-edge",
      ],
      [
        ".glass-card",
        "--shape-card-fill",
        "--shape-card-backdrop",
        "--shape-card-blur",
        "--shape-card-edge",
      ],
    ] as const) {
      const body = shapeRuleBody(`${selector} {`);
      expect(body, selector).toContain(`var(${fill})`);
      expect(body, selector).toContain(`backdrop-filter: var(${backdrop})`);
      expect(SHAPE_ROLES[backdrop], backdrop).toBe(`blur(var(${blur}))`);
      expect(body, selector).toContain(`var(${edge})`);
      expect(body, selector).toContain("var(--shape-edge-width)");
      // And nothing hard-coded is left behind.
      expect(body, selector).not.toMatch(/blur\(\d/);
      expect(body, selector).not.toMatch(/var\(--mm-glass/);
    }
  });

  it("frames the page from shape roles", () => {
    expect(shapeRuleBody(".page-shell {")).toContain("var(--shape-page-pad)");
    expect(shapeRuleBody(".page-container {")).toContain("var(--shape-page-measure)");
    const title = shapeRuleBody(".page-title {");
    expect(title).toContain("var(--shape-heading-font)");
    expect(title).toContain("var(--shape-title-size)");
    expect(shapeRuleBody(".font-display {")).toContain("var(--shape-heading-font)");
  });

  it("routes the two ambient effects through shape roles", () => {
    // `--shadow-glow` / `--shadow-glass` are what `shadow-glow` and
    // `shadow-glass` compile to. Presets that want a calmer surface set the
    // shape role to `none`; the theme still owns the colour when there is one.
    const colourBase = shapeRuleBody(":root {");
    expect(colourBase).toContain("--shadow-glow: var(--shape-glow)");
    expect(colourBase).toContain("--shadow-glass: var(--shape-panel-shadow)");
  });

  it("scales the app's own animations by the motion role", () => {
    for (const selector of [
      ".reader-end-card-enter {",
      ".reader-page-transition-enter {",
    ]) {
      expect(shapeRuleBody(selector), selector).toContain("var(--shape-motion)");
    }
  });
});

describe("Eclipse-era values survive the extraction", () => {
  /**
   * The regression bar. Extracting a literal into a variable is only safe if
   * the variable holds the same literal, and these are the numbers the app the
   * owner uses daily is built from. Changing one is a design decision; changing
   * one by accident is this test failing.
   */
  it.each([
    ["--shape-panel-blur", "20px"],
    ["--shape-card-blur", "12px"],
    ["--shape-panel-backdrop", "blur(var(--shape-panel-blur))"],
    ["--shape-card-backdrop", "blur(var(--shape-card-blur))"],
    ["--shape-edge-width", "1px"],
    ["--shape-page-pad", "1.5rem"],
    ["--shape-page-pad-wide", "2.5rem"],
    ["--shape-page-measure", "80rem"],
    ["--shape-empty-pad", "3rem"],
    ["--shape-title-size", "2.25rem"],
    ["--shape-title-leading", "1"],
    ["--shape-title-tracking", "0.025em"],
    ["--shape-subtitle-size", "0.875rem"],
    ["--shape-heading-font", "var(--font-display)"],
    ["--shape-motion", "1"],
  ])("%s is still %s", (role, value) => {
    expect(SHAPE_ROLES[role]).toBe(value);
  });
});
