"use client";

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useScrollContainer } from "@/lib/scroll-container";
import { useUiStore } from "@/stores/ui-store";
import { cn } from "@/lib/cn";
import { moodReaderMargin, useActiveProfileStore } from "@/features/profiles";
import { createReadingPercent } from "@/features/novels/reading-percent";
import { DownloadChapterControl } from "@/features/offline";
import {
  BookmarkNotice,
  fractionWithin,
  pointWithin,
  resolveAnchor,
} from "@/features/bookmarks";
import { autoScrollPxPerSecond } from "../auto-scroll";
import { readerDebug } from "../debug";
import { effectiveFitMode, wheelZoomSteps, zoomBy } from "../fit";
import {
  defaultTapZoneConfig,
  resolveEscapeTarget,
  resolveTapZone,
  TOGGLE_ONLY_TAP_ZONES,
  type PageTurn,
  type TapZone,
} from "../keymap";
import {
  estimatePageHeight,
  estimateScrollOffsetToPage,
  resolveContainerWidth,
} from "../page-layout";
import { readerChapterHref } from "../reader-link";
import {
  clearChapterScrollPreparation,
  estimateResumeOffset,
  scrollReaderBy,
  setReaderScrollTop,
  syncChapterScroll,
} from "../scroll-preparation";
import {
  readReaderPosition,
  writeReaderPosition,
  type ReaderPosition,
} from "../scroll-storage";
import { scrubPercent } from "../scrub";
import {
  buildPageViews,
  findViewIndex,
  pagedProgressPosition,
  viewLeadPage,
} from "../spread";
import { useReaderStore } from "../store";
import {
  chapterIndexOf,
  nextChapterLabelFor,
  stripChapterLabel,
  type StripChapter,
  type StripPosition,
} from "../strip";
import { useAutoScroll } from "../use-auto-scroll";
import { useCinema } from "../use-cinema";
import { useChapterPreload } from "../use-chapter-preload";
import { useFullscreen } from "../use-fullscreen";
import { useReaderPreferences } from "../use-reader-preferences";
import { useReaderSettings } from "../use-reader-settings";
import { useReaderShortcuts } from "../use-reader-shortcuts";
import type { StripEdge } from "../use-chapter-strip";
import type { ReadingMode } from "../types";
import { installWheelZoomArming } from "../wheel-zoom-arming";
import {
  ContinuousStrip,
  READING_LINE_PX,
  type StripHandle,
} from "./ContinuousStrip";
import { PagedView } from "./PagedView";
import { ReaderControls, StripHead, StripTail } from "./ReaderControls";

interface ChapterReaderProps {
  /**
   * The strip: every chapter currently loaded, in reading order. Continuous
   * mode renders them as ONE scroll, so the last page of chapter N and the
   * first of N+1 sit in the same viewport (spec 2026-09-05 R1). The paged
   * modes still show one chapter at a time — a seam has no meaning when the
   * viewport holds exactly one page.
   */
  chapters: readonly StripChapter[];
  /** The chapter the strip opened on: whose saved scroll and page it restores. */
  entryChapterKey: string;
  isLoading: boolean;
  /** Why the ENTRY chapter did not load; a later one is `nextError`. */
  error: string | null;
  onRetry?: () => void;
  /** Identifies the series whose reading mode / fit / zoom this reader restores. */
  seriesKey: string;
  initialPage?: number;
  /**
   * This chapter's own series page. It is both where the reader exits to and
   * where the "Series" control jumps, so a chapter opened from search, Updates
   * or a deep link still reaches its chapter list without retracing history.
   */
  seriesHref: string;
  /**
   * What lies just outside each end of the strip. The strip's owner knows this
   * and the strip does not: Read-all reads it off the series' chapter list,
   * while the plain reader has only the manifest's own neighbour links.
   */
  head: StripEdge;
  tail: StripEdge;
  /** Where the active chapter sits in the series, e.g. "13 of 40". */
  chapterPosition?: string | null;
  /** Fires on every scroll frame with the chapter and page being read. */
  onPosition?: (position: StripPosition) => void;
  /**
   * Capture the exact spot being read — a page AND how far down it — in one
   * action (design §5). A page number alone is thousands of pixels of webtoon
   * strip, which is why this is not `(page: number)`.
   */
  onBookmark?: (anchor: CapturedAnchor) => void;
  /**
   * Open at an exact position rather than at `initialPage`'s top: the fraction
   * of that page a bookmark recorded, off the route's `?at=`.
   */
  initialAnchorFraction?: number | null;
  /** A capture just succeeded / just failed — drives the transient pill. */
  bookmarkSaved?: boolean;
  bookmarkFailed?: boolean;
  /** Pull the chapter BEFORE the strip's first onto its head. */
  onLoadPrevious?: () => void;
  loadingPrevious?: boolean;
  /** Why the next chapter did not arrive, if it did not. */
  nextError?: string | null;
  onRetryNext?: () => void;
  /** Resolves the next chapter's payload so the paged modes can pull it early. */
  preloadNextChapter?: () => Promise<ReadonlyArray<{ imageUrl: string }>>;
  bookmarkPending?: boolean;
  showBookmark?: boolean;
  /**
   * Pin the reader to the strip, whatever this series' saved layout says.
   *
   * A run through a whole series IS a scroll: the paged modes render only the
   * ACTIVE chapter's pages, the position report that moves the run from one
   * chapter to the next comes from the strip alone, and "next chapter" there
   * falls through to a route — which navigates out of the run and back into the
   * ordinary single-chapter reader. Read-all sets this so a reader who once
   * chose two-page mode for a manga does not get one chapter and a silent exit.
   * The preference itself is untouched, so leaving the run restores their
   * layout.
   */
  continuousOnly?: boolean;
}

/** How long the "opened at the nearest page" explanation stays up. */
const MOVED_NOTICE_MS = 5200;

/** The exact spot a bookmark records: a page, how far into it, and of how many. */
export interface CapturedAnchor {
  /** 1-based page in the ACTIVE chapter. */
  index: number;
  /** 0.0–1.0 down that page. */
  fraction: number;
  /** Pages in that chapter right now — what turns the pair into a percentage. */
  total: number;
}

const SCROLL_EDGE_THRESHOLD = 48;
const SCROLL_SAVE_MS = 250;
/** Fraction of the viewport a Space press travels, leaving an overlap to re-read. */
const SCREEN_SCROLL_RATIO = 0.9;
/** Wheel travel past the top that pulls the previous chapter onto the strip. */
const OVERSCROLL_TRIGGER = 140;

