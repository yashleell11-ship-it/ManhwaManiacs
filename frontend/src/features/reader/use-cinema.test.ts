import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { createCinemaMachine } from "./use-cinema";

/**
 * Cinema mode listens to `pointermove`, `keydown` and the strip's `scroll`,
 * each of which fires about once a frame. Almost none of those events change
 * anything: the chrome is already up, or cinema mode is off. React 19's
 * `useReducer` dispatch has no early bail-out, so every one of them used to
 * schedule a render of the whole reader just for the reducer to hand back the
 * same state. The machine below is what the hook renders from, and it only
 * tells React when the state really moved.
 */
describe("createCinemaMachine", () => {
  it("starts off with the chrome shown", () => {
    expect(createCinemaMachine().get()).toEqual({ enabled: false, chrome: "shown" });
  });

  it("is silent about activity while cinema mode is off", () => {
    const machine = createCinemaMachine();
    const listener = vi.fn();
    machine.subscribe(listener);

    for (let frame = 0; frame < 60; frame += 1) machine.send({ type: "activity" });
    machine.send({ type: "idle" });

    expect(listener).not.toHaveBeenCalled();
  });

  it("wakes React once when activity reveals the chrome, not once per event", () => {
    const machine = createCinemaMachine();
    machine.send({ type: "enable" });
    const listener = vi.fn();
    machine.subscribe(listener);

    // A second of pointer movement over a hidden chrome: one reveal.
    for (let frame = 0; frame < 60; frame += 1) machine.send({ type: "activity" });

    expect(listener).toHaveBeenCalledTimes(1);
    expect(machine.get()).toEqual({ enabled: true, chrome: "shown" });
  });

  it("hides once on idle and ignores a repeated idle", () => {
    const machine = createCinemaMachine();
    machine.send({ type: "enable" });
    machine.send({ type: "activity" });
    const listener = vi.fn();
    machine.subscribe(listener);

    machine.send({ type: "idle" });
    machine.send({ type: "idle" });

    expect(listener).toHaveBeenCalledTimes(1);
    expect(machine.get().chrome).toBe("hidden");
  });

  it("keeps the same snapshot while nothing changes, as useSyncExternalStore requires", () => {
    const machine = createCinemaMachine();
    machine.send({ type: "enable" });
    machine.send({ type: "activity" });
    const shown = machine.get();

    machine.send({ type: "activity" });

    expect(machine.get()).toBe(shown);
  });

  it("notifies every toggle, and stops notifying after unsubscribe", () => {
    const machine = createCinemaMachine();
    const listener = vi.fn();
    const unsubscribe = machine.subscribe(listener);

    machine.send({ type: "toggle" });
    machine.send({ type: "toggle" });
    expect(listener).toHaveBeenCalledTimes(2);
    expect(machine.get()).toEqual({ enabled: false, chrome: "shown" });

    unsubscribe();
    machine.send({ type: "toggle" });
    expect(listener).toHaveBeenCalledTimes(2);
  });
});

describe("useCinema", () => {
  // Code only: the doc comments explain why the reducer went, by name.
  const source = readFileSync(new URL("./use-cinema.ts", import.meta.url), "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\/\/.*$/gm, "");

  it("renders from the machine rather than a reducer that re-renders on every event", () => {
    expect(source).not.toMatch(/\buseReducer\b/);
    expect(source).toMatch(/useSyncExternalStore\(\s*machine\.subscribe/);
  });
});
