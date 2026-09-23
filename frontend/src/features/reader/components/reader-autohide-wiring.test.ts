import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

// The vitest environment is node, so these pin the two pieces of wiring that
// keep the reader's controls from staying up while the owner reads.
const read = (file: string) => readFileSync(join(__dirname, file), "utf8");

describe("reader chrome auto-hide wiring", () => {
  it("blurs the page box after a jump, so a focused text box does not hold the bar", () => {
    const source = read("ScrubBar.tsx");
    const submit = source.slice(source.indexOf("const submitJump"), source.indexOf("return ("));
    expect(submit).toMatch(/onSeek\(target\);[\s\S]*jumpInputRef\.current\?\.blur\(\)/);
    expect(source).toMatch(/ref=\{jumpInputRef\}/);
  });

  it("marks a keyboard chapter jump as reading, like a page turn", () => {
    const source = read("ChapterReader.tsx");
    expect(source).toMatch(/onPreviousChapter: \(\) => \{\s*intendScroll\(\);\s*goPreviousChapter\(\);/);
    expect(source).toMatch(/onNextChapter: \(\) => \{\s*intendScroll\(\);\s*goNextChapter\(\);/);
  });
});