/** Stable no-op so `useChapterPreload` is not re-armed by an identity change. */
const NO_PRELOAD = async (): Promise<ReadonlyArray<{ imageUrl: string }>> => [];

/** Stable placeholder view for the frame before any page is known. */
const FIRST_PAGE_VIEW = [1];

/** The per-chapter key reading positions have always been stored under. */
function chapterScrollKey(chapter: StripChapter): string {
  return `${chapter.sourceId}:${chapter.seriesKey}:${chapter.chapterKey}`;
}

export function ChapterReader({
  chapters,
  entryChapterKey,
  isLoading,
  error,
  onRetry,
  seriesKey,
  initialPage = 1,
  seriesHref,
  head,
  tail,
  chapterPosition,
  onPosition,
  onBookmark,
  initialAnchorFraction = null,
  bookmarkSaved = false,
  bookmarkFailed = false,
  onLoadPrevious,
  loadingPrevious = false,
  nextError = null,
  onRetryNext,
  preloadNextChapter,
  bookmarkPending,
  showBookmark = true,
  continuousOnly = false,
}: ChapterReaderProps) {
  const router = useRouter();
  const scrollElement = useScrollContainer();
  const toggleControls = useReaderStore((state) => state.toggleControls);
  const setControlsVisible = useReaderStore((state) => state.setControlsVisible);
  const {
    pageGap,
    cinema,
    dimmer,
    warmth,
    pageTransition,
    tapZones,
    togglePageGap,
    setCinema,
    togglePageTransition,
    setDimmer,
    setWarmth,
    setTapZones,
  } = useReaderSettings();

  const {
    readingMode: preferredReadingMode,
    fitMode,
    direction,
    zoom,
    autoScrollSpeed,
    hydrated: preferencesReady,
    update: updatePreferences,
  } = useReaderPreferences(seriesKey);
  // Resolved once, here, so every layout decision below — the view builder, the
  // page-turn handlers, the chrome — reads the mode the reader is actually in.
  const readingMode = continuousOnly ? "continuous" : preferredReadingMode;
  const fullscreen = useFullscreen();

  const scrollSaveTimerRef = useRef<number | null>(null);
  const stripHandleRef = useRef<StripHandle | null>(null);
  const pendingScrollPageRef = useRef<number | null>(null);
  const restoreDoneRef = useRef(false);
  const readingModeRef = useRef(readingMode);
  // How far through the chapter, for the chrome's "· 62%". Not state: in the
  // strip it moves with the scroll, and as state every whole-percent step
  // re-rendered this reader and all of its chrome for one number. Only the
  // read-out subscribes (see `reading-percent.ts`, the novel reader's twin).
  const [percentStore] = useState(createReadingPercent);
  const [visiblePage, setVisiblePage] = useState(Math.max(1, initialPage));
  const [activeChapterKey, setActiveChapterKey] = useState(entryChapterKey);
  const [atTop, setAtTop] = useState(false);
  const [atBottom, setAtBottom] = useState(false);
  // The shortcuts sheet is app-wide (shell-owned) — the reader only needs to
  // know whether it is up, so Escape closes it before leaving the chapter.
  const helpOpen = useUiStore((state) => state.shortcutsOpen);
  const closeShortcuts = useUiStore((state) => state.closeShortcuts);
  const toggleShortcuts = useUiStore((state) => state.toggleShortcuts);

  /**
   * The chapter the chrome describes: the one whose pages the reader is on.
   *
   * In a strip that is not always the chapter the route named — crossing a seam
   * moves it without any navigation — so every per-chapter thing below (title,
   * page count, download control, progress, saved scroll) reads from here.
   */
  const activeIndex = chapterIndexOf(chapters, activeChapterKey);
  const chapter = activeIndex >= 0 ? chapters[activeIndex] : chapters[0];
  const entryChapter = useMemo(
    () => chapters.find((entry) => entry.chapterKey === entryChapterKey) ?? chapters[0],
    [chapters, entryChapterKey],
  );

  const pages = useMemo(() => chapter?.pages ?? [], [chapter]);
  const chapterTitle = chapter ? stripChapterLabel(chapter) : "Chapter";
  const continuous = readingMode === "continuous";

  const previousChapterHref =
    chapter?.previousChapterKey && chapter
      ? readerChapterHref({
          sourceId: chapter.sourceId,
          seriesKey: chapter.seriesKey,
          chapterKey: chapter.previousChapterKey,
        })
      : null;
  const nextChapterHref =
    chapter?.nextChapterKey && chapter
      ? readerChapterHref({
          sourceId: chapter.sourceId,
          seriesKey: chapter.seriesKey,
          chapterKey: chapter.nextChapterKey,
        })
      : null;
  const nextChapterLabel = chapter ? nextChapterLabelFor(chapter) : null;

  const activeChapterKeyRef = useRef(activeChapterKey);
  useEffect(() => {
    activeChapterKeyRef.current = activeChapterKey;
  }, [activeChapterKey]);

  // Follow the route when it names a different chapter (a Previous/Next link, a
  // deep link into a strip that is already mounted).
  const [routedEntry, setRoutedEntry] = useState(entryChapterKey);
  if (routedEntry !== entryChapterKey) {
    setRoutedEntry(entryChapterKey);
    setActiveChapterKey(entryChapterKey);
  }

  /**
   * Tap-zone customisation (reader settings §3). `tapZones` is `null` until a
   * reader explicitly customises it, and the two views disagree about what
   * "not customised" means: the paged stage has always turned pages from its
   * outer edges, while the continuous strip has always toggled the chrome
   * from anywhere (there is no single page under a thumb). Once customised,
   * the same explicit config applies to both — the strip simply gains
   * edge-tap page jumping if that is what the reader asked for.
   */
  const effectiveTapZones = useMemo(
    () => tapZones ?? (continuous ? TOGGLE_ONLY_TAP_ZONES : defaultTapZoneConfig(direction)),
    [tapZones, continuous, direction],
  );

  // Ambient mood tint, but only in the gutters beside the page column — the page
  // itself stays pure obsidian. `default` mood → "transparent" → no wash.
  const mood = useActiveProfileStore((state) => state.activeProfile?.mood ?? "default");
  const marginWash = moodReaderMargin(mood);
  const gutterBackground =
    marginWash === "transparent"
      ? undefined
      : `linear-gradient(90deg, ${marginWash} 0%, transparent calc((100% - 48rem) / 2), transparent calc(100% - (100% - 48rem) / 2), ${marginWash} 100%)`;

  const cinemaCtl = useCinema({
    persistedEnabled: cinema,
    scrollElement,
    active: Boolean(chapter) && !isLoading && !error,
    onEnabledChange: setCinema,
    // `atBottom` is only kept up to date by the strip's scroll.
    atEnd: continuous && atBottom,
    pagedPosition: continuous ? null : `${activeChapterKey}#${visiblePage}`,
  });

  // The chrome follows cinema mode while it is engaged; otherwise the store
  // value that a tap toggles and reading hides (see `useCinema`). Turning
  // cinema off always leaves the chrome up.
  const chromeVisible = cinemaCtl.chromeVisible;
  const toggleCinema = useCallback(() => {
    cinemaCtl.toggle();
    if (cinemaCtl.enabled) setControlsVisible(true);
  }, [cinemaCtl, setControlsVisible]);

  const autoScroll = useAutoScroll({
    scrollElement,
    active: continuous && Boolean(chapter) && !isLoading && !error,
    // Auto-scroll stops at the end of the STRIP, not at the end of a chapter:
    // in continuous mode the next chapter is already below, so the run
    // continues straight through the seam.
    atBottom,
    pxPerSecond: autoScrollPxPerSecond(autoScrollSpeed),
  });

  useEffect(() => {
    readingModeRef.current = readingMode;
  }, [readingMode]);

  const views = useMemo(
    () => buildPageViews(pages.length, readingMode),
    [pages.length, readingMode],
  );
  const viewIndex = useMemo(() => findViewIndex(views, visiblePage), [views, visiblePage]);
  const currentView = views[viewIndex];

  const entryPages = useMemo(() => entryChapter?.pages ?? [], [entryChapter]);

  /**
   * The bookmark this reader was opened from, resolved against what the entry
   * chapter actually holds (design §3).
   *
   * `null` unless the route carried a `?at=`, which only a bookmark link
   * produces — a plain `?page=` link keeps the existing "top of that page"
   * behaviour. `stale` means the source has since re-listed the chapter with
   * fewer pages than the bookmark recorded, in which case the nearest valid
   * page is used and the reader is told so, quietly, rather than being dropped
   * at the top of the chapter with no explanation.
   */
  const bookmarkTarget = useMemo(() => {
    if (initialAnchorFraction == null) return null;
    const resolved = resolveAnchor(
      { index: initialPage, fraction: initialAnchorFraction },
      entryPages.length,
    );
    return resolved;
  }, [entryPages.length, initialAnchorFraction, initialPage]);

  /**
   * Where the reader left the ENTRY chapter: a page, and how far into it.
   *
   * The route's own `?page=` wins when it names one — a link that says where to
   * go must go there — and otherwise the saved position stands. A bookmark
   * target outranks both: it names a page AND a fraction of it, and the pixel
   * offset that fraction works out to cannot be known until the page has been
   * measured, so it is carried separately and applied by the restore below.
   */
  const savedPosition = useMemo((): ReaderPosition | null => {
    if (!entryChapter) return null;
    if (bookmarkTarget) return { page: bookmarkTarget.index, offset: 0 };
    if (initialPage > 1) return { page: initialPage, offset: 0 };
    return readReaderPosition(chapterScrollKey(entryChapter));
  }, [bookmarkTarget, entryChapter, initialPage]);

  /**
   * Where the strip lands on its first paint, before anything is measured.
   *
   * An estimate on purpose: the exact landing is done through the strip's own
   * handle once it can answer where a page really starts (see the restore
   * below). This only has to be close enough that the reader does not watch
   * page one for a frame on the way to page nine.
   */
  const initialScrollTop = useMemo(() => {
    if (entryPages.length === 0) {
      return 0;
    }

    const containerWidth = resolveContainerWidth(scrollElement);
    const targetPage = Math.max(1, Math.min(savedPosition?.page ?? 1, entryPages.length));
    // A bookmark's offset is a FRACTION of the target page, which only becomes
    // a pixel count once something knows that page's height. Nothing has been
    // measured yet, so the estimate uses the estimated height — close enough
    // that the reader does not watch the top of the page on the way down to
    // where they were, and corrected exactly by the restore below.
    const within = bookmarkTarget
      ? bookmarkTarget.fraction *
        estimatePageHeight(entryPages[targetPage - 1], containerWidth, zoom)
      : (savedPosition?.offset ?? 0);
    return estimateResumeOffset({
      position: savedPosition && { page: targetPage, offset: within },
      pageCount: entryPages.length,
      estimatedOffsetToPage: estimateScrollOffsetToPage(
        entryPages,
        targetPage,
        containerWidth,
        zoom,
      ),
    });
  }, [bookmarkTarget, entryPages, savedPosition, scrollElement, zoom]);

  const stripScrollKey = entryChapter ? chapterScrollKey(entryChapter) : entryChapterKey;

  // Read by the strip's one-time restore, which runs from a callback rather
  // than from render — the handle arrives when the list mounts, not before.
  const savedPositionRef = useRef(savedPosition);
  useEffect(() => {
    savedPositionRef.current = savedPosition;
  }, [savedPosition]);

  const bookmarkTargetRef = useRef(bookmarkTarget);
  useEffect(() => {
    bookmarkTargetRef.current = bookmarkTarget;
  }, [bookmarkTarget]);

  /**
   * Where to resume the chapter being read, resolved at the moment the reader
   * leaves.
   *
   * A PAGE and a distance into it, not a raw scroll offset: the strip holds
   * several chapters, and a pixel count from the top of it means something
   * different every time a chapter is prepended or an estimate settles. Anchored
   * to a page, the worst a drifted estimate can do is land a little high or low
   * inside the right page. A paged mode has no scroll of its own, so it reports
   * its current page with no offset at all.
   */
  const scrollAnchorRef = useRef<() => { key: string; position: ReaderPosition } | null>(
    () => null,
  );
  useEffect(() => {
    scrollAnchorRef.current = () => {
      if (!scrollElement || !chapter || pages.length === 0) return null;
      const key = chapterScrollKey(chapter);
      if (readingModeRef.current !== "continuous") {
        return { key, position: { page: visiblePage, offset: 0 } };
      }
      const start = stripHandleRef.current?.pageStart(chapter.chapterKey, visiblePage);
      return {
        key,
        position: {
          page: visiblePage,
          offset: start == null ? 0 : scrollElement.scrollTop - start,
        },
      };
    };
  }, [chapter, pages.length, scrollElement, visiblePage]);

  useEffect(() => {
    return () => {
      if (scrollSaveTimerRef.current) {
        clearTimeout(scrollSaveTimerRef.current);
        scrollSaveTimerRef.current = null;
      }
      const anchor = scrollAnchorRef.current();
      if (anchor != null) {
        writeReaderPosition(anchor.key, anchor.position);
      }
      clearChapterScrollPreparation(stripScrollKey);
    };
  }, [scrollElement, stripScrollKey]);

  useEffect(() => {
    readerDebug("route-entered", {
      entryChapterKey,
      initialPage,
      isLoading,
      chapters: chapters.length,
    });
  }, [entryChapterKey, initialPage, isLoading, chapters.length]);

  useEffect(() => {
    if (isLoading) {
      readerDebug("loading-state", { entryChapterKey, reason: "chapter-pending" });
    }
  }, [isLoading, entryChapterKey]);

  useEffect(() => {
    if (!chapter) return;
    readerDebug("chapter-render-ready", {
      chapterKey: chapter.chapterKey,
      pagesLength: pages.length,
      title: chapter.title,
    });
  }, [chapter, pages.length]);

  const handleImagesReady = useCallback(() => {
    readerDebug("reader-ready", {
      entryChapterKey,
      pageCount: pages.length,
      scrollReady: Boolean(scrollElement),
    });
  }, [entryChapterKey, pages.length, scrollElement]);

  /**
   * The strip's report, on every scroll frame: which chapter, which page.
   *
   * This is where a seam crossing actually happens — no navigation, no remount,
   * just the row under the reading line belonging to a different chapter than
   * the row above it. Progress goes to the parent with the chapter attached, so
   * pages either side of the boundary are recorded against the right one.
   */
  const handleStripPosition = useCallback(
    (position: StripPosition) => {
      setActiveChapterKey(position.chapterKey);
      setVisiblePage(position.pageNumber);
      onPosition?.(position);
    },
    [onPosition],
  );

  /**
   * The paged modes' report: one per screen, through the same `onPosition`.
   *
   * They render no strip, so without this nothing reported a page at all and
   * a series read in Single or Double mode was never saved. An effect rather
   * than a call in `goToPage` so the opening screen and a switch in from the
   * strip report too; the helper returns `null` in continuous mode, where the
   * strip already reports every frame.
   */
  const pagedPosition = pagedProgressPosition(
    readingMode,
    chapter?.chapterKey,
    currentView,
    pages.length,
  );
  const pagedChapterKey = pagedPosition?.chapterKey;
  const pagedPageNumber = pagedPosition?.pageNumber;
  const pagedPageCount = pagedPosition?.pageCount;
  useEffect(() => {
    if (pagedChapterKey == null || pagedPageNumber == null || pagedPageCount == null) return;
    onPosition?.({
      chapterKey: pagedChapterKey,
      pageNumber: pagedPageNumber,
      pageCount: pagedPageCount,
    });
  }, [onPosition, pagedChapterKey, pagedPageCount, pagedPageNumber]);

  const registerStripHandle = useCallback(
    (handle: StripHandle | null) => {
      stripHandleRef.current = handle;
      if (!handle) return;

      // A pending target means the strip was just re-entered from a paged mode.
      // Consume it on the first registration — the list has mounted and its own
      // restore has already run, so this is the last word on where to land.
      const pending = pendingScrollPageRef.current;
      if (pending != null) {
        pendingScrollPageRef.current = null;
        handle.scrollToPosition(activeChapterKeyRef.current, pending);
        return;
      }

      // The exact landing for a resumed chapter, done once and only through the
      // strip: it is the only thing that knows where a page really begins.
      if (restoreDoneRef.current) return;
      restoreDoneRef.current = true;

      // A bookmark lands on the exact position, not the chapter start and not
      // the top of the bookmarked page: the fraction is turned into pixels
      // against the page's MEASURED extent, and the reading line is put back
      // where it was — the exact inverse of `captureAnchor` below, so a
      // capture and a restore with nothing changed in between agree to the
      // pixel.
      const target = bookmarkTargetRef.current;
      if (target) {
        const extent = handle.pageExtent(entryChapterKey, target.index);
        const offset = extent
          ? Math.round(
              pointWithin(target.fraction, extent.start, extent.end) -
                extent.start -
                READING_LINE_PX,
            )
          : 0;
        handle.scrollToPosition(entryChapterKey, target.index, Math.max(0, offset));
        return;
      }

      const saved = savedPositionRef.current;
      if (!saved || (saved.page <= 1 && saved.offset <= 0)) return;
      handle.scrollToPosition(entryChapterKey, saved.page, saved.offset);
    },
    [entryChapterKey],
  );

  const updateScrollState = useCallback(() => {
    if (!scrollElement || chapters.length === 0) return;
    if (readingModeRef.current !== "continuous") return;

    const { scrollTop, scrollHeight, clientHeight } = scrollElement;
    // Progress is per CHAPTER, not per strip: "62%" has to mean 62% of what
    // the chrome says you are reading, whatever else is loaded around it.
    const range = stripHandleRef.current?.chapterRange(activeChapterKey);
    if (range && range.end > range.start) {
      const span = Math.max(1, range.end - range.start - clientHeight);
      const ratio = (scrollTop - range.start) / span;
      percentStore.set(Math.min(1, Math.max(0, ratio)) * 100);
    } else {
      const maxScroll = Math.max(scrollHeight - clientHeight, 0);
      percentStore.set(maxScroll > 0 ? (scrollTop / maxScroll) * 100 : 100);
    }
    setAtTop(scrollTop <= SCROLL_EDGE_THRESHOLD);
    setAtBottom(scrollTop + clientHeight >= scrollHeight - SCROLL_EDGE_THRESHOLD);

    if (scrollSaveTimerRef.current) {
      clearTimeout(scrollSaveTimerRef.current);
    }
    scrollSaveTimerRef.current = window.setTimeout(() => {
      const anchor = scrollAnchorRef.current();
      if (anchor) writeReaderPosition(anchor.key, anchor.position);
      scrollSaveTimerRef.current = null;
    }, SCROLL_SAVE_MS);
    // Re-made whenever the active chapter changes OR the strip does, so the
    // listener effect below re-attaches and recomputes at once. Both move the
    // ground this reads: crossing a seam changes which chapter's range the
    // percentage is against, and pulling a chapter onto the head moves every
    // range in the strip. Either, followed by STOPPING, would otherwise leave a
    // stale read-out with no further scroll to correct it.
  }, [activeChapterKey, chapters, percentStore, scrollElement]);

  // The paged modes have no scroll, so their percent is the page's place in
  // the chapter. A layout effect, so a page turn and its new percent reach
  // the screen in the same frame.
  const pagedPercent = continuous ? null : scrubPercent(visiblePage, pages.length);
  useLayoutEffect(() => {
    if (pagedPercent != null) percentStore.set(pagedPercent);
  }, [pagedPercent, percentStore]);

  useEffect(() => {
    if (!scrollElement) return;

    let frame = 0;
    const handleScroll = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(updateScrollState);
    };

    handleScroll();
    scrollElement.addEventListener("scroll", handleScroll, { passive: true });
    return () => {
      scrollElement.removeEventListener("scroll", handleScroll);
      cancelAnimationFrame(frame);
    };
  }, [scrollElement, updateScrollState]);

  /**
   * The strip's opening position, applied once.
   *
   * Only while the entry chapter is still the strip's FIRST chapter: a saved
   * offset is relative to its own chapter's start, which is zero exactly until
   * something is prepended above it. After that this number means a different
   * place, and re-applying it (a zoom change recomputes it) would throw the
   * reader somewhere they never were.
   */
  const stripAnchored = chapters[0]?.chapterKey === entryChapterKey;
  useLayoutEffect(() => {
    if (isLoading || error || !chapter || entryPages.length === 0 || !scrollElement) {
      return;
    }
    if (!stripAnchored) return;
    syncChapterScroll(stripScrollKey, scrollElement, initialScrollTop);
  }, [
    chapter,
    entryPages.length,
    error,
    initialScrollTop,
    isLoading,
    scrollElement,
    stripAnchored,
    stripScrollKey,
  ]);

  /** A chapter already in the strip is a scroll away; anything else is a route. */
  const jumpToChapter = useCallback(
    (chapterKey: string | null, href: string | null, page: number) => {
      if (!chapterKey) return;
      const handle = stripHandleRef.current;
      if (continuous && handle && chapterIndexOf(chapters, chapterKey) >= 0) {
        handle.scrollToPosition(chapterKey, page);
        return;
      }
      if (href) router.push(href);
    },
    [chapters, continuous, router],
  );

  const goPreviousChapter = useCallback(() => {
    const previousKey = chapter?.previousChapterKey ?? null;
    // "Last page" is only knowable for a chapter already loaded; a route jump
    // lands on page one, which is what it has always done.
    const loaded = previousKey ? chapters[chapterIndexOf(chapters, previousKey)] : undefined;
    jumpToChapter(previousKey, previousChapterHref, loaded ? loaded.pages.length : 1);
  }, [chapter, chapters, jumpToChapter, previousChapterHref]);

  const goNextChapter = useCallback(() => {
    jumpToChapter(chapter?.nextChapterKey ?? null, nextChapterHref, 1);
  }, [chapter, jumpToChapter, nextChapterHref]);

  const goToPage = useCallback(
    (pageNumber: number) => {
      if (pages.length === 0 || !chapter) return;
      const target = Math.min(pages.length, Math.max(1, Math.round(pageNumber)));
      setVisiblePage(target);

      if (readingMode !== "continuous") return;

      // The virtualizer knows the measured page heights; the estimator is only
      // the fallback for the frame before it has published its jump.
      const handle = stripHandleRef.current;
      if (handle) {
        handle.scrollToPosition(chapter.chapterKey, target);
      } else {
        setReaderScrollTop(
          scrollElement,
          estimateScrollOffsetToPage(
            pages,
            target,
            resolveContainerWidth(scrollElement),
            zoom,
          ),
        );
      }
    },
    [chapter, pages, readingMode, scrollElement, zoom],
  );

  const turnPage = useCallback(
    (turn: PageTurn) => {
      if (pages.length === 0) return;
      const step = turn === "advance" ? 1 : -1;

      if (readingMode === "continuous") {
        const target = visiblePage + step;
        // The strip has no hard edge any more: a turn off the end of a chapter
        // continues into the neighbour that is already sitting under it.
        if (target < 1) {
          goPreviousChapter();
          return;
        }
        if (target > pages.length) {
          goNextChapter();
          return;
        }
        goToPage(target);
        return;
      }

      // Paged modes have a hard edge, so a turn past it continues into the
      // neighbouring chapter — the payload is already warm by then.
      const nextIndex = viewIndex + step;
      if (nextIndex < 0) {
        goPreviousChapter();
        return;
      }
      if (nextIndex >= views.length) {
        goNextChapter();
        return;
      }
      goToPage(viewLeadPage(views[nextIndex]));
    },
    [
      goNextChapter,
      goPreviousChapter,
      goToPage,
      pages.length,
      readingMode,
      viewIndex,
      views,
      visiblePage,
    ],
  );

  const scrollScreen = useCallback(
    (turn: PageTurn) => {
      if (readingMode !== "continuous") {
        turnPage(turn);
        return;
      }
      if (!scrollElement) return;
      const delta = Math.max(160, scrollElement.clientHeight * SCREEN_SCROLL_RATIO);
      scrollReaderBy(scrollElement, turn === "advance" ? delta : -delta);
    },
    [readingMode, scrollElement, turnPage],
  );

  const handleTap = useCallback(
    (zone: TapZone) => {
      // A tap always hands control back from auto-scroll, even a plain toggle
      // tap that never moves the scroll position (and so would otherwise slip
      // past the scroll-diff pause detection in `useAutoScroll`).
      autoScroll.pause();
      if (zone === "toggle") {
        // In cinema mode a tap reveals the chrome (and re-arms the idle timer)
        // rather than latching it on/off — the timeout owns hiding it again.
        if (cinemaCtl.enabled) cinemaCtl.notifyActivity();
        else toggleControls();
        return;
      }
      turnPage(zone);
    },
    [autoScroll, cinemaCtl, toggleControls, turnPage],
  );

  /**
   * The exact spot being read, in one action (design §5).
   *
   * The fraction is measured at the SAME reading line that chose
   * `visiblePage`, against that page's measured extent — so the pair is always
   * self-consistent, and restoring it is `pointWithin` run backwards.
   *
   * A paged mode reports 0.0 and means it: the stage shows one page fitted to
   * the viewport with no scroll of its own, so "how far down the page" has
   * exactly one honest answer there. That is also why the strip is the only
   * thing asked — it is the only view with a scroll position inside a page.
   */
  const captureAnchor = useCallback((): CapturedAnchor => {
    const total = pages.length;
    if (!continuous || !scrollElement || !chapter) {
      return { index: visiblePage, fraction: 0, total };
    }
    const extent = stripHandleRef.current?.pageExtent(chapter.chapterKey, visiblePage);
    const fraction = extent
      ? fractionWithin(scrollElement.scrollTop + READING_LINE_PX, extent.start, extent.end)
      : 0;
    return { index: visiblePage, fraction, total };
  }, [chapter, continuous, pages.length, scrollElement, visiblePage]);

  const handleBookmark = useCallback(() => {
    if (!showBookmark || !onBookmark) return;
    onBookmark(captureAnchor());
  }, [captureAnchor, onBookmark, showBookmark]);

  /**
   * "Say so quietly" (design §3): the chapter lost pages since this bookmark
   * was made, so it opened at the nearest page that still exists. Timed rather
   * than dismissible — it is an explanation for where the reader landed, and
   * it stops being useful the moment they start reading.
   */
  const anchorMoved = bookmarkTarget?.stale ?? false;
  // Derived, not mirrored into state: the effect only ever ARMS the timeout,
  // and the timeout's setState is asynchronous. Setting a "visible" flag from
  // the effect body instead would be a synchronous setState inside an effect —
  // a cascading render, and the one thing `react-hooks/set-state-in-effect`
  // exists to stop.
  const [movedNoticeDismissed, setMovedNoticeDismissed] = useState(false);
  useEffect(() => {
    if (!anchorMoved) return;
    const timer = window.setTimeout(
      () => setMovedNoticeDismissed(true),
      MOVED_NOTICE_MS,
    );
    return () => window.clearTimeout(timer);
  }, [anchorMoved]);
  const movedNoticeVisible = anchorMoved && !movedNoticeDismissed;

  const bookmarkNotice = bookmarkFailed
    ? { tone: "failed" as const, text: "Couldn't save that spot." }
    : bookmarkSaved
      ? { tone: "saved" as const, text: "Saved this spot." }
      : movedNoticeVisible
        ? {
            tone: "moved" as const,
            text: "That page is gone from this chapter — opened at the nearest one.",
          }
        : null;

  const zoomIn = useCallback(
    () => updatePreferences({ zoom: zoomBy(zoom, 1) }),
    [updatePreferences, zoom],
  );
  const zoomOut = useCallback(
    () => updatePreferences({ zoom: zoomBy(zoom, -1) }),
    [updatePreferences, zoom],
  );
  const resetZoom = useCallback(() => updatePreferences({ zoom: 1 }), [updatePreferences]);
  const zoomSteps = useCallback(
    (steps: number) => updatePreferences({ zoom: zoomBy(zoom, steps) }),
    [updatePreferences, zoom],
  );

  /**
   * Switching back to the strip lands on the page that was on screen instead of
   * wherever the strip happened to be left. The target is queued rather than
   * applied here: the list has not mounted yet, and it hands back a jump that
   * uses measured page heights as soon as it has.
   */
  const changeReadingMode = useCallback(
    (mode: ReadingMode) => {
      if (mode === readingMode) return;
      if (mode === "continuous" && pages.length > 0) {
        pendingScrollPageRef.current = visiblePage;
        // The edge prompts are driven by scroll state the paged modes never
        // update; clear them so a stale flag cannot greet the returning strip.
        setAtTop(false);
        setAtBottom(false);
      }
      updatePreferences({ readingMode: mode });
    },
    [pages.length, readingMode, updatePreferences, visiblePage],
  );

  // Same wheel contract as the paged stage: ctrl/⌘+wheel zooms, a plain wheel
  // scrolls.
  //
  // PASSIVE by default, which is the whole point. `scrollElement` is <main> —
  // the app's only scroller — and a scroll-blocking wheel listener on the
  // scroll target means the browser cannot apply a wheel scroll on the
  // compositor thread at all: every tick has to reach the main thread and wait
  // for this handler to return. The handler is cheap, but the round trip is
  // not, so any frame busy with an image decode or a React commit delayed the
  // scroll ITSELF. That is the "input is a beat behind" feel rather than
  // dropped frames, and it cost every wheel gesture in the strip to keep a
  // preventDefault available for the rare zoom.
  //
  // So: the passive listener does the zoom and also ARMS a second, non-passive
  // one the moment it sees a modifier. A mouse-wheel zoom arms on the
  // Control/Meta keydown before the first tick; a trackpad pinch synthesises
  // ctrlKey with no keydown, so it arms on the first tick and loses only that
  // one to the browser's own zoom. A key-armed zoom disarms when the modifier
  // lifts; a pinch, which has no keyup, when it goes idle. The arming itself
  // lives in `installWheelZoomArming`, where it is tested.
  useEffect(() => {
    if (!scrollElement || !continuous) return;
    return installWheelZoomArming({
      scroller: scrollElement,
      keys: window,
      zoom: (event) => {
        const steps = wheelZoomSteps(event);
        if (steps !== 0) zoomSteps(steps);
        return steps !== 0;
      },
    });
  }, [continuous, scrollElement, zoomSteps]);

  /**
   * Keep scrolling UP at the top of the strip and the chapter before it is
   * pulled onto the head — the mirror of the gesture that used to drop into the
   * next chapter at the bottom.
   *
   * Deliberately a sustained overscroll rather than "you touched the top":
   * every chapter opens at scroll zero, so an automatic pull would fetch the
   * previous chapter for every reader who never intended to go backwards.
   */
  const loadPreviousRef = useRef(onLoadPrevious);
  useEffect(() => {
    loadPreviousRef.current = onLoadPrevious;
  }, [onLoadPrevious]);
  useEffect(() => {
    if (!scrollElement || !continuous || !atTop || !onLoadPrevious) return;
    let overscroll = 0;
    let resetTimer: number | null = null;
    const handleWheel = (event: WheelEvent) => {
      if (event.ctrlKey || event.metaKey || event.deltaY >= 0) return;
      overscroll -= event.deltaY;
      if (resetTimer) window.clearTimeout(resetTimer);
      resetTimer = window.setTimeout(() => {
        overscroll = 0;
      }, 320);
      if (overscroll >= OVERSCROLL_TRIGGER) {
        overscroll = 0;
        loadPreviousRef.current?.();
      }
    };
    scrollElement.addEventListener("wheel", handleWheel, { passive: true });
    return () => {
      scrollElement.removeEventListener("wheel", handleWheel);
      if (resetTimer) window.clearTimeout(resetTimer);
    };
  }, [scrollElement, continuous, atTop, onLoadPrevious]);

  const handleEscape = useCallback(() => {
    switch (resolveEscapeTarget({ helpOpen, fullscreen: fullscreen.active })) {
      case "help":
        closeShortcuts();
        return;
      case "fullscreen":
        fullscreen.exit();
        return;
      default:
        // Peel cinema mode before leaving the reader, so Escape doesn't drop
        // the reader and the immersive chrome in one press.
        if (cinemaCtl.enabled) {
          toggleCinema();
          return;
        }
        router.push(seriesHref);
    }
  }, [
    cinemaCtl.enabled,
    closeShortcuts,
    fullscreen,
    helpOpen,
    router,
    seriesHref,
    toggleCinema,
  ]);

  /**
   * Leave the chapter for its series page.
   *
   * Fullscreen belongs to the document, not to the reader, so it survives a
   * client-side navigation: without dropping it first the chapter list would
   * open in a fullscreened window with no browser chrome to get out of.
   */
  const openSeries = useCallback(() => {
    fullscreen.exit();
    router.push(seriesHref);
  }, [fullscreen, router, seriesHref]);

  useReaderShortcuts({
    direction,
    onTurnPage: turnPage,
    onScrollScreen: scrollScreen,
    onFirstPage: () => goToPage(1),
    onLastPage: () => goToPage(pages.length),
    onToggleFullscreen: fullscreen.toggle,
    onToggleCinema: toggleCinema,
    // A no-op outside continuous mode — auto-scroll only ever drives the strip.
    onToggleAutoScroll: () => {
      if (continuous) autoScroll.toggle();
    },
    onEscape: handleEscape,
    onPreviousChapter: goPreviousChapter,
    onNextChapter: goNextChapter,
    onOpenSeries: openSeries,
    onBookmark: handleBookmark,
    onZoomIn: zoomIn,
    onZoomOut: zoomOut,
    onZoomReset: resetZoom,
  });

  // The strip pulls the next chapter itself and warms images straight across
  // the seam, so this is only for the paged modes, where there is no strip.
  useChapterPreload({
    chapterKey: activeChapterKey,
    page: visiblePage,
    pageCount: pages.length,
    hasNextChapter:
      !continuous && chapter?.nextChapterKey != null && preloadNextChapter != null,
    loadNextChapter: preloadNextChapter ?? NO_PRELOAD,
  });

  if (isLoading || !preferencesReady) {
    return (
      <div
        className="flex min-h-[60vh] flex-col items-center justify-center gap-4 bg-bg p-6"
        aria-busy="true"
        aria-label="Loading chapter"
      >
        <div className="w-full max-w-3xl space-y-3">
          {Array.from({ length: 3 }).map((_, index) => (
            <div
              key={index}
              className="mx-auto aspect-[2/3] w-full max-w-md animate-pulse rounded-lg bg-white/5"
            />
          ))}
        </div>
        <p className="text-sm text-muted">Loading chapter…</p>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex min-h-[60vh] flex-col items-center justify-center gap-3 bg-bg p-6 text-center">
        <p className="text-danger">{error}</p>
        <div className="flex items-center gap-2">
          {onRetry ? (
            <button
              type="button"
              onClick={onRetry}
              className="inline-flex h-10 items-center justify-center rounded-lg bg-primary px-4 text-sm font-medium text-primary-fg transition-colors hover:bg-primary-hover"
            >
              Try again
            </button>
          ) : null}
          <Link
            href={seriesHref}
            className="inline-flex h-10 items-center justify-center rounded-lg border border-border/60 px-4 text-sm font-medium text-fg transition-colors hover:bg-white/5"
          >
            Go to series
          </Link>
        </div>
      </div>
    );
  }

  if (!chapter || pages.length === 0) {
    return (
      <div className="flex min-h-[60vh] items-center justify-center bg-bg text-muted">
        This chapter has no pages.
      </div>
    );
  }

  return (
    <div
      className={cn(
        "relative flex flex-col bg-bg",
        continuous ? "min-h-full scroll-smooth" : "h-full overflow-hidden",
      )}
      style={gutterBackground ? { background: gutterBackground } : undefined}
      // The paged view owns its own clicks (edge zones turn the page), so the
      // tap-anywhere-by-default toggle is wired only for the strip. Goes
      // through the same `resolveTapZone` + `handleTap` as the paged stage,
      // so a customised tap-zone config applies here too.
      onClick={
        continuous
          ? (event) => {
              const rect = event.currentTarget.getBoundingClientRect();
              handleTap(resolveTapZone(event.clientX, rect, effectiveTapZones));
            }
          : undefined
      }
      role="presentation"
    >
      {/* Night-reading dimmer + warmth overlays. Pure CSS opacity over the
          pages, `pointer-events-none` so they never intercept a tap or the
          scrub bar, and z-10 keeps them beneath every piece of chrome
          (including the page counter) so the controls stay reachable no
          matter how far either slider is pushed. Persist per profile; see
          `reader-settings.ts`. */}
      {dimmer > 0 ? (
        <div
          aria-hidden
          className="pointer-events-none fixed inset-0 z-10 bg-bg"
          style={{ opacity: dimmer }}
        />
      ) : null}
      {warmth > 0 ? (
        <div
          aria-hidden
          // A flat wash, NOT mix-blend-multiply. A blend mode over a
          // viewport-sized fixed layer forces the whole stacking context
          // beneath it to stay readable as a backdrop and re-blends the entire
          // viewport on every frame the backdrop moves — which, during a
          // scroll, is every frame. It also defeats opaque-overlap culling.
          // The dimmer directly above composites normally for the same reason.
          // Warmth is a low-opacity tint either way; the wash reads the same.
          className="pointer-events-none fixed inset-0 z-10 bg-primary"
          style={{ opacity: warmth * 0.55 }}
        />
      ) : null}

      {/*
        Saves this chapter's pages to the device, using the very URLs resolved
        above — the reader's own page loading is untouched, the service worker
        just answers those requests from the cache when the network is gone.
      */}
      {/* `data-reader-chrome` here and on the controls below: resting the
          pointer or keyboard focus in either holds the chrome up, and focus
          arriving in either brings it back (`chrome-autohide.ts`). */}
      <div onClick={(event) => event.stopPropagation()} role="presentation" data-reader-chrome="">
        <DownloadChapterControl
          chapter={chapter}
          visiblePage={visiblePage}
          visible={chromeVisible}
        />
      </div>

      <div
        className={cn(
          "pointer-events-none fixed left-1/2 top-4 z-20 -translate-x-1/2",
          cinemaCtl.reducedMotion ? "" : "transition-opacity duration-300",
          // Cinema mode hides even this: revealed activity brings the full
          // control bar (which carries the page count) back instead.
          !chromeVisible && !cinemaCtl.enabled ? "opacity-100" : "opacity-0",
        )}
      >
        {/* Flat glass: this pill stays up for the whole read with the page
            strip moving under it, and a backdrop blur there is re-sampled on
            every scroll frame. Without the blur the count needs a denser fill
            to stay legible over a white page: the preset's own panel fill
            mixed into the surface colour, about 90% opaque where the fill is
            glass and unchanged where it is already solid. `!` because the
            glass rule is unlayered and would otherwise win. */}
        <div className="glass-panel glass-flat rounded-full bg-[color-mix(in_srgb,var(--shape-panel-fill)_35%,var(--color-surface))]! px-4 py-1.5 font-mono text-xs tabular-nums text-primary">
          {visiblePage} <span className="text-muted">/ {pages.length}</span>
        </div>
      </div>

      {continuous ? (
        <div className="flex-1 py-4 pb-28">
          <StripHead
            label={head.label}
            href={
              head.chapterKey
                ? readerChapterHref({
                    sourceId: chapter.sourceId,
                    seriesKey: chapter.seriesKey,
                    chapterKey: head.chapterKey,
                  })
                : null
            }
            visible={atTop && Boolean(head.chapterKey)}
            loading={loadingPrevious}
            onLoad={onLoadPrevious}
          />
          {scrollElement ? (
            <ContinuousStrip
              key={stripScrollKey}
              chapters={chapters}
              zoom={zoom}
              pageGap={pageGap}
              scrollElement={scrollElement}
              initialScrollTop={initialScrollTop}
              onPositionChange={handleStripPosition}
              onImagesReady={handleImagesReady}
              onHandleReady={registerStripHandle}
            />
          ) : null}
          <StripTail
            hasMore={Boolean(tail.chapterKey)}
            error={nextError}
            onRetry={onRetryNext}
            label={tail.label}
            href={
              tail.chapterKey
                ? readerChapterHref({
                    sourceId: chapter.sourceId,
                    seriesKey: chapter.seriesKey,
                    chapterKey: tail.chapterKey,
                  })
                : null
            }
          />
        </div>
      ) : (
        <PagedView
          pages={pages}
          chapterTitle={chapterTitle}
          view={currentView ?? FIRST_PAGE_VIEW}
          slotsPerView={readingMode === "double" ? 2 : 1}
          direction={direction}
          fitMode={effectiveFitMode(fitMode, readingMode)}
          zoom={zoom}
          tapZoneConfig={effectiveTapZones}
          onTap={handleTap}
          onZoom={zoomSteps}
          pageTransition={pageTransition}
        />
      )}

      <div onClick={(event) => event.stopPropagation()} role="presentation" data-reader-chrome="">
        <ReaderControls
          chapterTitle={chapterTitle}
          chapterPosition={chapterPosition}
          progress={percentStore}
          visiblePage={visiblePage}
          pageCount={pages.length}
          zoom={zoom}
          onZoomIn={zoomIn}
          onZoomOut={zoomOut}
          onZoomReset={resetZoom}
          readingMode={readingMode}
          onReadingModeChange={changeReadingMode}
          readingModeLocked={continuousOnly}
          fitMode={fitMode}
          onFitModeChange={(mode) => updatePreferences({ fitMode: mode })}
          direction={direction}
          onDirectionChange={(next) => updatePreferences({ direction: next })}
          onSeekPage={goToPage}
          fullscreen={fullscreen.active}
          fullscreenSupported={fullscreen.supported}
          onToggleFullscreen={fullscreen.toggle}
          onShowShortcuts={toggleShortcuts}
          pageGap={pageGap}
          onTogglePageGap={continuous ? togglePageGap : undefined}
          cinema={cinemaCtl.enabled}
          onToggleCinema={toggleCinema}
          pageTransition={pageTransition}
          onTogglePageTransition={!continuous ? togglePageTransition : undefined}
          autoScrollAvailable={continuous}
          autoScrollPlaying={autoScroll.playing}
          onToggleAutoScroll={autoScroll.toggle}
          autoScrollSpeed={autoScrollSpeed}
          onAutoScrollSpeedChange={(speed) => updatePreferences({ autoScrollSpeed: speed })}
          autoScrollReducedMotion={autoScroll.reducedMotion}
          dimmer={dimmer}
          onDimmerChange={setDimmer}
          warmth={warmth}
          onWarmthChange={setWarmth}
          tapZones={effectiveTapZones}
          onTapZonesChange={setTapZones}
          onBookmark={onBookmark ? handleBookmark : undefined}
          previousChapterHref={previousChapterHref}
          nextChapterHref={nextChapterHref}
          nextChapterLabel={nextChapterLabel}
          seriesHref={seriesHref}
          onOpenSeries={openSeries}
          onPreviousChapter={goPreviousChapter}
          onNextChapter={goNextChapter}
          bookmarkPending={bookmarkPending}
          showBookmark={showBookmark}
          visible={chromeVisible}
        />
      </div>

      {bookmarkNotice ? (
        <BookmarkNotice tone={bookmarkNotice.tone}>{bookmarkNotice.text}</BookmarkNotice>
      ) : null}
    </div>
  );
}
