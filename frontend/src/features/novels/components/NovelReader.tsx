"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import {
  BOOKMARK_MEDIA_NOVEL,
  useBookmarkCapture,
} from "@/features/bookmarks";
import { useSaveProgress } from "@/features/reader/hooks";
import { useReadingClock } from "@/features/reader/reading-clock";
import { seriesPageHref } from "@/features/reader/reader-link";
import { setReaderScrollTop } from "@/features/reader/scroll-preparation";
import { useSourceSeriesDetail } from "@/features/sources/hooks";
import { useScrollContainer } from "@/lib/scroll-container";
import type { ChapterId } from "@/types/api";
import { toNovelChapter } from "../api";
import { prefetchNovelChapter, useNovelChapter } from "../hooks";
import { novelChapterHref, novelContentsHref } from "../novel-link";
import { novelSeriesKey } from "../preferences";
import type { ParagraphAnchor } from "../paragraph-anchor";
import { nextProgressPush, type NovelProgressPosition } from "../progress";
import { NovelChapterView } from "./NovelChapterView";

interface NovelReaderProps {
  sourceId: string;
  seriesKey: string;
  chapterKey: string;
  /** The progress BUCKET to resume at — `?page=` carries it, see `progress.ts`. */
  initialPage?: number;
  /**
   * A bookmark's exact spot: 1-based PARAGRAPH plus a fraction within it, off
   * `?para=&at=`. A paragraph is not a bucket, so it gets its own parameter —
   * see `features/bookmarks/anchor.ts`.
   *
   * Two primitives rather than one object because they are compared during
   * render to decide whether the route moved, and a fresh object literal from
   * the page component would compare unequal to itself every time.
   */
  initialParagraph?: number | null;
  initialAnchorFraction?: number | null;
}

const PROGRESS_SAVE_MS = 500;

/**
 * The novel reader, route level.
 *
 * The same division of labour as the manga reader's `SourceReader`: this owns
 * the chapter identity, the progress writes and the seamless transition;
 * `NovelChapterView` owns the page. Keeping the split identical is what lets
 * the two readers share a mental model (and, in the seamless case, literally
 * the same mechanism) while sharing no rendering at all.
 */
