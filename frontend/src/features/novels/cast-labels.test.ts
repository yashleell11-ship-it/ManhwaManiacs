import { describe, expect, it } from "vitest";

import { ApiError } from "@/types/api";
import {
  AUTOMATIC,
  AUTOMATIC_VOICE,
  automaticVoiceOption,
  castVoiceLabel,
  voiceChangeError,
} from "./cast-labels";
import type { NovelVoicePayload } from "./types";

const voice = (voice_id: string, name: string): NovelVoicePayload => ({
  voice_id,
  name,
  character: "deep, steady",
  gender: "male",
  pitch_hz: 110,
  expressiveness: 0.5,
  seconds: 12,
  license: "CC-BY-4.0",
  attribution: "LibriTTS",
  transcript: "Hello, I'm Rowan.",
});

const roster = [voice("libritts-2803", "Rowan"), voice("libritts-1088", "Mira")];

describe("castVoiceLabel", () => {
  it("names a pinned voice", () => {
    expect(castVoiceLabel("libritts-2803", roster)).toBe("Rowan");
  });

  it("calls an unpinned character automatic, never narrator", () => {
    // The render plan gives every unpinned character an assigned voice of
    // their own; "narrator" told the reader something the audio did not do.
    expect(castVoiceLabel(null, roster)).toBe(AUTOMATIC);
    expect(AUTOMATIC).toBe("Automatic");
    expect(castVoiceLabel(null, roster)).not.toMatch(/narrator/i);
  });

  it("shows a pin the roster no longer lists by its id", () => {
    // The pin still applies at render time, so it is not automatic.
    expect(castVoiceLabel("libritts-9999", roster)).toBe("libritts-9999");
  });
});

describe("automaticVoiceOption", () => {
  it("offers clearing a character's pin as the automatic voice", () => {
    const option = automaticVoiceOption(false);
    expect(option.title).toBe(AUTOMATIC_VOICE);
    expect(option.title).toBe("Automatic voice");
    expect(option.title).not.toMatch(/narrator/i);
    expect(option.detail).toBe("Assigned automatically, not pinned");
  });

  it("offers clearing the narration pin as the book's default", () => {
    const option = automaticVoiceOption(true);
    expect(option.title).toBe("Automatic voice");
    expect(option.detail).toBe("The book's default narration voice");
  });
});

describe("voiceChangeError", () => {
  it("says nothing when nothing failed", () => {
    expect(voiceChangeError(null)).toBeNull();
    expect(voiceChangeError(undefined)).toBeNull();
  });

  it("shows the server's reason when a non-admin is refused", () => {
    const refused = new ApiError(403, {
      code: "forbidden",
      message: "Administrator access required.",
    });
    expect(voiceChangeError(refused)).toBe("Administrator access required.");
  });

  it("falls back to a plain line for a failure with no server message", () => {
    expect(voiceChangeError(new Error("boom"))).toBe(
      "The voice could not be changed. Try again.",
    );
  });
});
