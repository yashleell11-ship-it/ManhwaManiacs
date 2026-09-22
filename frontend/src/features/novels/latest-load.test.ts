import { describe, expect, it } from "vitest";

import { createLatestLoad, isPlaybackFailure, keepLoadedUrl } from "./latest-load";

describe("createLatestLoad", () => {
  it("abandons the load in flight when a new one begins", () => {
    // Pressing voice A and then voice B before A's clip arrives: A must not
    // play over B when it lands.
    const loads = createLatestLoad();
    const first = loads.begin();
    const second = loads.begin();

    expect(first.aborted).toBe(true);
    expect(second.aborted).toBe(false);
  });

  it("abandons the load in flight on cancel", () => {
    // Leaving the chapter, or closing the picker, while the file downloads.
    const loads = createLatestLoad();
    const signal = loads.begin();
    loads.cancel();

    expect(signal.aborted).toBe(true);
  });

  it("does nothing when cancelled with nothing in flight", () => {
    const loads = createLatestLoad();
    expect(() => loads.cancel()).not.toThrow();
    expect(loads.begin().aborted).toBe(false);
  });
});

describe("keepLoadedUrl", () => {
  it("keeps a URL whose load is still wanted, and revokes nothing", () => {
    const revoked: string[] = [];
    const loads = createLatestLoad();
    const signal = loads.begin();

    expect(keepLoadedUrl(signal, "blob:chapter", (u) => revoked.push(u))).toBe(true);
    expect(revoked).toEqual([]);
  });

  it("refuses and revokes a URL that arrived after the reader left", () => {
    // The unmount cleanup ran before this URL existed, so if it is not
    // revoked here it never is.
    const revoked: string[] = [];
    const loads = createLatestLoad();
    const signal = loads.begin();
    loads.cancel();

    expect(keepLoadedUrl(signal, "blob:chapter", (u) => revoked.push(u))).toBe(false);
    expect(revoked).toEqual(["blob:chapter"]);
  });

  it("plays only the last of two quick previews", async () => {
    // The picker's race, end to end: two presses, the FIRST clip arriving
    // last. Only B may start, and A's URL must not leak.
    const loads = createLatestLoad();
    const revoked: string[] = [];
    const played: string[] = [];

    const press = async (voice: string, arrives: Promise<void>) => {
      const signal = loads.begin();
      await arrives;
      const url = `blob:${voice}`;
      if (!keepLoadedUrl(signal, url, (u) => revoked.push(u))) return;
      played.push(url);
    };

    let releaseA!: () => void;
    const a = press("a", new Promise<void>((resolve) => (releaseA = resolve)));
    const b = press("b", Promise.resolve());
    await b;
    releaseA();
    await a;

    expect(played).toEqual(["blob:b"]);
    expect(revoked).toEqual(["blob:a"]);
  });

  it("lets only the current clip's end stop playback", () => {
    // The picker binds `ended` to each clip's own signal. A replaced clip
    // finishing must not stop the one that replaced it mid-sentence.
    const loads = createLatestLoad();
    const stops: string[] = [];
    const endedFor = (voice: string, signal: AbortSignal) => () => {
      if (!signal.aborted) stops.push(voice);
    };

    const endedA = endedFor("a", loads.begin());
    const endedB = endedFor("b", loads.begin());
    endedA();
    expect(stops).toEqual([]);
    endedB();
    expect(stops).toEqual(["b"]);
  });
});

describe("isPlaybackFailure", () => {
  it("ignores play() being interrupted by a pause", () => {
    expect(isPlaybackFailure(new DOMException("interrupted", "AbortError"))).toBe(false);
  });

  it("reports a refusal or an undecodable file", () => {
    expect(isPlaybackFailure(new DOMException("blocked", "NotAllowedError"))).toBe(true);
    expect(isPlaybackFailure(new DOMException("bad file", "NotSupportedError"))).toBe(true);
    expect(isPlaybackFailure(new Error("anything else"))).toBe(true);
    expect(isPlaybackFailure(undefined)).toBe(true);
  });
});
