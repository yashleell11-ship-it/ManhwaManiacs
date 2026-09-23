import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { KeyboardProvider } from "@/lib/keyboard";

import { SeriesGrid, type SeriesGridSelection } from "./components/SeriesGrid";
import type { FollowedSeries } from "./types";

/**
 * What the grid hands each card, captured in place of the card. A memoised
 * card re-renders only when a prop changes by `Object.is`, so an unchanged
 * card must get props that compare equal from one grid render to the next.
 */
const { rendered } = vi.hoisted(() => ({
  rendered: [] as Array<{ id: number; props: Record<string, unknown> }>,
}));

vi.mock("./components/SeriesCard", () => {
  const capture = (props: Record<string, unknown>) => {
    rendered.push({ id: (props.series as { id: number }).id, props });
    return null;
  };
  return { SeriesCard: capture, SeriesListItem: capture };
});

function row(id: number): FollowedSeries {
  return {
    id,
    source_id: "bato",
    series_key: `series-${id}`,
    title: `Series ${id}`,
    cover_url: "",
    is_favorite: false,
    reading_status: "reading",
    notify: true,
    sort_order: 0,
    content_rating: "safe",
    rating: "safe",
    mature_override: null,
    chapter_count: 1,
    last_checked_at: null,
    created_at: null,
    updated_at: null,
  };
}

const items = [row(1), row(2), row(3)];
const onSelect = () => {};

function propsPerCard(
  density: "comfortable" | "list",
  selection: SeriesGridSelection,
): Map<number, Record<string, unknown>> {
  rendered.length = 0;
  renderToStaticMarkup(
    createElement(
      KeyboardProvider,
      null,
      createElement(SeriesGrid, { items, density, selection }),
    ),
  );
  return new Map(rendered.map(({ id, props }) => [id, props]));
}

/** `React.memo`'s own comparison. */
function shallowEqual(a: Record<string, unknown>, b: Record<string, unknown>): boolean {
  const keys = Object.keys(a);
  return (
    keys.length === Object.keys(b).length &&
    keys.every((key) => Object.prototype.hasOwnProperty.call(b, key) && Object.is(a[key], b[key]))
  );
}

describe("SeriesGrid card props", () => {
  beforeEach(() => {
    rendered.length = 0;
  });

  for (const density of ["comfortable", "list"] as const) {
    it(`re-renders only the card a selection click changed (${density})`, () => {
      const before = propsPerCard(density, {
        selecting: true,
        selectedIds: new Set([1]),
        onSelect,
      });
      const after = propsPerCard(density, {
        selecting: true,
        selectedIds: new Set([1, 2]),
        onSelect,
      });

      expect(shallowEqual(before.get(1)!, after.get(1)!)).toBe(true);
      expect(shallowEqual(before.get(3)!, after.get(3)!)).toBe(true);
      expect(shallowEqual(before.get(2)!, after.get(2)!)).toBe(false);
      expect(after.get(2)).toMatchObject({ selected: true, selecting: true, onSelect });
    });
  }

  it("tells every card when select mode starts", () => {
    const browsing = propsPerCard("comfortable", {
      selecting: false,
      selectedIds: new Set(),
      onSelect,
    });
    const selecting = propsPerCard("comfortable", {
      selecting: true,
      selectedIds: new Set(),
      onSelect,
    });
    for (const id of [1, 2, 3]) {
      expect(browsing.get(id)).toMatchObject({ selecting: false, selected: false });
      expect(selecting.get(id)).toMatchObject({ selecting: true, selected: false });
    }
  });
});
