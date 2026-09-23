import { readFileSync } from "node:fs";
import { join } from "node:path";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createElement, type ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { FollowButton } from "./components/FollowButton";
import { SeriesCard, SeriesListItem } from "./components/SeriesCard";
import { SeriesGrid } from "./components/SeriesGrid";
import type { FollowedSeries } from "./types";

/**
 * The library cards, rendered to markup.
 *
 * `/library/browse` draws up to 200 of them with no virtualisation, so what one
 * card costs is multiplied by the whole shelf: every `backdrop-blur` a
 * separate render pass on each scroll frame, every re-render or remount 200 of
 * them.
 */

function followed(overrides: Partial<FollowedSeries> = {}): FollowedSeries {
  return {
    id: 7,
    source_id: "bato",
    series_key: "solo-leveling",
    title: "Solo Leveling",
    cover_url: "/sources/bato/series/solo-leveling/cover",
    is_favorite: true,
    reading_status: "plan_to_read",
    notify: true,
    sort_order: 0,
    content_rating: "safe",
    rating: "safe",
    mature_override: null,
    chapter_count: 200,
    last_checked_at: null,
    created_at: null,
    updated_at: null,
    ...overrides,
  };
}

function render(element: ReactElement, client = new QueryClient()): string {
  return renderToStaticMarkup(createElement(QueryClientProvider, { client }, element));
}

const noop = () => {};

/** Every corner control a card can show at once: status, checkbox, follow, star. */
function everyControl(): string {
  return [
    render(createElement(SeriesCard, { series: followed(), onSelect: noop })),
    render(createElement(SeriesCard, { series: followed({ reading_status: "dropped" }) })),
    render(createElement(SeriesListItem, { series: followed(), onSelect: noop })),
  ].join("\n");
}

function rootTag(html: string): string {
  return html.match(/^<([a-z]+)/)?.[1] ?? "";
}

describe("library card paint cost", () => {
  it("frosts nothing: no chip, button or checkbox takes a backdrop blur", () => {
    expect(everyControl()).not.toContain("backdrop-blur");
  });

  it("gives the light status chips a dark fill over a cover, now that no frost backs them", () => {
    for (const status of ["plan_to_read", "dropped"]) {
      const html = render(
        createElement(SeriesCard, { series: followed({ reading_status: status }) }),
      );
      const chip = html.match(/<span class="absolute left-2 top-2[^"]*"/)?.[0] ?? "";
      expect(chip).toContain("bg-black/55");
      expect(chip).not.toContain("bg-white/");
    }
  });

  it("leaves the list row's chip as it was: it never sat on a cover or a blur", () => {
    const html = render(createElement(SeriesListItem, { series: followed() }));
    expect(html).toContain("bg-white/20 text-white");
  });

  it("keeps the corner buttons as opaque as the frost made them look", () => {
    const html = render(createElement(SeriesCard, { series: followed(), onSelect: noop }));
    expect(html).toContain('aria-label="Unfollow"');
    expect(html.match(/rounded-full bg-black\/60/g)).toHaveLength(2);
    expect(html).toContain("border-white/50 bg-black/60");
  });

  it("animates no property it does not name", () => {
    expect(everyControl()).not.toContain("transition-all");
  });

  it("fades the hover glow by opacity on its own layer, not by repainting a box-shadow", () => {
    const html = render(createElement(SeriesCard, { series: followed() }));
    expect(html).not.toContain("hover:shadow-glow");
    expect(html).toMatch(
      /<span aria-hidden="true" class="[^"]*opacity-0[^"]*shadow-\[0_0_24px_rgba\(88,166,255,0\.22\)\][^"]*transition-opacity[^"]*group-hover\/card:opacity-100/,
    );
    // The glow answers to the card root's hover.
    expect(html).toMatch(/^<a [^>]*class="[^"]*group\/card/);
  });

  it("draws the list row without a backdrop pass over the flat page", () => {
    const html = render(createElement(SeriesListItem, { series: followed() }));
    expect(html).toContain("glass-card glass-flat");
  });
});

describe("library card render cost", () => {
  it("is memoised, so an unchanged card skips its parent's re-render", () => {
    const memo = Symbol.for("react.memo");
    for (const component of [SeriesCard, SeriesListItem, SeriesGrid]) {
      expect((component as unknown as { $$typeof: symbol }).$$typeof).toBe(memo);
    }
  });

  it("keeps one root element through select mode, so toggling it never remounts the shelf", () => {
    for (const Card of [SeriesCard, SeriesListItem]) {
      const browsing = render(createElement(Card, { series: followed(), onSelect: noop }));
      const selecting = render(
        createElement(Card, { series: followed(), onSelect: noop, selecting: true, selected: true }),
      );
      expect(rootTag(browsing)).toBe("a");
      expect(rootTag(selecting)).toBe(rootTag(browsing));
      expect(selecting).toMatch(/^<a [^>]*role="checkbox"[^>]*aria-checked="true"/);
      expect(selecting).toMatch(/^<a [^>]*aria-label="Select Solo Leveling"/);
      expect(browsing).not.toMatch(/^<a [^>]*role="checkbox"/);
    }
  });

  it("holds no hover state of its own: CSS group-hover already reveals the actions", () => {
    const source = readFileSync(
      join(process.cwd(), "src/features/library/components/SeriesCard.tsx"),
      "utf8",
    );
    expect(source).not.toMatch(/onMouseEnter|onMouseLeave|isHovered/);
  });
});

describe("FollowButton", () => {
  const FOLLOWED_INDEX_KEY = ["library", "followed-index"];

  it("does not watch the whole followed set when it already has its follow id", () => {
    const client = new QueryClient();
    render(
      createElement(FollowButton, {
        series: { sourceId: "bato", seriesKey: "solo-leveling" },
        followedId: 7,
        compact: true,
      }),
      client,
    );
    expect(client.getQueryCache().find({ queryKey: FOLLOWED_INDEX_KEY })).toBeUndefined();
  });

  it("still resolves its follow state from the index when it has no id", () => {
    const client = new QueryClient();
    client.setQueryData(FOLLOWED_INDEX_KEY, [followed({ id: 42 })]);
    const html = render(
      createElement(FollowButton, {
        series: { sourceId: "bato", seriesKey: "solo-leveling" },
        compact: true,
      }),
      client,
    );
    expect(html).toContain('aria-label="Unfollow"');
    expect(
      render(
        createElement(FollowButton, {
          series: { sourceId: "bato", seriesKey: "not-followed" },
          compact: true,
        }),
        client,
      ),
    ).toContain('aria-label="Follow"');
  });
});

describe("ReadingHistoryView", () => {
  const source = readFileSync(
    join(process.cwd(), "src/features/library/components/ReadingHistoryView.tsx"),
    "utf8",
  );

  it("gives the Continue pill a solid fill instead of a backdrop blur", () => {
    const pill = source.match(/const CONTINUE_CLASS =\s*"([^"]*)"/)?.[1] ?? "";
    expect(pill).toContain("bg-black/70");
    expect(pill).not.toContain("backdrop-blur");
  });

  it("animates no property it does not name", () => {
    expect(source).not.toContain("transition-all");
  });
});
