import { describe, expect, it } from "vitest";

import { novelAudioPath } from "./audio-url";

/**
 * The audio is fetched, not pointed at with `<audio src>`, because
 * `mm_session` is httpOnly and SameSite=lax and a browser-managed subresource
 * request to another origin never carries it. What is left to test here is
 * that the identity travels as a query, which is what keeps opaque connector
 * keys from breaking the route.
 */

describe("novelAudioPath", () => {
  const ref = { sourceId: "novelarchive", seriesKey: "tbate", chapterKey: "ch-121" };

  it("points at the file endpoint", () => {
    expect(novelAudioPath(ref).path).toBe("/novels/audio/file");
  });

  it("carries the identity triple", () => {
    expect(novelAudioPath(ref).query).toEqual({
      source: "novelarchive",
      series: "tbate",
      chapter: "ch-121",
    });
  });

  it("keeps an awkward key intact rather than in the path", () => {
    // Connector keys routinely contain slashes; as a path segment one would
    // break the route and, worse, change which file it addressed.
    const awkward = { sourceId: "s", seriesKey: "a/b?c", chapterKey: "d/e#f" };
    const { path, query } = novelAudioPath(awkward);

    expect(path).toBe("/novels/audio/file");
    expect(query.series).toBe("a/b?c");
    expect(query.chapter).toBe("d/e#f");
  });
});
