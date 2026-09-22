import { describe, expect, it } from "vitest";

import { novelAudioPath, OGG_OPUS_MIME, pickNovelAudioFormat } from "./audio-url";

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
    expect(novelAudioPath(ref, "ogg").path).toBe("/novels/audio/file");
  });

  it("carries the identity triple and the format asked for", () => {
    expect(novelAudioPath(ref, "ogg").query).toEqual({
      source: "novelarchive",
      series: "tbate",
      chapter: "ch-121",
      format: "ogg",
    });
    expect(novelAudioPath(ref, "m4a").query).toEqual({
      source: "novelarchive",
      series: "tbate",
      chapter: "ch-121",
      format: "m4a",
    });
  });

  it("keeps an awkward key intact rather than in the path", () => {
    // Connector keys routinely contain slashes; as a path segment one would
    // break the route and, worse, change which file it addressed.
    const awkward = { sourceId: "s", seriesKey: "a/b?c", chapterKey: "d/e#f" };
    const { path, query } = novelAudioPath(awkward, "ogg");

    expect(path).toBe("/novels/audio/file");
    expect(query.series).toBe("a/b?c");
    expect(query.chapter).toBe("d/e#f");
  });
});

/**
 * Safari on iPhone cannot read the Ogg container at all, so every narrated
 * chapter was a player that never started there. The browser is asked about
 * the stored file, and only a flat "no" gets the transcoded m4a.
 */
describe("pickNovelAudioFormat", () => {
  it("asks about Ogg Opus specifically, not Ogg in general", () => {
    // Some browsers read Ogg Vorbis but not Opus inside it; asking about bare
    // "audio/ogg" would get a yes for a file they cannot decode.
    expect(OGG_OPUS_MIME).toBe("audio/ogg; codecs=opus");
  });

  it("asks for m4a when the browser says it cannot play Ogg Opus", () => {
    expect(pickNovelAudioFormat("")).toBe("m4a");
  });

  it("keeps the stored Ogg when the browser can play it", () => {
    expect(pickNovelAudioFormat("probably")).toBe("ogg");
  });

  it("treats 'maybe' as a yes", () => {
    // "maybe" is the spec's usual answer for a type the browser does handle;
    // only the empty string means no.
    expect(pickNovelAudioFormat("maybe")).toBe("ogg");
  });
});
