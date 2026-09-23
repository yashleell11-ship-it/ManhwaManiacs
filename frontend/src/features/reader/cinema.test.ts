import { describe, expect, it } from "vitest";
import {
  cinemaExpectsIdle,
  cinemaReduce,
  cinemaTransition,
  INITIAL_CINEMA_STATE,
  type CinemaState,
} from "./cinema";

describe("cinemaReduce", () => {
  it("starts off with the chrome shown", () => {
    expect(INITIAL_CINEMA_STATE).toEqual({ enabled: false, chrome: "shown" });
  });

  it("engages with the chrome hidden (toggle or 3 s auto-engage)", () => {
    expect(cinemaReduce(INITIAL_CINEMA_STATE, { type: "enable" })).toEqual({
      enabled: true,
      chrome: "hidden",
    });
    expect(cinemaReduce(INITIAL_CINEMA_STATE, { type: "toggle" })).toEqual({
      enabled: true,
      chrome: "hidden",
    });
  });

  it("runs the active -> idle -> revealed -> idle cycle while engaged", () => {
    let state: CinemaState = cinemaReduce(INITIAL_CINEMA_STATE, { type: "enable" });
    expect(state.chrome).toBe("hidden");

    // Activity reveals the chrome...
    state = cinemaReduce(state, { type: "activity" });
    expect(state).toEqual({ enabled: true, chrome: "shown" });
    expect(cinemaExpectsIdle(state)).toBe(true);

    // ...and the idle timer hides it again.
    state = cinemaReduce(state, { type: "idle" });
    expect(state).toEqual({ enabled: true, chrome: "hidden" });
    expect(cinemaExpectsIdle(state)).toBe(false);

    // Revealed once more, then idle again — the loop is stable.
    state = cinemaReduce(state, { type: "activity" });
    expect(state.chrome).toBe("shown");
    state = cinemaReduce(state, { type: "idle" });
    expect(state.chrome).toBe("hidden");
  });

  it("ignores activity / idle while cinema mode is off", () => {
    expect(cinemaReduce(INITIAL_CINEMA_STATE, { type: "activity" })).toBe(
      INITIAL_CINEMA_STATE,
    );
    expect(cinemaReduce(INITIAL_CINEMA_STATE, { type: "idle" })).toBe(
      INITIAL_CINEMA_STATE,
    );
  });

  it("disable brings the chrome back and keeps it", () => {
    const engaged = cinemaReduce(INITIAL_CINEMA_STATE, { type: "enable" });
    const off = cinemaReduce(engaged, { type: "disable" });
    expect(off).toEqual({ enabled: false, chrome: "shown" });
    expect(cinemaReduce(off, { type: "idle" })).toBe(off);
  });

  it("returns the same reference when nothing changes (stable snapshots)", () => {
    const engagedShown = cinemaReduce(
      cinemaReduce(INITIAL_CINEMA_STATE, { type: "enable" }),
      { type: "activity" },
    );
    expect(cinemaReduce(engagedShown, { type: "activity" })).toBe(engagedShown);
  });

  it("conceals at once when reading moves on, without waiting for idle", () => {
    const revealed = cinemaReduce(
      cinemaReduce(INITIAL_CINEMA_STATE, { type: "enable" }),
      { type: "activity" },
    );
    const concealed = cinemaReduce(revealed, { type: "conceal" });
    expect(concealed).toEqual({ enabled: true, chrome: "hidden" });
    // Scrolling on keeps concealing a chrome that is already gone: same state.
    expect(cinemaReduce(concealed, { type: "conceal" })).toBe(concealed);
  });

  it("leaves conceal to the reader store while cinema mode is off", () => {
    expect(cinemaReduce(INITIAL_CINEMA_STATE, { type: "conceal" })).toBe(INITIAL_CINEMA_STATE);
  });
});

describe("cinemaTransition", () => {
  it("fades normally and swaps instantly under reduced motion", () => {
    expect(cinemaTransition(false)).toBe("fade");
    expect(cinemaTransition(true)).toBe("instant");
  });
});
