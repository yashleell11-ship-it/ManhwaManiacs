import { readFileSync } from "node:fs";
import { join } from "node:path";

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { SourceSeriesSummary } from "../types";
import { SourceSeriesCard } from "./SourceSeriesCard";
import { SourceSeriesGrid } from "./SourceSeriesGrid";

/**
 * What the source catalog and a source series page cost to scroll.
 *
 * `.glass-card` and `.glass-panel` carry a `backdrop-filter`, and each element
 * wearing one is re-blurred on every scroll frame. These screens paint them
 * over the shell's flat or smoothly graded background, where the blur shows
 * nothing, so each surface either drops the class or adds `glass-flat`.
 */

const REACT_MEMO = Symbol.for("react.memo");

function readComponent(name: string): string {
  return readFileSync(
    join(process.cwd(), "src/features/sources/components", name),
    "utf8",
  );
}

/** Every class list in the markup that still asks for a backdrop blur. */
function blurredClassLists(html: string): string[] {
  return [...html.matchAll(/class="([^"]*)"/g)]
    .map(([, classes]) => classes.split(/\s+/))
    .filter(
      (classes) =>
        (classes.includes("glass-card") || classes.includes("glass-panel")) &&
        !classes.includes("glass-flat"),
    )
    .map((classes) => classes.join(" "));
}

const SERIES: SourceSeriesSummary = {
  id: "solo leveling",
  source_id: "src",
  title: "Solo Leveling",
  chapter_count: 200,
  description: null,
  author: null,
  artist: null,
  status: null,
  genres: [],
  latest_chapter: null,
  cover_url: "https://covers.example/solo.jpg",
};

function renderCard(): string {
  return renderToStaticMarkup(
    createElement(SourceSeriesCard, { sourceId: "src", series: SERIES }),
  );
}

describe("SourceSeriesCard", () => {
  it("puts no backdrop blur behind a catalog cover", () => {
    expect(blurredClassLists(renderCard())).toEqual([]);
  });

  it("keeps the card fill and edge the glass card painted", () => {
    const html = renderCard();
    const tile = html.match(/<a [^>]*><div class="([^"]*)"/)?.[1].split(" ");
    // `.glass-card` is unlayered, so these are the declarations it resolved
    // to on the old cell: fill, edge width and colour, the radius and the
    // colour transition. Only the blur is gone.
    expect(tile).toEqual(
      expect.arrayContaining([
        "bg-(--shape-card-fill)",
        "border-(length:--shape-edge-width)",
        "border-(color:--shape-card-edge)",
        "rounded-xl",
        "overflow-hidden",
        "transition-colors",
        "duration-200",
        "group",
      ]),
    );
    // Dead while `.glass-card` outranked them; live now, and they would turn
    // the tile transparent.
    expect(tile).not.toContain("bg-transparent");
    expect(tile).not.toContain("border-transparent");
  });

  it("lets a cell far off screen skip layout and paint", () => {
    const link = renderCard().match(/<a [^>]*class="([^"]*)"/)?.[1].split(" ");
    expect(link).toContain("cv-card");
  });

  it("skips the render when a page lands and its props have not changed", () => {
    expect((SourceSeriesCard as unknown as { $$typeof: symbol }).$$typeof).toBe(REACT_MEMO);
  });
});

describe("SourceSeriesGrid", () => {
  it("skips the render when the browse view re-renders around it", () => {
    expect((SourceSeriesGrid as unknown as { $$typeof: symbol }).$$typeof).toBe(REACT_MEMO);
  });
});

describe("SourceBrowserView", () => {
  const source = readComponent("SourceBrowserView.tsx");
  const view = source.slice(
    source.indexOf("export function SourceBrowserView"),
    source.indexOf("\nfunction SourceSearchForm"),
  );

  it("finds the view and the search form", () => {
    expect(view).toContain("<SourceSeriesGrid");
    expect(source).toContain("function SourceSearchForm");
  });

  it("keeps each keystroke out of the view that renders the catalog", () => {
    // The typed text is state on the form; the view holds only the settled
    // query, so a keystroke does not re-render every loaded card.
    expect(view).not.toContain("setSearch");
    expect(view).not.toContain("useDebouncedValue(");
    expect(view).not.toContain("<Input");
    expect(view).toContain("<SourceSearchForm onQueryChange={setQuery}>");
  });
});
