import { readFileSync } from "node:fs";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { createReadingPercent, type ReadingPercentStore } from "@/features/novels/reading-percent";
import { ReaderControls } from "./ReaderControls";

/**
 * What the reader's chrome costs while the strip scrolls under it.
 *
 * The chrome is fixed over a strip that moves every frame, so anything on it
 * with a backdrop-filter is re-sampled and re-blurred every frame, and
 * anything it re-renders is main-thread work in the hottest path the app has.
 * These pin the three places that used to pay for nothing: a hidden bar that
 * kept its blur alive, a page counter blurring art it could simply cover, and
 * a scroll percent that re-rendered the whole reader to print one number.
 */

const noop = () => {};

function renderControls(overrides: { visible: boolean; progress?: ReadingPercentStore }): string {
  return renderToStaticMarkup(
    createElement(ReaderControls, {
      chapterTitle: "Chapter 12",
      progress: overrides.progress ?? createReadingPercent(),
      visiblePage: 3,
      pageCount: 20,
      zoom: 1,
      onZoomIn: noop,
      onZoomOut: noop,
      onZoomReset: noop,
      readingMode: "continuous",
      onReadingModeChange: noop,
      fitMode: "width",
      onFitModeChange: noop,
      direction: "ltr",
      onDirectionChange: noop,
      onSeekPage: noop,
      fullscreen: false,
      fullscreenSupported: true,
      onToggleFullscreen: noop,
      onShowShortcuts: noop,
      previousChapterHref: null,
      nextChapterHref: "/reader/next",
      seriesHref: "/series",
      onOpenSeries: noop,
      visible: overrides.visible,
    }),
  );
}

/** The classes of the fixed wrapper that holds the blurred bottom bar. */
function barWrapperClasses(html: string): string[] {
  const panel = html.indexOf('class="glass-panel');
  expect(panel, "the bottom bar's glass panel is missing").toBeGreaterThan(-1);
  const wrappers = [...html.slice(0, panel).matchAll(/<div class="([^"]*\bfixed\b[^"]*)"/g)];
  const nearest = wrappers.at(-1);
  expect(nearest, "no fixed wrapper around the bottom bar").toBeDefined();
  return nearest![1].split(/\s+/);
}

describe("reader bottom bar", () => {
  it("leaves visibility once hidden, so its blur is not kept alive over the strip", () => {
    const classes = barWrapperClasses(renderControls({ visible: false }));
    expect(classes).toContain("invisible");
    // The slide-and-fade out still plays: visibility rides the same transition
    // and only flips at its end.
    expect(classes).toEqual(
      expect.arrayContaining(["translate-y-full", "opacity-0", "transition-all"]),
    );
  });

  it("is visible and in place while the chrome is up", () => {
    const classes = barWrapperClasses(renderControls({ visible: true }));
    expect(classes).not.toContain("invisible");
    expect(classes).toEqual(expect.arrayContaining(["translate-y-0", "opacity-100"]));
  });

  it("comes back visible at once, so the Tab that reveals it can land in it", () => {
    // A visibility transition out of `hidden` is still hidden at its first
    // instant, which is when the browser moves focus for that same key press.
    const classes = barWrapperClasses(renderControls({ visible: true }));
    expect(classes).toContain("transition-[opacity,translate]");
    expect(classes).not.toContain("transition-all");
  });

  it("prints the chapter percent from the store the reader writes to", () => {
    const progress = createReadingPercent();
    progress.set(41.6);
    expect(renderControls({ visible: true, progress })).toContain(" · 42%");
  });
});

describe("ChapterReader chrome", () => {
  // Code only: the comments explain the old state by name.
  const code = readFileSync(new URL("./ChapterReader.tsx", import.meta.url), "utf8")
    .replace(/\{\/\*[\s\S]*?\*\/\}/g, "")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^\s*\/\/.*$/gm, "");

  it("draws the page counter as flat glass with a fill dense enough for bright pages", () => {
    const pill = code.match(
      /className="([^"]*)"\s*>\s*\{visiblePage\} <span className="text-muted">\/ \{pages\.length\}/,
    );
    expect(pill, "the page counter pill is missing").not.toBeNull();
    const classes = pill![1].split(/\s+/);
    expect(classes).toContain("glass-flat");
    // `.glass-panel` is unlayered, so only an important background beats it.
    expect(classes.some((name) => /^bg-.+!$/.test(name))).toBe(true);
  });

  it("keeps the scroll percent out of React state", () => {
    expect(code).not.toMatch(/\bscrollProgress\b/);
    expect(code).toMatch(/useState\(createReadingPercent\)/);
    expect(code).toMatch(/percentStore\.set\(/);
  });
});
