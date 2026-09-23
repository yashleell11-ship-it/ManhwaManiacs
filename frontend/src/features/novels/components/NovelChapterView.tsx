"use client";

import Link from "next/link";
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { useRouter } from "next/navigation";
import {
  ArrowLeft,
  Bookmark as BookmarkIcon,
  BookmarkCheck,
  ChevronRight,
  ListOrdered,
  TriangleAlert,
  Type,
} from "lucide-react";
import { EmptyState } from "@/components/ui/empty-state";
import { OfflineState } from "@/components/ui/offline-state";
import { BookmarkNotice } from "@/features/bookmarks";
// The manga reader's own scroll writer, reused rather than re-derived: it
// rounds, clamps at zero and skips a no-op write.
import { setReaderScrollTop } from "@/features/reader/scroll-preparation";
import { tintParagraph, type SpeakerSpan, type TintedRun } from "@/features/novels/speaker-tint";
import { speakerHues } from "@/features/novels/speaker-tint";
import {
  useNovelAttribution,
  useNovelAudio,
  useNovelVoices,
  useSetNovelVoice,
} from "@/features/novels/hooks";
import { NovelAudioPlayer } from "@/features/novels/components/NovelAudioPlayer";
import { NovelCastPanel } from "@/features/novels/components/NovelCastPanel";
import { createHighlighter } from "@/features/novels/audio-highlight";
import { followAlongTiming, segmentAt } from "@/features/novels/audio-follow";
import { useScrollContainer } from "@/lib/scroll-container";
import { apiErrorMessage, resolveViewState } from "@/lib/view-state";
import { isSceneBreak, splitDropCap, tocEntry } from "../book";
import { voiceChangeError } from "../cast-labels";
import { paletteSurface } from "../palettes";
import {
  captureParagraphAnchor,
  restoreParagraphAnchor,
  type ParagraphAnchor,
} from "../paragraph-anchor";
import { createParagraphRefs } from "../paragraph-refs";
import {
  activeParagraphIndex,
  paragraphForBucket,
  progressForParagraph,
  resumeScrollTop,
} from "../progress";
import { createReadingPercent, type ReadingPercentStore } from "../reading-percent";
import { formatChapterLength } from "../reading-time";
import { novelFontStack, stepFontSize } from "../typography";
import { useNovelPalette } from "../use-novel-palette";
import { useNovelPreferences } from "../use-novel-preferences";
import { useNovelShortcuts } from "../use-novel-shortcuts";
import type { NovelProgressPosition } from "../progress";
import type { NovelChapterContent } from "../types";
import { NovelTypePanel } from "./NovelTypePanel";

interface NovelChapterViewProps {
  chapter: NovelChapterContent | undefined;
  isLoading: boolean;
  error: unknown;
  onRetry: () => void;
  /** Identifies the series whose typography this reader restores. */
  preferencesKey: string;
  seriesTitle: string;
  /** The book's own page — where Escape and the back arrow go. */
  seriesHref: string;
  /** The book's contents, opened at this chapter (`novelContentsHref`). */
  contentsHref: string;
  /** 1-based progress bucket to resume at. */
  initialBucket: number;
  /**
   * A bookmark's exact spot — a 1-based PARAGRAPH and a fraction within it —
   * off the route's `?para=&at=`. Outranks `initialBucket`, which is only ever
   * a ~1% slice of the chapter (see `progress.ts`). Null for a plain open.
   */
  initialAnchor?: { index: number; fraction: number } | null;
  /** Capture the paragraph under the reading line. */
  onBookmark: (anchor: ParagraphAnchor) => void;
  bookmarkPending?: boolean;
  bookmarkSaved?: boolean;
  bookmarkFailed?: boolean;
  previousChapterHref: string | null;
  nextChapterHref: string | null;
  /** Short label for the next chapter, e.g. "Chapter 41". */
  nextChapterLabel: string | null;
  /** Swap into the next chapter with no route navigation. */
  onSeamlessNext?: () => void;
  onProgress: (position: NovelProgressPosition) => void;
}

/** Where in the viewport a paragraph counts as "the one being read". */
const READING_LINE_RATIO = 0.35;
const SCROLL_EDGE_THRESHOLD = 48;
/** Wheel travel past the bottom that drops into the next chapter. */
const OVERSCROLL_TRIGGER = 140;
/** How long the "opened at the nearest paragraph" explanation stays up. */
const MOVED_NOTICE_MS = 5200;

/**
 * A chapter of prose.
 *
 * The page is the whole design: a single column at the reader's own measure,
 * set in a system serif, on one of the twelve reading palettes. Everything else
 * — the running head, the progress hairline, the end-of-chapter block — is
 * furniture set in the muted ink, deliberately quiet enough to disappear while
 * reading and findable when looked for.
 *
 * Progress is reported in `progress.ts` buckets (paragraph position mapped onto
 * `last_page`/`page_count`), so the server's furthest-wins merge, "continue
 * reading" and the statistics service all keep working unchanged.
 *
 * Seamless continuation is the manga reader's mechanism, not a second one: at
 * the bottom an end card appears, and a tap or a continued downward scroll asks
 * the parent to swap the chapter in place — no route navigation, no flash. See
 * `features/reader/components/SourceReader.tsx`.
 */
