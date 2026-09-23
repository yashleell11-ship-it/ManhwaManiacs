import { describe, expect, it } from "vitest";
import { novelContentsHref } from "./novel-link";

describe("novelContentsHref", () => {
  it("opens the book's page at the chapter's KEY", () => {
    // TBATE key 122 is printed "Chapter 120": the link carries the key, and
    // the page finds the row by it — never by a number.
    expect(novelContentsHref({ sourceId: "novelfull", seriesKey: "tbate", chapterKey: "122" })).toBe(
      "/sources/novelfull/series/tbate?chapter=122",
    );
  });

  it("keeps an opaque key with slashes intact", () => {
    const href = novelContentsHref({
      sourceId: "royal road",
      seriesKey: "the-wandering-inn",
      chapterKey: "chapter/1.00 R",
    });
    expect(href).toBe(
      "/sources/royal%20road/series/the-wandering-inn?chapter=chapter%2F1.00+R",
    );
    expect(new URL(href, "https://x.test").searchParams.get("chapter")).toBe("chapter/1.00 R");
  });
});
