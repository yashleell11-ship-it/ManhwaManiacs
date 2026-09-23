import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { DESIGN_PRESETS, type DesignPreset } from "./presets";
import {
  GLOBALS_CSS,
  declarationBlock,
  shapeBaseBlock,
  shapeRuleBody,
} from "./shape-css.testkit";

/**
 * What the glass costs, asserted rather than remembered.
 *
 * Every `backdrop-filter` is its own render pass: the browser reads back what
 * is behind the element and blurs it again on every frame anything under it
 * changes, which on a scrolling grid is every frame. The owner's browsers draw
 * at 2560x1600, so each pass is paid on four million pixels.
 *
 * Two facts make this suite necessary. `blur(0px)` is still a filter, so a
 * preset that sets its blur radius to zero keeps every pass it was meant to
 * drop; only `none` turns it off. And a blur laid over a surface that is
 * already blurred or already flat is invisible, so stacking one costs a full
 * pass and shows nothing.
 */

const SHAPE_BASE = shapeBaseBlock();

/** The shape tokens in force on `<html data-preset="…">`. */
function tokensFor(preset: DesignPreset): Record<string, string> {
  return { ...SHAPE_BASE, ...declarationBlock(`:root[data-preset="${preset}"]`) };
}

/** Substitutes `var(--token)` references until none are left. */
function resolve(value: string, tokens: Record<string, string>): string {
  let current = value;
  for (let depth = 0; depth < 8; depth += 1) {
    const next = current.replace(
      /var\((--[a-z0-9-]+)\)/gi,
      (_, name: string) => tokens[name] ?? `<unset ${name}>`,
    );
    if (next === current) return next;
    current = next;
  }
  throw new Error(`var() chain too deep in ${value}`);
}

/** Every declaration in a rule body, custom property or not. */
function propertiesOf(selector: string): Record<string, string> {
  const declarations: Record<string, string> = {};
  for (const line of shapeRuleBody(`${selector} {`).split(";")) {
    const match = /^([a-z-]+)\s*:\s*([\s\S]+)$/i.exec(line.trim());
    if (match) declarations[match[1]] = match[2].replace(/\s+/g, " ").trim();
  }
  return declarations;
}

