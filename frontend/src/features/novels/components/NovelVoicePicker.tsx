"use client";

/**
 * Choose the voice that reads a character, by listening to it.
 *
 * The automatic assignment is a starting position, not a verdict: it matches
 * gender and hands out whatever is left in speaking order, which is a
 * reasonable way to fill thirty slots and a poor way to cast a protagonist you
 * are about to spend four hundred chapters with.
 *
 * Every voice introduces itself, rendered through the same model that will
 * read the book. That matters more than it sounds: a preview cut from the
 * reference clip would demonstrate a stranger reading a sentence from a
 * nineteenth-century novel, whereas this is the voice saying its own name on
 * the same inference path the chapters take. A preview cannot flatter a voice
 * the renderer will not reproduce.
 *
 * One clip plays at a time, deliberately. Auditioning voices means comparing
 * them, and two talking at once compares nothing.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { novelsApi } from "../api";
import { automaticVoiceOption } from "../cast-labels";
import { createLatestLoad, keepLoadedUrl } from "../latest-load";
import type { NovelVoicePayload } from "../types";

type Surface = { bg: string; ink: string; muted: string; rule: string };

export function NovelVoicePicker({
  voices,
  selected,
  label,
  surface,
  onChoose,
  onClose,
  busy,
  forNarration = false,
}: {
  voices: readonly NovelVoicePayload[];
  /** The voice currently pinned, or null for an automatic one. */
  selected: string | null;
  /** Who is being cast — a character's name, or the narrator. */
  label: string;
  surface: Surface;
  onChoose: (voiceId: string | null) => void;
  onClose: () => void;
  busy: boolean;
  /** Casting the narration rather than a character: changes what "automatic" means. */
  forNarration?: boolean;
}) {
  const [playing, setPlaying] = useState<string | null>(null);
  const [failed, setFailed] = useState<string | null>(null);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const urlRef = useRef<string | null>(null);
  // The clip being fetched. Stopping has to reach it too, not just the clip
  // already playing: otherwise pressing two names in quick succession plays
  // both at once, and a clip pressed just before "Done" plays after the
  // picker has gone, with nothing left on screen to stop it.
  const [loads] = useState(createLatestLoad);

  const stop = useCallback(() => {
    loads.cancel();
    audioRef.current?.pause();
    audioRef.current = null;
    if (urlRef.current) {
      // A leaked object URL pins the whole clip in memory for the life of the
      // tab, and auditioning thirty voices would pin all thirty.
      URL.revokeObjectURL(urlRef.current);
      urlRef.current = null;
    }
    setPlaying(null);
  }, [loads]);

  useEffect(() => stop, [stop]);

  const preview = useCallback(
    async (voiceId: string) => {
      if (playing === voiceId) {
        stop();
        return;
      }
      stop();
      setFailed(null);
      setPlaying(voiceId);
      const signal = loads.begin();
      try {
        const url = await novelsApi.voiceSampleObjectUrl(voiceId, { signal });
        // Another name was pressed, or the picker closed, while this clip
        // was on its way.
        if (!keepLoadedUrl(signal, url)) return;
        urlRef.current = url;
        const audio = new Audio(url);
        audioRef.current = audio;
        // Bound to THIS clip: one that has been replaced must not stop its
        // successor, and cut it off mid-sentence, when it finishes.
        audio.addEventListener(
          "ended",
          () => {
            if (!signal.aborted) stop();
          },
          { once: true },
        );
        await audio.play();
      } catch {
        // Abandoned on purpose — a newer press owns the row state now.
        if (signal.aborted) return;
        // A voice with no clip on disk is still a voice that renders; it just
        // cannot be auditioned. Say so on the row rather than blocking the
        // choice.
        setFailed(voiceId);
        setPlaying(null);
      }
    },
    [playing, stop, loads],
  );

  const automatic = automaticVoiceOption(forNarration);

  const grouped: Array<[string, NovelVoicePayload[]]> = [
    ["Male", voices.filter((v) => v.gender === "male")],
    ["Female", voices.filter((v) => v.gender === "female")],
  ];

  return (
    <div
      className="mt-2 rounded-md border px-3 py-2.5"
      style={{ borderColor: surface.rule }}
    >
      <div className="flex items-baseline justify-between gap-3">
        <h3
          className="text-[11px] font-semibold uppercase tracking-[0.1em]"
          style={{ color: surface.muted }}
        >
          A voice for {label}
        </h3>
        <button
          type="button"
          onClick={() => {
            stop();
            onClose();
          }}
          className="text-xs underline-offset-2 hover:underline"
          style={{ color: surface.muted }}
        >
          Done
        </button>
      </div>

      <p className="mt-1.5 text-[11px]" style={{ color: surface.muted }}>
        Press a name to hear it introduce itself. Chapters already rendered keep
        the voice they were made with until they are rendered again.
      </p>

      <ul className="mt-2 flex flex-col gap-0.5">
        <li>
          <VoiceRow
            title={automatic.title}
            detail={automatic.detail}
            chosen={selected === null}
            surface={surface}
            busy={busy}
            onChoose={() => {
              stop();
              onChoose(null);
            }}
          />
        </li>
      </ul>

      {grouped.map(([heading, list]) =>
        list.length === 0 ? null : (
          <div key={heading} className="mt-2.5">
            <p
              className="text-[10px] font-semibold uppercase tracking-[0.1em]"
              style={{ color: surface.muted }}
            >
              {heading}
            </p>
            <ul className="mt-1 flex flex-col gap-0.5">
              {list.map((voice) => (
                <li key={voice.voice_id}>
                  <VoiceRow
                    title={voice.name}
                    detail={
                      failed === voice.voice_id
                        ? "No preview available"
                        : `${voice.character} · ${Math.round(voice.pitch_hz)} Hz`
                    }
                    chosen={selected === voice.voice_id}
                    playing={playing === voice.voice_id}
                    surface={surface}
                    busy={busy}
                    onPreview={() => void preview(voice.voice_id)}
                    onChoose={() => {
                      stop();
                      onChoose(voice.voice_id);
                    }}
                  />
                </li>
              ))}
            </ul>
          </div>
        ),
      )}
    </div>
  );
}

function VoiceRow({
  title,
  detail,
  chosen,
  playing,
  surface,
  busy,
  onPreview,
  onChoose,
}: {
  title: string;
  detail: string;
  chosen: boolean;
  playing?: boolean;
  surface: Surface;
  busy: boolean;
  onPreview?: () => void;
  onChoose: () => void;
}) {
  return (
    <div
      className="grid grid-cols-[1fr_auto] items-center gap-2 rounded px-1.5 py-1"
      style={chosen ? { backgroundColor: `${surface.ink}14` } : undefined}
    >
      <button
        type="button"
        onClick={onPreview ?? onChoose}
        className="flex flex-col items-start text-left"
      >
        <span className="text-sm" style={{ color: surface.ink }}>
          {playing ? "❚❚ " : onPreview ? "▸ " : ""}
          {title}
        </span>
        <span className="text-[11px]" style={{ color: surface.muted }}>
          {detail}
        </span>
      </button>
      <button
        type="button"
        onClick={onChoose}
        disabled={busy || chosen}
        className="rounded border px-2 py-0.5 text-[11px] disabled:opacity-45"
        style={{ borderColor: surface.rule, color: surface.ink }}
      >
        {chosen ? "Chosen" : "Use"}
      </button>
    </div>
  );
}
