"use client";

/**
 * Who speaks in this chapter, and in whose voice.
 *
 * Painted in the reader's own palette rather than the app's chrome, for the
 * same reason the type panel is: a settings sheet in the site theme dropped
 * onto a Paper page is a hole punched in the book.
 *
 * Deliberately small. This is not a character sheet and must never become one
 * — `frontend/AGENTS.md` records that character/world/timeline extraction was
 * permanently abandoned. It shows exactly what decides how a line SOUNDS: the
 * name, the colour it is tinted in, and how much it speaks. A description, a
 * relationship, a first appearance, would all be the abandoned thing wearing a
 * different hat.
 */

import { useState } from "react";
import { NovelVoicePicker } from "./NovelVoicePicker";
import type { NovelVoicePayload } from "../types";

export type CastMember = {
  name: string;
  gender: string;
  voice_id: string | null;
};

/** The narrator is cast from the same roster, under its own key. */
const NARRATOR = "\u0000narrator";

export function NovelCastPanel({
  cast,
  hues,
  lineCounts,
  narrator,
  surface,
  onClose,
  voices,
  narratorVoiceId,
  onChooseVoice,
  saving,
}: {
  cast: readonly CastMember[];
  hues: ReadonlyMap<string, number>;
  /** Spans attributed to each name in this chapter. */
  lineCounts: ReadonlyMap<string, number>;
  /** Who narrates this chapter, when it is known. */
  narrator: string | null;
  surface: { bg: string; ink: string; muted: string; rule: string };
  onClose: () => void;
  /** Every voice on offer. Empty when no pack is installed. */
  voices?: readonly NovelVoicePayload[];
  /** The series' narration voice, when one has been pinned. */
  narratorVoiceId?: string | null;
  /** `null` as the name means the narrator. Absent = read-only panel. */
  onChooseVoice?: (name: string | null, voiceId: string | null) => void;
  saving?: boolean;
}) {
  // Which row has its picker open. One at a time: this panel sits inside the
  // page, and thirty voices under every character is a wall.
  const [open, setOpen] = useState<string | null>(null);
  const canCast = Boolean(onChooseVoice && voices && voices.length > 0);
  const voiceName = (id: string | null) =>
    voices?.find((v) => v.voice_id === id)?.name ?? null;

  return (
    <div
      className="mx-auto mt-3 max-w-2xl rounded-lg border px-4 py-3"
      style={{ borderColor: surface.rule, backgroundColor: surface.bg }}
    >
      <div className="flex items-baseline justify-between gap-3">
        <h2
          className="text-[11px] font-semibold uppercase tracking-[0.1em]"
          style={{ color: surface.muted }}
        >
          Voices in this chapter
        </h2>
        <button
          type="button"
          onClick={onClose}
          className="text-xs underline-offset-2 hover:underline"
          style={{ color: surface.muted }}
        >
          Close
        </button>
      </div>

      {narrator ? (
        <p className="mt-2 text-xs" style={{ color: surface.muted }}>
          Narrated by <span style={{ color: surface.ink }}>{narrator}</span> — their
          own lines are read in the narrator&rsquo;s voice, because they are the
          same person.
        </p>
      ) : null}

      {canCast ? (
        <div className="mt-2">
          <button
            type="button"
            onClick={() => setOpen(open === NARRATOR ? null : NARRATOR)}
            className="text-xs underline-offset-2 hover:underline"
            style={{ color: surface.muted }}
          >
            Narration is read by{" "}
            <span style={{ color: surface.ink }}>
              {voiceName(narratorVoiceId ?? null) ?? "the default voice"}
            </span>
            {open === NARRATOR ? "" : " — change"}
          </button>
          {open === NARRATOR ? (
            <NovelVoicePicker
              voices={voices ?? []}
              selected={narratorVoiceId ?? null}
              label="the narration"
              surface={surface}
              busy={Boolean(saving)}
              onChoose={(voiceId) => onChooseVoice?.(null, voiceId)}
              onClose={() => setOpen(null)}
            />
          ) : null}
        </div>
      ) : null}

      {cast.length === 0 ? (
        <p className="mt-2 text-xs" style={{ color: surface.muted }}>
          Nobody else was identified with enough confidence to be given a voice,
          so this chapter is read by the narrator throughout.
        </p>
      ) : (
        <ul className="mt-3 flex flex-col gap-1">
          {cast.map((member) => {
            const hue = hues.get(member.name);
            const lines = lineCounts.get(member.name) ?? 0;
            return (
              <li
                key={member.name}
                className="grid grid-cols-[10px_1fr_auto] items-baseline gap-2.5 text-sm"
              >
                <span
                  aria-hidden
                  className="h-2.5 w-2.5 self-center rounded-[2px]"
                  style={
                    hue === undefined
                      ? { border: `1px dashed ${surface.muted}` }
                      : {
                          backgroundColor: `hsl(${hue} 70% 50% / 0.35)`,
                          boxShadow: `inset 0 0 0 1px hsl(${hue} 60% 45% / 0.7)`,
                        }
                  }
                />
                <span style={{ color: surface.ink }}>{member.name}</span>
                {canCast ? (
                  <button
                    type="button"
                    onClick={() =>
                      setOpen(open === member.name ? null : member.name)
                    }
                    className="font-mono text-[11px] tabular-nums underline-offset-2 hover:underline"
                    style={{ color: surface.muted }}
                  >
                    {voiceName(member.voice_id) ?? "narrator"} · {lines}
                  </button>
                ) : (
                  <span
                    className="font-mono text-[11px] tabular-nums"
                    style={{ color: surface.muted }}
                  >
                    {lines} {lines === 1 ? "line" : "lines"}
                    {member.voice_id ? "" : " · narrator"}
                  </span>
                )}
                {open === member.name ? (
                  <div className="col-span-3">
                    <NovelVoicePicker
                      voices={voices ?? []}
                      selected={member.voice_id}
                      label={member.name}
                      surface={surface}
                      busy={Boolean(saving)}
                      onChoose={(voiceId) =>
                        onChooseVoice?.(member.name, voiceId)
                      }
                      onClose={() => setOpen(null)}
                    />
                  </div>
                ) : null}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
