import { describe, expect, it } from "vitest";
import {
  followedCardSubtitle,
  followedShelfNote,
  newCountLabel,
  readStateLabel,
  readStateNewCount,
  readStateNote,
  seriesCardMeta,
} from "./read-state";
import type { ReadState } from "./types";

const NOT_STARTED: ReadState = {
  started: false,
  chapter_key: null,
  chapter_number: null,
  position: null,
  total: 120,
  latest_number: null,
  new_count: null,
};

function started(overrides: Partial<ReadState> = {}): ReadState {
  return {
    started: true,
    chapter_key: "c5",
    chapter_number: 5,
    position: 5,
    total: 120,
    latest_number: 120,
    new_count: 115,
    ...overrides,
  };
}

describe("readStateLabel", () => {
  it("says a never-opened series is not started", () => {
    expect(readStateLabel(NOT_STARTED)).toBe("Not started");
  });

  it("uses printed numbers when both ends have one", () => {
    // A prologue puts the list one ahead of the printed numbers.
    expect(
      readStateLabel(started({ chapter_number: 4, position: 5, total: 121, latest_number: 120 })),
    ).toBe("Ch 4 of 120");
    expect(readStateLabel(started({ chapter_number: 12.5, latest_number: 30 }))).toBe(
      "Ch 12.5 of 30",
    );
  });

  it("falls back to list position when either end is unnumbered", () => {
    expect(readStateLabel(started({ chapter_number: null }))).toBe("Ch 5 of 120");
    expect(readStateLabel(started({ latest_number: null }))).toBe("Ch 5 of 120");
  });

  it("never prints a chapter past the last one", () => {
    expect(readStateLabel(started({ chapter_number: 12, latest_number: 10, total: 14 }))).toBe(
      "Ch 5 of 14",
    );
  });

  it("names the chapter alone when the list no longer carries it", () => {
    expect(readStateLabel(started({ position: null, chapter_number: 7, new_count: null }))).toBe(
      "Ch 7",
    );
    expect(
      readStateLabel(started({ position: null, chapter_number: null, new_count: null })),
    ).toBe("Started");
  });

  it("says nothing without a read state, so the caller keeps its old line", () => {
    expect(readStateLabel(undefined)).toBeNull();
  });
});

describe("readStateNewCount / newCountLabel", () => {
  it("counts chapters past the furthest one opened", () => {
    expect(readStateNewCount(started({ new_count: 2 }))).toBe(2);
    expect(newCountLabel(2)).toBe("2 new");
  });

  it("is zero for a series never started", () => {
    expect(readStateNewCount({ ...NOT_STARTED, new_count: 120 })).toBe(0);
    expect(readStateNewCount(undefined)).toBe(0);
  });

  it("is zero when the position is unknown", () => {
    expect(readStateNewCount(started({ position: null, new_count: null }))).toBe(0);
  });

  it("caps the pill and hides it at zero", () => {
    expect(newCountLabel(3183)).toBe("99+ new");
    expect(newCountLabel(99)).toBe("99 new");
    expect(newCountLabel(0)).toBeNull();
  });
});

describe("readStateNote", () => {
  it("joins where the reader is with what is waiting", () => {
    expect(readStateNote(started({ new_count: 2, chapter_number: 118, latest_number: 120 }))).toBe(
      "Ch 118 of 120 · 2 new",
    );
  });

  it("leaves the new part out when caught up or not started", () => {
    expect(
      readStateNote(started({ new_count: 0, chapter_number: 120, position: 120 })),
    ).toBe("Ch 120 of 120");
    expect(readStateNote(NOT_STARTED)).toBe("Not started");
  });
});

describe("followedShelfNote", () => {
  it("says where the reader is instead of the follow's default 'Reading'", () => {
    expect(followedShelfNote({ reading_status: "reading", read_state: NOT_STARTED })).toBe(
      "Not started",
    );
    expect(
      followedShelfNote({ reading_status: "reading", read_state: started({ new_count: 3 }) }),
    ).toBe("Ch 5 of 120 · 3 new");
  });

  it("keeps the reading-status word for a row with no read state", () => {
    expect(followedShelfNote({ reading_status: "reading" })).toBe("Reading");
    expect(followedShelfNote({ reading_status: "" })).toBeNull();
  });
});

describe("seriesCardMeta", () => {
  it("puts where the reader is in place of the bare chapter count", () => {
    expect(seriesCardMeta({ chapter_count: 120, read_state: NOT_STARTED })).toBe("Not started");
    expect(seriesCardMeta({ chapter_count: 120, read_state: started({ new_count: 1 }) })).toBe(
      "Ch 5 of 120 · 1 new",
    );
  });

  it("keeps the chapter count for a row with no read state", () => {
    expect(seriesCardMeta({ chapter_count: 0 })).toBe("0 chapters");
  });
});

describe("followedCardSubtitle", () => {
  it("replaces the chapter count with where the reader is", () => {
    expect(followedCardSubtitle({ chapter_count: 120, read_state: NOT_STARTED })).toBe(
      "Not started",
    );
    expect(followedCardSubtitle({ chapter_count: 120, read_state: started() })).toBe(
      "Ch 5 of 120",
    );
  });

  it("keeps the old count line for a row with no read state", () => {
    expect(followedCardSubtitle({ chapter_count: 1 })).toBe("1 chapter");
    expect(followedCardSubtitle({ chapter_count: 40 })).toBe("40 chapters");
    expect(followedCardSubtitle({ chapter_count: 0 })).toBeNull();
  });
});