export function NovelChapterView({
  chapter,
  isLoading,
  error,
  onRetry,
  preferencesKey,
  seriesTitle,
  seriesHref,
  contentsHref,
  initialBucket,
  initialAnchor = null,
  onBookmark,
  bookmarkPending = false,
  bookmarkSaved = false,
  bookmarkFailed = false,
  previousChapterHref,
  nextChapterHref,
  nextChapterLabel,
  onSeamlessNext,
  onProgress,
}: NovelChapterViewProps) {
  const router = useRouter();
  const scrollElement = useScrollContainer();

  // Who speaks each line, when the server already knows. A separate query from
  // the text because attribution exists for a fraction of the library and is
  // decoration: it must never make the prose wait, and a failure here renders
  // exactly the page that shipped before any of this existed.
  const attributionRef = useMemo(
    () =>
      chapter
        ? {
            sourceId: chapter.sourceId,
            seriesKey: chapter.seriesKey,
            chapterKey: chapter.chapterKey,
          }
        : null,
    [chapter],
  );
  const paragraphs = useMemo(() => chapter?.paragraphs ?? [], [chapter]);
  const paragraphCount = paragraphs.length;

  const { data: attribution } = useNovelAttribution(attributionRef);
  const { data: audio } = useNovelAudio(attributionRef);

  // Only trust a timing map that still describes the text on screen. The
  // chapter cache refetches, so a map will eventually point at words that have
  // moved — and a highlight on the wrong words is worse than no highlight.
  // With no map the player still plays; it simply lights and scrolls nothing,
  // and the speaker colours fall back to the attribution.
  const timing = useMemo(
    () => followAlongTiming(audio, paragraphs),
    [audio, paragraphs],
  );

  const spansByParagraph = useMemo(() => {
    const byParagraph = new Map<number, SpeakerSpan[]>();
    // When the chapter has been rendered, the TIMING MAP is the better source:
    // its segments are sentences, cover the narration too, and already name
    // the speaker. One element then carries both the speaker's colour and the
    // playhead's highlight, instead of two overlapping sets of spans.
    if (timing) {
      for (const seg of timing) {
        const span: SpeakerSpan = {
          s: seg.s, e: seg.e, head: "", speaker: seg.speaker, segment: seg.i,
        };
        const list = byParagraph.get(seg.p);
        if (list) list.push(span);
        else byParagraph.set(seg.p, [span]);
      }
      return byParagraph;
    }
    if (!attribution?.attributed) return byParagraph;
    for (const span of attribution.spans) {
      const list = byParagraph.get(span.p);
      if (list) list.push(span);
      else byParagraph.set(span.p, [span]);
    }
    return byParagraph;
  }, [attribution, timing]);

  // Imperative on purpose: `timeupdate` fires about four times a second, and
  // re-rendering a page of prose that often is exactly the scroll jank this
  // reader already had to be fixed for once.
  const highlighterRef = useRef<ReturnType<typeof createHighlighter> | null>(null);
  useEffect(() => {
    const handle = createHighlighter(() => articleRef.current, { scroll: true });
    highlighterRef.current = handle;
    return () => {
      handle.dispose();
      highlighterRef.current = null;
    };
  }, [timing]);

  const onAudioTime = useCallback(
    (ms: number | null) => {
      const handle = highlighterRef.current;
      if (!handle) return;
      if (ms === null || !timing) {
        handle.set(null);
        return;
      }
      const index = segmentAt(timing, ms);
      handle.set(index < 0 ? null : timing[index].i);
    },
    [timing],
  );

  // Cast order is speaking order, so the two busiest characters in a scene get
  // the furthest-apart hues rather than whatever a hash happened to pick.
  const hues = useMemo(
    () => speakerHues((attribution?.cast ?? []).map((member) => member.name)),
    [attribution],
  );

  const [castOpen, setCastOpen] = useState(false);
  // Fetched only when the panel opens: most readers never cast anybody, and
  // the roster is a request they should not spend to turn a page.
  const { data: voices } = useNovelVoices(castOpen);
  const setVoice = useSetNovelVoice(attributionRef);

  // Counted from the spans actually shown, not from the series totals: the
  // panel answers "who speaks in THIS chapter", and a series-wide number would
  // list characters who say nothing here.
  const lineCounts = useMemo(() => {
    const counts = new Map<string, number>();
    const source = timing ?? attribution?.spans ?? [];
    for (const span of source) {
      if (!span.speaker) continue;
      counts.set(span.speaker, (counts.get(span.speaker) ?? 0) + 1);
    }
    return counts;
  }, [attribution, timing]);

  const castInChapter = useMemo(
    () => (attribution?.cast ?? []).filter((m) => lineCounts.has(m.name)),
    [attribution, lineCounts],
  );
  const { palette, choice, siteScheme, siteThemeLabel, setChoice } = useNovelPalette();
  const {
    fontSize,
    lineHeight,
    measure,
    fontFamily,
    hydrated,
    update,
  } = useNovelPreferences(preferencesKey);

  const surface = useMemo(() => paletteSurface(palette), [palette]);
  const fontStack = novelFontStack(fontFamily);

  const [typePanelOpen, setTypePanelOpen] = useState(false);
  // Not state: see `reading-percent.ts`. Only the two elements that print the
  // number subscribe, so scrolling never re-renders the page of prose.
  const [readingPercent] = useState(createReadingPercent);
  const [atBottom, setAtBottom] = useState(false);
  /** The bookmark this chapter opened from pointed past the end of the text. */
  const [anchorMoved, setAnchorMoved] = useState(false);

  const paragraphNodes = useRef<(HTMLParagraphElement | null)[]>([]);
  // Stable for the life of the chapter, which is what lets `ChapterBody` hold
  // one unchanging ref callback per paragraph (`paragraph-refs.ts`).
  const registerParagraph = useCallback(
    (index: number, node: HTMLParagraphElement | null) => {
      paragraphNodes.current[index] = node;
    },
    [],
  );
  const offsetsRef = useRef<number[]>([]);
  const articleRef = useRef<HTMLElement>(null);
  const restoredRef = useRef(false);

  // Kept in refs so the scroll listener is attached once per chapter rather
  // than re-attached on every render that changes a callback's identity.
  const onProgressRef = useRef(onProgress);
  useEffect(() => {
    onProgressRef.current = onProgress;
  }, [onProgress]);
  const seamlessNextRef = useRef(onSeamlessNext);
  useEffect(() => {
    seamlessNextRef.current = onSeamlessNext;
  }, [onSeamlessNext]);

  /**
   * Each paragraph's distance from the top of the scroll container, measured
   * once per layout rather than per scroll: a long web-novel chapter runs to
   * hundreds of paragraphs, and reading a rect for every one of them on every
   * scroll frame would be the only expensive thing on the page. The ascending
   * array is then binary-searched by `activeParagraphIndex`.
   */
  const measureOffsets = useCallback(() => {
    const container = scrollElement;
    if (!container) return;
    const containerTop = container.getBoundingClientRect().top;
    const offsets: number[] = [];
    // Exactly one entry per paragraph, in paragraph order: `offsets[i]` IS
    // paragraph `i`. A bookmark records that index and the server looks the
    // snippet up in the same array, so an entry skipped for a missing node
    // would slide every later index by one and quote the wrong sentence. A
    // node that has not attached inherits the previous offset, which keeps the
    // array ascending for `activeParagraphIndex`'s binary search.
    let previous = 0;
    for (let index = 0; index < paragraphCount; index += 1) {
      const node = paragraphNodes.current[index];
      if (node) {
        previous =
          node.getBoundingClientRect().top - containerTop + container.scrollTop;
      }
      offsets.push(previous);
    }
    offsetsRef.current = offsets;
  }, [paragraphCount, scrollElement]);

  // Re-measured whenever anything that moves a paragraph changes: the chapter
  // itself, and every typography control.
  useLayoutEffect(() => {
    measureOffsets();
  }, [measureOffsets, paragraphs, fontSize, lineHeight, measure, fontFamily]);

  // …and when the column is re-flowed by something outside this component —
  // the window resizing, or the sidebar being collapsed.
  useEffect(() => {
    const node = articleRef.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => measureOffsets());
    observer.observe(node);
    return () => observer.disconnect();
  }, [measureOffsets]);

  /**
   * Land on the saved paragraph, once, after the first real measurement.
   *
   * Held until `hydrated` because the stored type size decides where every
   * paragraph sits: restoring against default-size offsets and then applying a
   * 24px preference would drop the reader in the wrong place.
   */
  useEffect(() => {
    if (restoredRef.current || !hydrated || !scrollElement) return;
    if (paragraphCount === 0) return;
    const offsets = offsetsRef.current;
    if (offsets.length === 0) return;
    restoredRef.current = true;

    // A bookmark lands on the exact spot, not the chapter start and not the
    // top of the paragraph: the recorded index is resolved against the
    // paragraphs this chapter has NOW (design §3 — an aggregator can re-split
    // the text under it), and the reading line is put back where the capture
    // measured it. The bucket resume below has only a paragraph, so it puts
    // that paragraph's top on the line; a bookmark has a pixel and must
    // reproduce it.
    if (initialAnchor) {
      const target = restoreParagraphAnchor(
        offsets,
        initialAnchor,
        scrollElement.scrollHeight,
      );
      if (!target) return;
      setAnchorMoved(target.stale);
      setReaderScrollTop(
        scrollElement,
        target.point - scrollElement.clientHeight * READING_LINE_RATIO,
      );
      return;
    }

    if (initialBucket <= 1) return;
    const index = paragraphForBucket(initialBucket, paragraphCount);
    const target = offsets[index];
    if (target == null) return;
    // On the reading line, not near the head: the landing is a scroll, and
    // progress is read at that line (see `resumeScrollTop`).
    setReaderScrollTop(
      scrollElement,
      resumeScrollTop(target, scrollElement.clientHeight, READING_LINE_RATIO),
    );
  }, [hydrated, initialAnchor, initialBucket, paragraphCount, scrollElement]);

  const updateScrollState = useCallback(() => {
    const container = scrollElement;
    if (!container) return;
    const { scrollTop, scrollHeight, clientHeight } = container;
    const maxScroll = Math.max(scrollHeight - clientHeight, 0);
    readingPercent.set(maxScroll > 0 ? (scrollTop / maxScroll) * 100 : 100);
    setAtBottom(scrollTop + clientHeight >= scrollHeight - SCROLL_EDGE_THRESHOLD);

    const offsets = offsetsRef.current;
    if (offsets.length === 0) return;
    const index = activeParagraphIndex(
      offsets,
      scrollTop + clientHeight * READING_LINE_RATIO,
    );
    onProgressRef.current(progressForParagraph(index, offsets.length));
  }, [readingPercent, scrollElement]);

  useEffect(() => {
    const container = scrollElement;
    if (!container) return;
    let frame = 0;
    const handleScroll = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(updateScrollState);
    };
    handleScroll();
    container.addEventListener("scroll", handleScroll, { passive: true });
    return () => {
      container.removeEventListener("scroll", handleScroll);
      cancelAnimationFrame(frame);
    };
  }, [scrollElement, updateScrollState]);

  // Continued scroll past the end card drops into the next chapter — the same
  // gesture, the same threshold, as the manga reader's continuous strip.
  useEffect(() => {
    if (!scrollElement || !atBottom || !onSeamlessNext) return;
    let overscroll = 0;
    let resetTimer: number | null = null;
    const handleWheel = (event: WheelEvent) => {
      if (event.ctrlKey || event.metaKey || event.deltaY <= 0) return;
      overscroll += event.deltaY;
      if (resetTimer) window.clearTimeout(resetTimer);
      resetTimer = window.setTimeout(() => {
        overscroll = 0;
      }, 320);
      if (overscroll >= OVERSCROLL_TRIGGER) {
        overscroll = 0;
        seamlessNextRef.current?.();
      }
    };
    scrollElement.addEventListener("wheel", handleWheel, { passive: true });
    return () => {
      scrollElement.removeEventListener("wheel", handleWheel);
      if (resetTimer) window.clearTimeout(resetTimer);
    };
  }, [scrollElement, atBottom, onSeamlessNext]);

  /**
   * The paragraph under the reading line, and how far into it — in one action.
   *
   * Measured at exactly the line `activeParagraphIndex` picks the paragraph
   * by, so index and fraction always describe the same point; the restore
   * above is this run backwards. Null while the column has not been measured,
   * which is what makes the binding inert on a loading or empty chapter rather
   * than saving "paragraph 1 of 0".
   */
  const captureAnchor = useCallback((): ParagraphAnchor | null => {
    const container = scrollElement;
    if (!container) return null;
    return captureParagraphAnchor(
      offsetsRef.current,
      container.scrollTop + container.clientHeight * READING_LINE_RATIO,
      container.scrollHeight,
    );
  }, [scrollElement]);

  const handleBookmark = useCallback(() => {
    const anchor = captureAnchor();
    if (!anchor) return;
    onBookmark(anchor);
  }, [captureAnchor, onBookmark]);

  useNovelShortcuts({
    onPreviousChapter: () => {
      if (previousChapterHref) router.push(previousChapterHref);
    },
    onNextChapter: () => {
      if (onSeamlessNext) {
        onSeamlessNext();
      } else if (nextChapterHref) {
        router.push(nextChapterHref);
      }
    },
    onLargerText: () => update({ fontSize: stepFontSize(fontSize, 1) }),
    onSmallerText: () => update({ fontSize: stepFontSize(fontSize, -1) }),
    onToggleTypePanel: () => setTypePanelOpen((open) => !open),
    onBookmark: handleBookmark,
    canBookmark: paragraphCount > 0,
    onEscape: () => {
      if (typePanelOpen) {
        setTypePanelOpen(false);
        return;
      }
      router.push(seriesHref);
    },
  });

  // "Say so quietly" (design §3), then get out of the way: this explains where
  // the reader landed, and stops being useful the moment they start reading.
  useEffect(() => {
    if (!anchorMoved) return;
    const timer = window.setTimeout(() => setAnchorMoved(false), MOVED_NOTICE_MS);
    return () => window.clearTimeout(timer);
  }, [anchorMoved]);

  const bookmarkNotice = bookmarkFailed
    ? { tone: "failed" as const, text: "Couldn't save that spot." }
    : bookmarkSaved
      ? { tone: "saved" as const, text: "Saved this spot." }
      : anchorMoved
        ? {
            tone: "moved" as const,
            text: "The text here changed — opened at the nearest paragraph.",
          }
        : null;

  const viewState = resolveViewState({
    isLoading,
    error,
    isEmpty: chapter != null && paragraphCount === 0,
  });

  const heading = useMemo(() => {
    if (!chapter) return { eyebrow: null as string | null, title: "Chapter" };
    const entry = tocEntry({ number: chapter.chapterNumber, title: chapter.title });
    const numbered = entry.ordinal ? `Chapter ${entry.ordinal}` : null;
    // When the source gave nothing but a number, that number IS the title —
    // printing it twice, once small and once large, is the tell of a template.
    return entry.title
      ? { eyebrow: numbered, title: entry.title }
      : { eyebrow: null, title: numbered ?? chapter.title };
  }, [chapter]);

  const lengthLine = chapter ? formatChapterLength(chapter.wordCount) : null;

  return (
    <div
      className="min-h-full"
      style={{ backgroundColor: surface.bg, color: surface.ink }}
    >
      <RunningHead
        surface={surface}
        seriesTitle={seriesTitle}
        seriesHref={seriesHref}
        contentsHref={contentsHref}
        chapterLabel={heading.eyebrow ?? heading.title}
        readingPercent={readingPercent}
        onBookmark={paragraphCount > 0 ? handleBookmark : undefined}
        bookmarkPending={bookmarkPending}
        bookmarkSaved={bookmarkSaved}
        typePanelOpen={typePanelOpen}
        onToggleTypePanel={() => setTypePanelOpen((open) => !open)}
        panel={
          typePanelOpen ? (
            <NovelTypePanel
              surface={surface}
              preferences={{ fontSize, lineHeight, measure, fontFamily }}
              onChange={update}
              choice={choice}
              onChoosePalette={setChoice}
              siteScheme={siteScheme}
              siteThemeLabel={siteThemeLabel}
              onClose={() => setTypePanelOpen(false)}
            />
          ) : null
        }
      />

      {viewState === "loading" || !hydrated ? (
        <ChapterSkeleton surface={surface} measure={measure} />
      ) : viewState === "offline" ? (
        <div className="mx-auto max-w-2xl px-6 py-16">
          <OfflineState
            reason="This chapter needs a connection to load."
            onRetry={onRetry}
          />
        </div>
      ) : viewState === "error" || !chapter ? (
        <div className="mx-auto max-w-2xl px-6 py-16">
          <EmptyState
            tone="error"
            icon={TriangleAlert}
            title="Couldn't load this chapter"
            description={apiErrorMessage(error, "The source did not answer.")}
            action={{ label: "Try again", onClick: onRetry }}
            secondaryAction={{ label: "Back to the book", href: seriesHref }}
          />
        </div>
      ) : viewState === "empty" ? (
        <div className="mx-auto max-w-2xl px-6 py-16">
          <EmptyState
            tone="error"
            icon={TriangleAlert}
            title="This chapter came through empty"
            description="The source answered, but with no text in it — usually a page that has been pulled or is still being published."
            action={{ label: "Try again", onClick: onRetry }}
            secondaryAction={{ label: "Back to the book", href: seriesHref }}
          />
        </div>
      ) : (
        <article
          ref={articleRef}
          // Horizontal insets, not a flat `px-6`: held in landscape on a
          // notched iPhone the 1.5rem gutter is entirely inside the notch's
          // shadow on one side, and the first character of every line sits
          // under it.
          className="mx-auto pb-24 pt-14 pl-[max(1.5rem,env(safe-area-inset-left))] pr-[max(1.5rem,env(safe-area-inset-right))] sm:pt-20"
          style={{
            maxWidth: `${measure}ch`,
            fontFamily: fontStack,
            fontSize: `${fontSize}px`,
            lineHeight: String(lineHeight),
          }}
        >
          <header className="mb-10">
            {heading.eyebrow ? (
              <p
                className="text-[0.6875em] font-semibold uppercase tracking-[0.22em]"
                style={{ color: surface.muted }}
              >
                {heading.eyebrow}
              </p>
            ) : null}
            <h1 className="mt-2 text-[1.55em] font-normal leading-[1.2]">
              {heading.title}
            </h1>
            <div
              className="mt-7 h-px w-14"
              style={{ backgroundColor: surface.rule }}
              aria-hidden
            />
            {/* At the TOP of the chapter, where somebody deciding how to read
                it actually is. It used to sit after the last paragraph, which
                meant a chapter with a voice looked identical to one without
                unless you scrolled the whole way down. */}
            {audio?.available && attributionRef ? (
              <NovelAudioPlayer
                chapter={attributionRef}
                totalMs={audio.total_ms}
                onTimeMs={onAudioTime}
                surface={surface}
              />
            ) : null}
          </header>

          <ChapterBody
            paragraphs={paragraphs}
            surface={surface}
            registerParagraph={registerParagraph}
            spansByParagraph={spansByParagraph}
            hues={hues}
          />

          {castInChapter.length > 0 || attribution?.narrator ? (
            <div className="mt-6 flex justify-end">
              <button
                type="button"
                onClick={() => setCastOpen((open) => !open)}
                className="text-xs underline-offset-2 hover:underline"
                style={{ color: surface.muted }}
                aria-expanded={castOpen}
              >
                {castOpen ? "Hide voices" : `Voices (${castInChapter.length})`}
              </button>
            </div>
          ) : null}

          {castOpen ? (
            <NovelCastPanel
              cast={castInChapter}
              hues={hues}
              lineCounts={lineCounts}
              narrator={attribution?.narrator ?? null}
              surface={surface}
              onClose={() => setCastOpen(false)}
              voices={voices?.voices}
              narratorVoiceId={attribution?.narrator_voice_id ?? null}
              saving={setVoice.isPending}
              error={voiceChangeError(setVoice.error)}
              onChooseVoice={(name, voiceId) =>
                setVoice.mutate({ name, voiceId })
              }
            />
          ) : null}

          <footer className="mt-16">
            <div
              className="mx-auto h-px w-24"
              style={{ backgroundColor: surface.rule }}
              aria-hidden
            />
            <p
              className="mt-6 text-center text-[0.6875em] uppercase tracking-[0.22em]"
              style={{ color: surface.muted }}
            >
              End of {heading.eyebrow ?? heading.title}
            </p>
            {lengthLine ? (
              <p
                className="mt-2 text-center text-[0.75em]"
                style={{ color: surface.muted }}
              >
                {lengthLine}
              </p>
            ) : null}

            <div className="mt-10 flex flex-col items-center gap-3">
              {nextChapterHref && nextChapterLabel ? (
                <Link
                  href={nextChapterHref}
                  onClick={(event) => {
                    if (!onSeamlessNext) return;
                    if (
                      event.metaKey ||
                      event.ctrlKey ||
                      event.shiftKey ||
                      event.altKey
                    ) {
                      return;
                    }
                    event.preventDefault();
                    onSeamlessNext();
                  }}
                  className="group flex w-full max-w-sm items-center justify-between gap-4 rounded-xl px-5 py-4 transition-opacity hover:opacity-80"
                  style={{ border: `1px solid ${surface.rule}` }}
                >
                  <span className="min-w-0">
                    <span
                      className="block text-[0.625em] uppercase tracking-[0.22em]"
                      style={{ color: surface.muted }}
                    >
                      Next
                    </span>
                    <span className="mt-1 block truncate text-[0.95em]">
                      {nextChapterLabel}
                    </span>
                  </span>
                  <ChevronRight
                    className="size-5 shrink-0 transition-transform group-hover:translate-x-0.5"
                    aria-hidden
                  />
                </Link>
              ) : (
                <p className="text-[0.8125em]" style={{ color: surface.muted }}>
                  You have reached the last chapter this source has published.
                </p>
              )}

              <div
                className="flex items-center gap-4 text-[0.75em]"
                style={{ color: surface.muted }}
              >
                {previousChapterHref ? (
                  <Link href={previousChapterHref} className="hover:opacity-70">
                    Previous chapter
                  </Link>
                ) : null}
                <Link href={seriesHref} className="hover:opacity-70">
                  Back to the book
                </Link>
              </div>
            </div>
          </footer>
        </article>
      )}

      {/* Painted in the reading palette rather than the app surface: a
          near-black pill over a Paper page would defeat the point of choosing
          Paper. */}
      {bookmarkNotice ? (
        <BookmarkNotice
          tone={bookmarkNotice.tone}
          style={{
            backgroundColor: surface.bg,
            color: surface.ink,
            border: `1px solid ${surface.rule}`,
          }}
        >
          {bookmarkNotice.text}
        </BookmarkNotice>
      ) : null}
    </div>
  );
}