/** The character ranges of every `@layer name { … }` block in a stylesheet. */
function layerRanges(css: string): Array<[number, number]> {
  const ranges: Array<[number, number]> = [];
  for (const match of css.matchAll(/@layer[^{;]*\{/g)) {
    const open = (match.index ?? 0) + match[0].length - 1;
    let depth = 0;
    for (let index = open; index < css.length; index += 1) {
      if (css[index] === "{") depth += 1;
      else if (css[index] === "}") {
        depth -= 1;
        if (depth === 0) {
          ranges.push([match.index ?? 0, index]);
          break;
        }
      }
    }
  }
  return ranges;
}

function ruleIndex(selector: string): number {
  const index = GLOBALS_CSS.indexOf(`\n${selector} {`);
  expect(index, `${selector} is not declared in globals.css`).toBeGreaterThan(-1);
  return index;
}

function isUnlayered(selector: string): boolean {
  const index = ruleIndex(selector);
  return layerRanges(GLOBALS_CSS).every(([start, end]) => index < start || index > end);
}

/** The three glass surfaces and the radius each one blurs by. */
const SURFACES = [
  [".glass-panel", "--shape-panel-blur"],
  [".glass-card", "--shape-card-blur"],
  [".empty-state", "--shape-panel-blur"],
] as const;

describe("a preset with no blur pays for no backdrop pass", () => {
  it.each(DESIGN_PRESETS)("%s never emits blur(0)", (preset) => {
    const tokens = tokensFor(preset);
    for (const [selector, radiusToken] of SURFACES) {
      const declared = propertiesOf(selector)["backdrop-filter"];
      expect(declared, `${selector} declares no backdrop-filter`).toBeDefined();
      const effective = resolve(declared, tokens);
      const radius = resolve(`var(${radiusToken})`, tokens);

      expect(effective, `${preset} ${selector}`).not.toMatch(/blur\(\s*0(?:px)?\s*\)/);
      if (/^0(?:px)?$/.test(radius)) {
        // Matte and Editorial: opaque fills, so there is nothing to blur and
        // the pass itself has to go, not just its radius.
        expect(effective, `${preset} ${selector}`).toBe("none");
      } else {
        // Every other preset keeps exactly the blur it had.
        expect(effective, `${preset} ${selector}`).toBe(`blur(${radius})`);
      }
    }
  });

  it.each([
    ["signature", "20px", "12px"],
    ["compact", "14px", "8px"],
    ["cinema", "28px", "18px"],
  ] as const)("%s keeps its frost at %s / %s", (preset, panel, card) => {
    const tokens = tokensFor(preset);
    expect(resolve(propertiesOf(".glass-panel")["backdrop-filter"], tokens)).toBe(
      `blur(${panel})`,
    );
    expect(resolve(propertiesOf(".glass-card")["backdrop-filter"], tokens)).toBe(
      `blur(${card})`,
    );
  });

  it("turns both passes off in the two opaque presets", () => {
    for (const preset of ["flat", "editorial"] as const) {
      const tokens = tokensFor(preset);
      expect(tokens["--shape-panel-backdrop"], preset).toBe("none");
      expect(tokens["--shape-card-backdrop"], preset).toBe("none");
    }
  });
});

describe("the shared opt-out classes", () => {
  it("offers .glass-flat: same fill and edge, no backdrop pass", () => {
    // Exactly the two declarations, so a surface that opts out keeps its
    // colour, its border and its radius and loses only the blur.
    expect(propertiesOf(".glass-flat")).toEqual({
      "-webkit-backdrop-filter": "none",
      "backdrop-filter": "none",
    });
  });

  it("declares .glass-flat after every glass surface so it wins on source order", () => {
    // Same specificity as the surfaces it overrides, so order decides. The
    // class list order on the element does not matter; this does.
    const flat = ruleIndex(".glass-flat");
    for (const [selector] of SURFACES) {
      expect(flat, `.glass-flat must follow ${selector}`).toBeGreaterThan(ruleIndex(selector));
    }
  });

  it("keeps the glass rules and their opt-out unlayered", () => {
    // Unlayered beats every @layer, which is why a Tailwind utility cannot
    // turn the glass off. The opt-out has to live in the same tier or it
    // would lose to the rule it exists to override.
    for (const selector of [".glass-panel", ".glass-card", ".empty-state", ".glass-flat"]) {
      expect(isUnlayered(selector), selector).toBe(true);
    }
  });

  it.each([
    [".cv-row", "auto 3.5rem"],
    [".cv-card", "auto 22rem"],
  ])("offers %s for long lists", (selector, size) => {
    expect(isUnlayered(selector), selector).toBe(true);
    expect(propertiesOf(selector)).toEqual({
      "content-visibility": "auto",
      "contain-intrinsic-size": size,
    });
  });

  it("reads each backdrop token from its blur radius in the base", () => {
    // Compact and Cinema move only the radius; deriving the filter from it
    // is what lets them keep doing that without restating the filter.
    expect(SHAPE_BASE["--shape-panel-backdrop"]).toBe("blur(var(--shape-panel-blur))");
    expect(SHAPE_BASE["--shape-card-backdrop"]).toBe("blur(var(--shape-card-blur))");
  });
});

describe("dialogs pay for one backdrop pass at most", () => {
  const DIALOG = readFileSync(
    path.resolve(__dirname, "../../components/ui/dialog.tsx"),
    "utf8",
  );
  const overlay = /className="(overlay-in[^"]*)"/.exec(DIALOG)?.[1] ?? "";
  const panel = /"(panel-in[^"]*)"/.exec(DIALOG)?.[1] ?? "";

  function passes(classes: string): number {
    const list = classes.split(/\s+/);
    const glass =
      (list.includes("glass-panel") || list.includes("glass-card")) &&
      !list.includes("glass-flat");
    const utility = list.some((name) => /^(?:[a-z]+:)*backdrop-(?:blur|filter)/.test(name));
    return (glass ? 1 : 0) + (utility ? 1 : 0);
  }

  it("finds the scrim and the panel", () => {
    // A pattern that matched nothing would make the rest vacuously true.
    expect(overlay).toContain("inset-0");
    expect(panel).toContain("rounded-2xl");
  });

  it("does not blur the whole viewport behind a dialog", () => {
    // The scrim covers every pixel of the screen, so a blur on it is the
    // most expensive pass the app can ask for, and it is redone for every
    // frame of the entrance animations and every caret blink underneath.
    expect(passes(overlay), overlay).toBe(0);
  });

  it("never stacks a second blur on the first", () => {
    expect(passes(overlay) + passes(panel)).toBeLessThanOrEqual(1);
  });

  it("dims the page at least as much as the frosted scrim did", () => {
    // Without the blur the page behind is sharp, so the scrim is denser than
    // the old 80% to keep the dialog standing off the page as clearly.
    const alpha = Number(/(?:^|\s)bg-bg\/(\d+)(?:\s|$)/.exec(overlay)?.[1] ?? 0);
    expect(alpha).toBeGreaterThanOrEqual(85);
  });
});
