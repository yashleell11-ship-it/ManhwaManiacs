import { describe, expect, it } from "vitest";
import { decideWorkerUpdate } from "./worker-update";

describe("decideWorkerUpdate", () => {
  it("asks a worker that is still waiting to take over", () => {
    expect(decideWorkerUpdate("installed", false)).toBe("skip-waiting");
  });

  it("reloads at once when another tab already activated the update", () => {
    // The controllerchange this tab would have waited for has already fired.
    expect(decideWorkerUpdate("activated", true)).toBe("reload");
    expect(decideWorkerUpdate("activated", false)).toBe("reload");
  });

  it("reloads once the new worker has claimed this tab, even mid-activation", () => {
    // clients.claim() runs inside the activate handler, before "activated".
    expect(decideWorkerUpdate("activating", true)).toBe("reload");
  });

  it("waits for the takeover while activation has not yet claimed this tab", () => {
    expect(decideWorkerUpdate("activating", false)).toBe("skip-waiting");
  });

  it("does nothing with a worker a newer build replaced", () => {
    expect(decideWorkerUpdate("redundant", false)).toBe("stale");
  });
});