/**
 * The running head: the book, the chapter, and how far in you are.
 *
 * Sticky rather than fixed, so it lives in the shell's own scroll container and
 * needs no knowledge of the reader's layout. Everything in it is set in the
 * muted ink — a running head that competes with the prose is a running head
 * nobody wants on the page.
 */
function RunningHead({
  surface,
  seriesTitle,
  seriesHref,
  contentsHref,
  chapterLabel,
  readingPercent,
  onBookmark,
  bookmarkPending,
  bookmarkSaved,
  typePanelOpen,
  onToggleTypePanel,
  panel,
}: {
  surface: ReturnType<typeof paletteSurface>;
  seriesTitle: string;
  seriesHref: string;
  contentsHref: string;
  chapterLabel: string;
  /**
   * Subscribed to by the read-out and the hairline INDIVIDUALLY rather than
   * read here: a head that re-rendered on every scroll frame would take the
   * open type panel down with it.
   */
  readingPercent: ReadingPercentStore;
  /** Absent until there is text on screen to take a position in. */
  onBookmark?: () => void;
  bookmarkPending: boolean;
  bookmarkSaved: boolean;
  typePanelOpen: boolean;
  onToggleTypePanel: () => void;
  panel: React.ReactNode;
}) {
  return (
    <div
      // The novel reader is the one screen that hides the app's Topbar and
      // paints its own chrome, which means it is also the one screen that has
      // to clear the notch itself: `viewport-fit=cover` plus the installed
      // app's `black-translucent` status bar draw this row straight under the
      // Dynamic Island. Padding rather than a margin so the head's own page
      // colour fills the strip behind the clock instead of a black band.
      className="sticky top-0 z-40 pt-[env(safe-area-inset-top)]"
      style={{ backgroundColor: surface.bg, color: surface.ink }}
    >
      <div className="mx-auto flex max-w-5xl items-center gap-3 py-3 pl-[max(1rem,env(safe-area-inset-left))] pr-[max(1rem,env(safe-area-inset-right))] sm:pl-[max(1.5rem,env(safe-area-inset-left))] sm:pr-[max(1.5rem,env(safe-area-inset-right))]">
        <Link
          href={seriesHref}
          aria-label="Back to the book"
          className="flex size-8 shrink-0 items-center justify-center rounded-lg transition-opacity hover:opacity-70 [@media(pointer:coarse)]:size-11"
          style={{ color: surface.muted }}
        >
          <ArrowLeft className="size-4" aria-hidden />
        </Link>
        <p
          className="min-w-0 flex-1 truncate text-[0.6875rem] uppercase tracking-[0.18em]"
          style={{ color: surface.muted }}
        >
          <span className="truncate">{seriesTitle}</span>
          <span aria-hidden> · </span>
          <span className="truncate">{chapterLabel}</span>
        </p>
        <PercentReadout store={readingPercent} color={surface.muted} />
        {/* The contents, at this chapter. Previous and next were the only way
            to move through a book, and Shadow Slave has 3,188 chapters. */}
        <Link
          href={contentsHref}
          aria-label="Contents"
          title="Contents"
          className="flex size-8 shrink-0 items-center justify-center rounded-lg transition-opacity hover:opacity-70 [@media(pointer:coarse)]:size-11"
          style={{ color: surface.muted }}
        >
          <ListOrdered className="size-4" aria-hidden />
        </Link>
        {/* The pointer equivalent of `b`. Set in the muted ink like every
            other piece of furniture in the head, so it is findable without
            competing with the prose. */}
        {onBookmark ? (
          <button
            type="button"
            aria-label="Bookmark this spot"
            onClick={onBookmark}
            disabled={bookmarkPending}
            title="Bookmark this spot (B)"
            className="flex size-8 shrink-0 items-center justify-center rounded-lg transition-opacity hover:opacity-70 disabled:opacity-40 [@media(pointer:coarse)]:size-11"
            style={{ color: bookmarkSaved ? surface.ink : surface.muted }}
          >
            {bookmarkSaved ? (
              <BookmarkCheck className="size-4" aria-hidden />
            ) : (
              <BookmarkIcon className="size-4" aria-hidden />
            )}
          </button>
        ) : null}
        <div className="relative shrink-0">
          <button
            type="button"
            aria-label="Type and page settings"
            aria-expanded={typePanelOpen}
            onClick={onToggleTypePanel}
            className="flex size-8 items-center justify-center rounded-lg transition-opacity hover:opacity-70 [@media(pointer:coarse)]:size-11"
            style={{
              color: surface.ink,
              border: `1px solid ${typePanelOpen ? surface.rule : "transparent"}`,
            }}
          >
            <Type className="size-4" aria-hidden />
          </button>
          {panel}
        </div>
      </div>
      {/* The progress indicator: one hairline, the width of how far you are. */}
      <ProgressHairline store={readingPercent} surface={surface} />
    </div>
  );
}

