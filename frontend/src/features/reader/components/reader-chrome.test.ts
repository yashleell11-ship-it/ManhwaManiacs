import { readFileSync } from "node:fs";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { createReadingPercent, type ReadingPercentStore } from "@/features/novels/reading-percent";
import { ReaderControls } from "./ReaderControls";

/**
 * What the reader's chrome costs while the strip scrolls under it.
 *
 * The chrome is fixed over a strip that moves every frame, so anything it
 * re-renders is main-thread work in the hottest path the app has. The scroll
 * percent used to re-render the whole reader to print one number.
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

describe("reader bottom bar", () => {
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

  it("keeps the scroll percent out of React state", () => {
    expect(code).not.toMatch(/\bscrollProgress\b/);
    expect(code).toMatch(/useState\(createReadingPercent\)/);
    expect(code).toMatch(/percentStore\.set\(/);
  });
});
