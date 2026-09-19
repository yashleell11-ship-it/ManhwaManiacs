import { describe, expect, it } from "vitest";

import { novelAudioUrl } from "./audio-url";

describe("novelAudioUrl", () => {
  const ref = { sourceId: "novelarchive", seriesKey: "tbate", chapterKey: "ch-121" };

  it("points at the file endpoint", () => {
    expect(novelAudioUrl(ref)).toContain("/novels/audio/file?");
  });

  it("puts the identity in the query, never the path", () => {
    // Connector keys are opaque and routinely contain slashes; as a path
    // segment one would break the route and, worse, change which file it
    // addressed.
    const awkward = { sourceId: "s", seriesKey: "a/b?c", chapterKey: "d/e#f" };
    const url = novelAudioUrl(awkward);

    expect(url.split("?")[0]).toMatch(/\/novels\/audio\/file$/);
    expect(url).toContain("series=a%2Fb%3Fc");
    expect(url).toContain("chapter=d%2Fe%23f");
  });

  it("round-trips through URL parsing", () => {
    const awkward = { sourceId: "s", seriesKey: "a/b?c", chapterKey: "d/e#f" };
    const parsed = new URL(novelAudioUrl(awkward));

    expect(parsed.searchParams.get("series")).toBe("a/b?c");
    expect(parsed.searchParams.get("chapter")).toBe("d/e#f");
  });
});