/**
 * The only two things a scroll frame is allowed to re-render.
 *
 * `store.get` doubles as the server snapshot: the position is measured from a
 * scroll container that does not exist during SSR, so zero is both the honest
 * starting value and the one the client hydrates against.
 */
function useReadingPercent(store: ReadingPercentStore): number {
  return useSyncExternalStore(store.subscribe, store.get, store.get);
}

function PercentReadout({
  store,
  color,
}: {
  store: ReadingPercentStore;
  color: string;
}) {
  const percent = useReadingPercent(store);
  return (
    <span className="shrink-0 text-[0.6875rem] tabular-nums" style={{ color }}>
      {percent}%
    </span>
  );
}

function ProgressHairline({
  store,
  surface,
}: {
  store: ReadingPercentStore;
  surface: ReturnType<typeof paletteSurface>;
}) {
  const percent = useReadingPercent(store);
  return (
    <div className="h-px w-full" style={{ backgroundColor: surface.rule }}>
      <div
        className="h-px transition-[width] duration-150"
        style={{ width: `${percent}%`, backgroundColor: surface.muted }}
        aria-hidden
      />
    </div>
  );
}

/**
 * The prose itself.
 *
 * Paragraphs are indented rather than spaced, which is how a book sets them and
 * is what makes a page of dialogue read as a page of a novel rather than as a
 * chat log. The opening paragraph is flush and carries the drop cap; scene
 * breaks are set centred with air around them instead of being run through the
 * body style as a line of asterisks.
 *
 * Memoised, and every prop it takes is stable for the life of the chapter, so
 * nothing that happens in the head — the type panel opening, a bookmark being
 * saved, the reader arriving at the bottom — walks a page of prose again.
 */
