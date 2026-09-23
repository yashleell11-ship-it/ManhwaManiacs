"use client";

import { useCallback, useEffect, useRef } from "react";
import { useSaveProgress } from "./hooks";
import { useReadingClock } from "./reading-clock";
import type { StripChapter, StripPosition } from "./strip";
import { createStripProgressTracker, type StripProgressTracker } from "./strip-progress";

export interface StripProgressInput {
  sourceId: string;
  seriesKey: string;
  /** The strip's loaded chapters, for the numbers a progress row carries. */
  chapters: readonly StripChapter[];
  /** Fires when the reading line crosses into a different chapter. */
  onChapterChange?: (chapterKey: string) => void;
}

/**
 * Reading position for a strip that spans several chapters (spec R1/R2). The
 * rules live in `createStripProgressTracker`; this binds them to the reader.
 *
 * One tracker per mounted reader, fed its inputs through a ref, so a strip that
 * grows by a chapter does not start a fresh tracker and forget how far the
 * reader got.
 *
 * The pending write is FLUSHED when the reader unmounts and when the page is
 * hidden, not dropped. Back, the series link and a paged turn into the next
 * chapter (a route, so a remount) all unmount within the debounce often
 * enough, and the report they cut off is usually the chapter's last page — the
 * completion. `visibilitychange` to hidden fires before a tab closes, while the
 * page can still send; `pagehide` covers a page put in the back/forward cache
 * without being hidden first. Mobile's reader flushes on dispose for the same
 * reason.
 */
export function useStripProgress({
  sourceId,
  seriesKey,
  chapters,
  onChapterChange,
}: StripProgressInput): (position: StripPosition) => void {
  const saveProgress = useSaveProgress();
  const takeElapsed = useReadingClock();

  const inputs = useRef({ sourceId, seriesKey, chapters, onChapterChange, saveProgress });
  useEffect(() => {
    inputs.current = { sourceId, seriesKey, chapters, onChapterChange, saveProgress };
  }, [chapters, onChapterChange, saveProgress, seriesKey, sourceId]);

  // Made on the first report rather than during render: the strip can report
  // from its own mount effects, which run before this component's.
  const trackerRef = useRef<StripProgressTracker | null>(null);

  useEffect(() => {
    const flush = () => trackerRef.current?.flush();
    const flushWhenHidden = () => {
      if (document.visibilityState === "hidden") flush();
    };
    document.addEventListener("visibilitychange", flushWhenHidden);
    window.addEventListener("pagehide", flush);
    return () => {
      document.removeEventListener("visibilitychange", flushWhenHidden);
      window.removeEventListener("pagehide", flush);
      flush();
    };
  }, []);

  return useCallback(
    (position: StripPosition) => {
      trackerRef.current ??= createStripProgressTracker({
        chapters: () => inputs.current.chapters,
        takeElapsed,
        onChapterChange: (chapterKey) => inputs.current.onChapterChange?.(chapterKey),
        save: (chapterKey, body) => {
          const current = inputs.current;
          current.saveProgress.mutate({
            ref: { sourceId: current.sourceId, seriesKey: current.seriesKey, chapterKey },
            body,
          });
        },
      });
      trackerRef.current.report(position);
    },
    [takeElapsed],
  );
}