export function NovelReader({
  sourceId,
  seriesKey,
  chapterKey,
  initialPage = 1,
  initialParagraph = null,
  initialAnchorFraction = null,
}: NovelReaderProps) {
  const routedAnchor = useMemo(
    () =>
      initialParagraph != null && initialParagraph >= 1
        ? { index: initialParagraph, fraction: initialAnchorFraction ?? 0 }
        : null,
    [initialAnchorFraction, initialParagraph],
  );
  const queryClient = useQueryClient();
  const scrollElement = useScrollContainer();

  // The chapter actually on screen. Starts at the routed key; a seamless
  // transition advances it without a navigation.
  const [activeChapterKey, setActiveChapterKey] = useState(chapterKey);
  const [resumeBucket, setResumeBucket] = useState(initialPage);
  // Cleared on a seamless advance: chapter 41 does not open at chapter 40's
  // bookmarked paragraph.
  const [resumeAnchor, setResumeAnchor] = useState(routedAnchor);

  // A real navigation normally remounts via the page's `key`, but follow the
  // props during render anyway if they change under us — React's accepted
  // "reset state on prop change" pattern, matching `SourceReader`.
  const [routed, setRouted] = useState({
    chapterKey,
    initialPage,
    initialParagraph,
    initialAnchorFraction,
  });
  if (
    routed.chapterKey !== chapterKey ||
    routed.initialPage !== initialPage ||
    routed.initialParagraph !== initialParagraph ||
    routed.initialAnchorFraction !== initialAnchorFraction
  ) {
    setRouted({ chapterKey, initialPage, initialParagraph, initialAnchorFraction });
    setActiveChapterKey(chapterKey);
    setResumeBucket(initialPage);
    setResumeAnchor(routedAnchor);
  }

  const ref: ChapterId = { sourceId, seriesKey, chapterKey: activeChapterKey };
  const chapterQuery = useNovelChapter(ref);
  const seriesQuery = useSourceSeriesDetail(sourceId, seriesKey);
  const saveProgress = useSaveProgress();
  // How long since this reader's last push — what the server turns into a
  // session's duration. See `reading-clock.ts`.
  const takeElapsed = useReadingClock();
  const bookmark = useBookmarkCapture();

  const chapter = useMemo(
    () => (chapterQuery.data ? toNovelChapter(chapterQuery.data) : undefined),
    [chapterQuery.data],
  );

  const progressTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  /** Furthest bucket already reported for THIS chapter — never rewound. */
  const furthestSent = useRef(0);

  const nextChapterKey = chapter?.nextChapterKey ?? null;

  const previousChapterHref = chapter?.previousChapterKey
    ? novelChapterHref({
        sourceId,
        seriesKey,
        chapterKey: chapter.previousChapterKey,
      })
    : null;
  const nextChapterHref = nextChapterKey
    ? novelChapterHref({ sourceId, seriesKey, chapterKey: nextChapterKey })
    : null;

  // The payload carries the next chapter's KEY but not its number, so the label
  // is inferred exactly as the manga reader infers it: only from a whole
  // chapter number, because decimal and split chapters make the guess wrong.
  const nextChapterLabel = nextChapterKey
    ? chapter?.chapterNumber != null && Number.isInteger(chapter.chapterNumber)
      ? `Chapter ${chapter.chapterNumber + 1}`
      : "Next chapter"
    : null;

  // Keep the next chapter warm as soon as this one resolves, so the end card's
  // "already there" promise holds even for a short chapter read straight
  // through. Chapter text is a single small JSON payload — there is no page
  // list to walk, so warming the query is the whole preload.
  useEffect(() => {
    if (!nextChapterKey) return;
    prefetchNovelChapter(queryClient, {
      sourceId,
      seriesKey,
      chapterKey: nextChapterKey,
    });
  }, [nextChapterKey, queryClient, seriesKey, sourceId]);

  const persistProgress = useCallback(
    (position: NovelProgressPosition) => {
      saveProgress.mutate({
        ref: { sourceId, seriesKey, chapterKey: activeChapterKey },
        body: {
          chapter_number: chapter?.chapterNumber ?? null,
          last_page: position.bucket,
          page_count: position.buckets,
          is_completed: position.completed,
          time_spent_seconds: takeElapsed(),
        },
      });
    },
    [
      chapter?.chapterNumber,
      activeChapterKey,
      saveProgress,
      seriesKey,
      sourceId,
      takeElapsed,
    ],
  );

  const handleProgress = useCallback(
    (position: NovelProgressPosition) => {
      // Never rewind: scrolling back to re-read a line must not tell the server
      // the reader is earlier in the chapter than they reached. The server's
      // furthest-wins merge would refuse it anyway, but the write would still
      // be pointless and would rewind the optimistic local state.
      const push = nextProgressPush(position, furthestSent.current);
      if (!push) return;
      furthestSent.current = push.bucket;
      if (progressTimer.current) clearTimeout(progressTimer.current);
      progressTimer.current = setTimeout(() => persistProgress(push), PROGRESS_SAVE_MS);
    },
    [persistProgress],
  );

  /**
   * One deliberate marker at the paragraph being read.
   *
   * Against `activeChapterKey`, not the routed key: a seamless advance moves
   * the chapter with no navigation, so a bookmark taken after one belongs to
   * the chapter on screen. `chapter_number` rides along so the bookmark
   * survives the source re-keying its chapters (design §3).
   */
  const handleBookmark = useCallback(
    (anchor: ParagraphAnchor) => {
      bookmark.capture({
        source_id: sourceId,
        series_key: seriesKey,
        chapter_key: activeChapterKey,
        chapter_number: chapter?.chapterNumber ?? null,
        media_type: BOOKMARK_MEDIA_NOVEL,
        anchor_index: anchor.index,
        anchor_fraction: anchor.fraction,
        anchor_total: anchor.total,
      });
    },
    [activeChapterKey, bookmark, chapter?.chapterNumber, seriesKey, sourceId],
  );

  const advanceToNextChapter = useCallback(() => {
    if (!nextChapterKey || !chapter) return;

    // Mark the finished chapter complete straight away — the debounced tracker
    // never reports the final bucket once the page stops scrolling.
    if (progressTimer.current) {
      clearTimeout(progressTimer.current);
      progressTimer.current = null;
    }
    saveProgress.mutate({
      ref: { sourceId, seriesKey, chapterKey: activeChapterKey },
      body: {
        chapter_number: chapter.chapterNumber,
        last_page: chapter.buckets,
        page_count: chapter.buckets,
        is_completed: true,
        time_spent_seconds: takeElapsed(),
      },
    });

    prefetchNovelChapter(queryClient, {
      sourceId,
      seriesKey,
      chapterKey: nextChapterKey,
    });
    furthestSent.current = 0;
    setResumeBucket(1);
    setResumeAnchor(null);
    setActiveChapterKey(nextChapterKey);
    // A new chapter starts at its first line, not wherever the last one ended.
    setReaderScrollTop(scrollElement, 0);
    window.history.replaceState(
      window.history.state,
      "",
      novelChapterHref({ sourceId, seriesKey, chapterKey: nextChapterKey }),
    );
  }, [
    activeChapterKey,
    chapter,
    nextChapterKey,
    queryClient,
    saveProgress,
    scrollElement,
    seriesKey,
    sourceId,
    takeElapsed,
  ]);

  useEffect(() => {
    return () => {
      if (progressTimer.current) clearTimeout(progressTimer.current);
    };
  }, []);

  return (
    <NovelChapterView
      key={activeChapterKey}
      chapter={chapter}
      isLoading={chapterQuery.isPending && chapterQuery.data === undefined}
      error={chapterQuery.error}
      onRetry={() => void chapterQuery.refetch()}
      preferencesKey={novelSeriesKey(sourceId, seriesKey)}
      seriesTitle={seriesQuery.data?.title ?? seriesKey}
      seriesHref={seriesPageHref({ sourceId, seriesKey })}
      // `activeChapterKey`, not the routed key: a seamless advance moves the
      // chapter with no navigation, and the contents should open at the one
      // on screen.
      contentsHref={novelContentsHref({ sourceId, seriesKey, chapterKey: activeChapterKey })}
      initialBucket={resumeBucket}
      initialAnchor={resumeAnchor}
      onBookmark={handleBookmark}
      bookmarkPending={bookmark.pending}
      bookmarkSaved={bookmark.justSaved}
      bookmarkFailed={bookmark.failed}
      previousChapterHref={previousChapterHref}
      nextChapterHref={nextChapterHref}
      nextChapterLabel={nextChapterLabel}
      onSeamlessNext={nextChapterKey ? advanceToNextChapter : undefined}
      onProgress={handleProgress}
    />
  );
}
