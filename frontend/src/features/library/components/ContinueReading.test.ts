import { createElement, type ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, expect, it } from "vitest";

import { libraryCoverUrl, seriesCoverUrl } from "../api";
import type { ContinueReadingItem } from "../types";
import {
  ContinueReadingRail,
  ContinueReadingStrip,
  continueItemCoverUrl,
  continueItemTitle,
} from "./ContinueReading";

/** The shape an older server sends: no title, no cover. */
const bare: ContinueReadingItem = {
  source_id: "asurascans",
  series_key: "nano-machine-6f7fe6eb",
  chapter_key: "nano-machine-6f7fe6eb:330",
  chapter_number: 330,
  last_page: 7,
  page_count: 24,
  last_read_at: "2026-09-22T09:08:31",
};

const withPayload: ContinueReadingItem = {
  ...bare,
  title: "Nano Machine",
  cover_url: "https://cdn.example.test/covers/nano.webp",
};

const followedTitles = new Map([["asurascans:nano-machine-6f7fe6eb", "Nano Machine (followed)"]]);

function render(element: ReactElement): string {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return renderToStaticMarkup(createElement(QueryClientProvider, { client }, element));
}

describe("continueItemTitle", () => {
  it("uses the title the server joined into the item", () => {
    expect(continueItemTitle(withPayload, followedTitles)).toBe("Nano Machine");
  });

  it("falls back to the followed-series map when the server sent none", () => {
    expect(continueItemTitle(bare, followedTitles)).toBe("Nano Machine (followed)");
    expect(continueItemTitle({ ...bare, title: null }, followedTitles)).toBe(
      "Nano Machine (followed)",
    );
    expect(continueItemTitle({ ...bare, title: "   " }, followedTitles)).toBe(
      "Nano Machine (followed)",
    );
  });

  it("falls back to the key when neither knows the series", () => {
    expect(continueItemTitle(bare, new Map())).toBe("nano-machine-6f7fe6eb");
  });
});

describe("continueItemCoverUrl", () => {
  it("uses the follow row's cover when the server sent one", () => {
    expect(continueItemCoverUrl(withPayload, "70px")).toBe(
      libraryCoverUrl("https://cdn.example.test/covers/nano.webp", "70px"),
    );
  });

  it("resolves a backend-relative cover against the API", () => {
    const relative = { ...bare, cover_url: "/sources/asurascans/series/nano/cover" };
    expect(continueItemCoverUrl(relative, "70px")).toBe(
      libraryCoverUrl("/sources/asurascans/series/nano/cover", "70px"),
    );
  });

  it("falls back to the source cover proxy for the item's key", () => {
    const proxy = seriesCoverUrl(
      { sourceId: "asurascans", seriesKey: "nano-machine-6f7fe6eb" },
      "70px",
    );
    expect(continueItemCoverUrl(bare, "70px")).toBe(proxy);
    expect(continueItemCoverUrl({ ...bare, cover_url: null }, "70px")).toBe(proxy);
    expect(continueItemCoverUrl({ ...bare, cover_url: "" }, "70px")).toBe(proxy);
  });
});

describe("ContinueReadingStrip", () => {
  it("shows the payload's title", () => {
    const html = render(
      createElement(ContinueReadingStrip, { items: [withPayload], titles: followedTitles }),
    );
    expect(html).toContain("Continue reading Nano Machine<");
    expect(html).not.toContain("(followed)");
  });

  it("still shows the followed title for an older server's item", () => {
    const html = render(
      createElement(ContinueReadingStrip, { items: [bare], titles: followedTitles }),
    );
    expect(html).toContain("Nano Machine (followed)");
  });
});

describe("ContinueReadingRail", () => {
  const second: ContinueReadingItem = {
    ...bare,
    series_key: "myst-might-mayhem-6f7fe6eb",
    chapter_key: "myst-might-mayhem-6f7fe6eb:117",
    chapter_number: 117,
    title: "Myst, Might, Mayhem",
  };

  it("titles the hero card and every rail card from the payload", () => {
    const html = render(
      createElement(ContinueReadingRail, {
        items: [withPayload, second],
        titles: followedTitles,
      }),
    );
    expect(html).toContain("Continue Reading");
    expect(html).toContain(">Nano Machine</h3>");
    expect(html).toContain("Myst, Might, Mayhem");
    expect(html).not.toContain("myst-might-mayhem-6f7fe6eb</p>");
  });

  it("renders nothing without items", () => {
    expect(render(createElement(ContinueReadingRail, { items: [], titles: followedTitles }))).toBe(
      "",
    );
  });

  it("takes the caller's classes, so a screen can show it from md up only", () => {
    const html = render(
      createElement(ContinueReadingRail, {
        items: [withPayload],
        titles: followedTitles,
        className: "hidden md:block",
      }),
    );
    expect(html).toMatch(/<section class="[^"]*\bhidden md:block\b/);
  });
});
