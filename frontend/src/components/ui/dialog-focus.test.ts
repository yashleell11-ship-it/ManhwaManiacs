import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { openDialogFocus, tabTrapTarget, type Focusable } from "./dialog-focus";

interface El extends Focusable {
  name: string;
}

/** Stand-in elements that record focus into a shared "document". */
function makeDoc() {
  const doc = { active: null as El | null };
  const element = (name: string): El => ({
    name,
    focus() {
      doc.active = this;
    },
  });
  return { doc, element };
}

function harness(initial: string[]) {
  const { doc, element } = makeDoc();
  const trigger = element("trigger");
  trigger.focus();
  let panel = initial.map((name) => element(name));
  const frames: Array<() => void> = [];
  const cancelled = new Set<number>();
  const onEscape = vi.fn();
  const focus = openDialogFocus({
    previous: doc.active,
    focusables: () => panel,
    active: () => doc.active,
    onEscape: () => onEscape(),
    schedule: (run) => frames.push(run) - 1,
    cancel: (handle) => cancelled.add(handle),
  });
  const runFrames = () =>
    frames.forEach((run, handle) => {
      if (!cancelled.has(handle)) run();
    });
  const key = (key: string, shiftKey = false) => {
    const preventDefault = vi.fn();
    focus.onKeyDown({ key, shiftKey, preventDefault });
    return preventDefault;
  };
  return {
    doc,
    trigger,
    focus,
    runFrames,
    key,
    onEscape,
    setPanel: (names: string[]) => {
      panel = names.map((name) => element(name));
      return panel;
    },
    panel: () => panel,
  };
}

describe("openDialogFocus", () => {
  it("moves focus into the dialog once, on the frame after it opens", () => {
    const h = harness(["close", "name", "save"]);
    expect(h.doc.active?.name).toBe("trigger");
    h.runFrames();
    expect(h.doc.active?.name).toBe("close");
  });

  it("leaves focus where the user put it: typing is never interrupted", () => {
    const h = harness(["close", "name", "save"]);
    h.runFrames();
    h.panel()[1].focus();
    // Keystrokes, and the parent re-renders they cause, are just keys here:
    // nothing but Tab and Escape moves focus.
    for (const k of ["M", "y", " ", "l"]) h.key(k);
    expect(h.doc.active?.name).toBe("name");
    expect(h.onEscape).not.toHaveBeenCalled();
  });

  it("closes on Escape through the handler it is given", () => {
    const h = harness(["close"]);
    h.key("Escape");
    expect(h.onEscape).toHaveBeenCalledTimes(1);
  });

  it("wraps Tab against the elements present NOW, not the ones at open", () => {
    const h = harness(["close", "search"]);
    h.runFrames();
    const [, , lastResult] = h.setPanel(["close", "search", "result-3"]);
    lastResult.focus();
    const prevented = h.key("Tab");
    expect(prevented).toHaveBeenCalled();
    expect(h.doc.active?.name).toBe("close");

    h.key("Tab", true);
    expect(h.doc.active?.name).toBe("result-3");
  });

  it("lets the browser move Tab between inner elements", () => {
    const h = harness(["close", "name", "save"]);
    h.runFrames();
    h.panel()[1].focus();
    expect(h.key("Tab")).not.toHaveBeenCalled();
  });

  it("returns focus to the trigger on release", () => {
    const h = harness(["close", "name"]);
    h.runFrames();
    h.focus.release();
    expect(h.doc.active?.name).toBe("trigger");
  });

  it("a dialog closed before its first frame never takes focus afterwards", () => {
    const h = harness(["close"]);
    h.focus.release();
    h.runFrames();
    expect(h.doc.active?.name).toBe("trigger");
  });
});

describe("tabTrapTarget", () => {
  it("has nothing to do in an empty panel", () => {
    expect(tabTrapTarget([], null, false)).toBeNull();
  });

  it("wraps at both ends", () => {
    expect(tabTrapTarget(["a", "b", "c"], "c", false)).toBe("a");
    expect(tabTrapTarget(["a", "b", "c"], "a", true)).toBe("c");
    expect(tabTrapTarget(["a", "b", "c"], "b", false)).toBeNull();
  });
});

describe("Dialog wiring", () => {
  // The whole bug was the effect's dependency list: keyed on the inline
  // `onClose` every caller passes, it re-ran — and moved focus — on every
  // parent render. It must run once per open.
  const source = readFileSync(join(process.cwd(), "src/components/ui/dialog.tsx"), "utf8");

  it("runs the focus handling once per open, not per render", () => {
    expect(source).toContain("openDialogFocus(");
    expect(source).toMatch(/\}, \[open\]\);/);
    expect(source).not.toMatch(/\[open, onClose\]/);
  });

  it("reads the latest onClose through a ref for Escape", () => {
    expect(source).toContain("onEscape: () => onCloseRef.current()");
  });
});
