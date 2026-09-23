import { describe, expect, it } from "vitest";
import { markAllReadLabel, markAllReadRequest } from "./mark-all";

describe("markAllReadRequest", () => {
  it("clears only the mode the screen is showing", () => {
    expect(markAllReadRequest(true, "manga")).toEqual({ content_kind: "manga" });
    expect(markAllReadRequest(true, "novel")).toEqual({ content_kind: "novel" });
  });

  it("sends no filter when novels are off, so the request is unchanged", () => {
    expect(markAllReadRequest(false, "manga")).toBeUndefined();
  });
});

describe("markAllReadLabel", () => {
  it("names the mode it clears", () => {
    expect(markAllReadLabel(true, "manga")).toBe("Mark all manga read");
    expect(markAllReadLabel(true, "novel")).toBe("Mark all novels read");
  });

  it("keeps the plain label with a single mode", () => {
    expect(markAllReadLabel(false, "manga")).toBe("Mark all read");
  });
});