/**
 * Quoted speech, tinted by who says it.
 *
 * A `<span>` INSIDE the paragraph, never instead of it: `measureOffsets` reads
 * each `<p>`'s own rect through `registerParagraph`, and every saved reading
 * position in the library is an index into that array. Replacing the paragraph
 * element, or skipping its ref, would silently move every bookmark.
 */
function SpeechRun({
  run,
  hue,
}: {
  run: TintedRun;
  hue: number | undefined;
}) {
  if (run.speaker === null || hue === undefined) {
    // Narration still needs to be addressable when it has a segment, because
    // the playhead moves through narration too — most of a chapter is it.
    return run.segment === undefined ? (
      <>{run.text}</>
    ) : (
      <span data-segment={run.segment}>{run.text}</span>
    );
  }
  return (
    <span
      // Tint only — the ink stays the reader's own, so a speaker colour can
      // never make prose harder to read than the untinted page it replaces.
      style={{
        backgroundColor: `hsl(${hue} 70% 50% / 0.16)`,
        boxShadow: `inset 0 -1px 0 hsl(${hue} 60% 45% / 0.55)`,
        borderRadius: "2px",
      }}
      data-speaker={run.speaker}
      data-segment={run.segment}
    >
      {run.text}
    </span>
  );
}

const ChapterBody = memo(function ChapterBody({
  paragraphs,
  surface,
  registerParagraph,
  spansByParagraph,
  hues,
}: {
  paragraphs: readonly string[];
  surface: ReturnType<typeof paletteSurface>;
  registerParagraph: (index: number, node: HTMLParagraphElement | null) => void;
  /** Attributed speech per paragraph index, when the chapter has any. */
  spansByParagraph?: ReadonlyMap<number, readonly SpeakerSpan[]>;
  /** Speaker label to hue. A speaker with no hue renders as plain prose. */
  hues?: ReadonlyMap<string, number>;
}) {
  const dropCap = splitDropCap(paragraphs[0]);
  const paragraphRef = useMemo(
    () => createParagraphRefs(registerParagraph),
    [registerParagraph],
  );

  return (
    <>
      {paragraphs.map((paragraph, index) => {
        const register = paragraphRef(index);

        if (isSceneBreak(paragraph)) {
          return (
            <p
              key={index}
              ref={register}
              className="my-8 text-center tracking-[0.5em]"
              style={{ color: surface.muted }}
            >
              {paragraph.trim()}
            </p>
          );
        }

        // The drop-cap paragraph is left untinted. The cap splits the first
        // character into its own floated span, which would have to be
        // reconciled with a span boundary landing in the same place; a chapter
        // rarely opens mid-dialogue, so the reading affordance wins.
        if (index === 0 && dropCap) {
          return (
            <p key={index} ref={register} className="mt-0">
              <span
                className="float-left pr-[0.07em] font-normal"
                style={{ fontSize: "3.1em", lineHeight: 0.84, paddingTop: "0.04em" }}
              >
                {dropCap.initial}
              </span>
              {dropCap.rest}
            </p>
          );
        }

        // Null whenever the offsets cannot be proved against this exact text
        // — a refetched chapter, or an astral character shifting UTF-16
        // indices — and then the paragraph renders exactly as it always did.
        const runs = spansByParagraph?.size
          ? tintParagraph(paragraph, spansByParagraph.get(index) ?? [])
          : null;

        return (
          <p
            key={index}
            ref={register}
            className={index === 0 ? "mt-0" : "mt-[0.35em] indent-[1.3em]"}
          >
            {runs
              ? runs.map((run, runIndex) => (
                  <SpeechRun
                    key={runIndex}
                    run={run}
                    hue={run.speaker ? hues?.get(run.speaker) : undefined}
                  />
                ))
              : paragraph}
          </p>
        );
      })}
    </>
  );
});

/**
 * The shape of a page of prose, while it loads.
 *
 * Lines at the reader's own measure rather than a generic block, so the column
 * does not jump width the moment the text arrives.
 */
function ChapterSkeleton({
  surface,
  measure,
}: {
  surface: ReturnType<typeof paletteSurface>;
  measure: number;
}) {
  const widths = [96, 99, 92, 97, 88, 98, 94, 99, 90, 96, 93, 87];
  return (
    <div
      className="mx-auto px-6 pb-24 pt-14 sm:pt-20"
      style={{ maxWidth: `${measure}ch` }}
      aria-busy="true"
      aria-label="Loading chapter"
    >
      <div
        className="h-3 w-24 rounded animate-pulse"
        style={{ backgroundColor: surface.rule }}
      />
      <div
        className="mt-4 h-7 w-2/3 rounded animate-pulse"
        style={{ backgroundColor: surface.rule }}
      />
      <div className="mt-12 space-y-4">
        {widths.map((width, index) => (
          <div
            key={index}
            className="h-3.5 rounded animate-pulse"
            style={{ width: `${width}%`, backgroundColor: surface.rule }}
          />
        ))}
      </div>
    </div>
  );
}
