"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import { novelAudioUrl } from "@/features/novels/audio-url";
import type { ChapterId } from "@/types/api";

/**
 * Playback for a rendered chapter, and the clock the highlight follows.
 *
 * `preload="none"`. A chapter is a couple of megabytes and most readers open a
 * chapter to READ it; fetching the audio on sight would spend their data on
 * something they never pressed play for. The element streams on demand and the
 * server answers Range with a 206, so seeking pulls only what it needs.
 *
 * The time is reported through a ref-backed callback rather than lifted into
 * this component's state: `timeupdate` fires about four times a second, and
 * re-rendering a page of prose that often would make the reader stutter on the
 * one screen where that is least acceptable.
 */
export function NovelAudioPlayer({
  chapter,
  totalMs,
  onTimeMs,
  surface,
}: {
  chapter: ChapterId;
  totalMs: number;
  /** Called with the playhead position, or null when nothing is playing. */
  onTimeMs: (ms: number | null) => void;
  surface: { muted: string; rule: string; accent?: string };
}) {
  const audioRef = useRef<HTMLAudioElement>(null);
  const [playing, setPlaying] = useState(false);
  const [positionMs, setPositionMs] = useState(0);
  const [rate, setRate] = useState(1);

  // Held in a ref so `timeupdate` never needs a fresh closure, and so changing
  // the callback cannot re-attach the listener mid-playback.
  const reportRef = useRef(onTimeMs);
  useEffect(() => {
    reportRef.current = onTimeMs;
  }, [onTimeMs]);

  useEffect(() => {
    const element = audioRef.current;
    if (!element) return;

    const onTime = () => {
      const ms = element.currentTime * 1000;
      setPositionMs(ms);
      reportRef.current(ms);
    };
    const onPlay = () => setPlaying(true);
    const onStop = () => {
      setPlaying(false);
      // Stop the highlight when the voice stops. Leaving one sentence lit
      // after playback ends reads as a bug, not as a bookmark.
      reportRef.current(null);
    };

    element.addEventListener("timeupdate", onTime);
    element.addEventListener("play", onPlay);
    element.addEventListener("pause", onStop);
    element.addEventListener("ended", onStop);
    return () => {
      element.removeEventListener("timeupdate", onTime);
      element.removeEventListener("play", onPlay);
      element.removeEventListener("pause", onStop);
      element.removeEventListener("ended", onStop);
      reportRef.current(null);
    };
  }, []);

  useEffect(() => {
    if (audioRef.current) audioRef.current.playbackRate = rate;
  }, [rate]);

  const toggle = useCallback(() => {
    const element = audioRef.current;
    if (!element) return;
    if (element.paused) void element.play();
    else element.pause();
  }, []);

  const seek = useCallback((ms: number) => {
    const element = audioRef.current;
    if (!element) return;
    element.currentTime = ms / 1000;
    setPositionMs(ms);
    reportRef.current(ms);
  }, []);

  return (
    <div
      className="mt-6 flex items-center gap-3 rounded-lg border px-3 py-2"
      style={{ borderColor: surface.rule }}
    >
      <audio ref={audioRef} src={novelAudioUrl(chapter)} preload="none" />

      <button
        type="button"
        onClick={toggle}
        aria-label={playing ? "Pause" : "Listen to this chapter"}
        className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full border"
        style={{ borderColor: surface.rule }}
      >
        <span aria-hidden className="text-sm leading-none">
          {playing ? "❚❚" : "▶"}
        </span>
      </button>

      <input
        type="range"
        min={0}
        max={Math.max(totalMs, 1)}
        value={Math.min(positionMs, totalMs)}
        onChange={(event) => seek(Number(event.target.value))}
        aria-label="Position in chapter"
        className="h-1 min-w-0 flex-1 cursor-pointer"
      />

      <span
        className="shrink-0 font-mono text-xs tabular-nums"
        style={{ color: surface.muted }}
      >
        {clock(positionMs)} / {clock(totalMs)}
      </span>

      <label className="sr-only" htmlFor="novel-audio-rate">
        Playback speed
      </label>
      <select
        id="novel-audio-rate"
        value={rate}
        onChange={(event) => setRate(Number(event.target.value))}
        className="shrink-0 bg-transparent text-xs"
        style={{ color: surface.muted }}
      >
        {[0.75, 1, 1.25, 1.5, 1.75, 2].map((value) => (
          <option key={value} value={value}>
            {value}×
          </option>
        ))}
      </select>
    </div>
  );
}

/** m:ss, and h:mm:ss only when there is an hour to show. */
function clock(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const seconds = total % 60;
  const minutes = Math.floor(total / 60) % 60;
  const hours = Math.floor(total / 3600);
  const pad = (n: number) => String(n).padStart(2, "0");
  return hours > 0
    ? `${hours}:${pad(minutes)}:${pad(seconds)}`
    : `${minutes}:${pad(seconds)}`;
}

export const __test__ = { clock };
