import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/network/network_connectivity.dart';
import 'package:manhwamaniacs/features/downloads/providers/bookmark_outbox_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/progress_outbox_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';
import 'package:manhwamaniacs/features/downloads/widgets/open_chapter_scope.dart';
import 'package:manhwamaniacs/features/library/providers/library_read_state.dart';
import 'package:manhwamaniacs/features/reader/models/bookmark.dart';
import 'package:manhwamaniacs/features/reader/models/reader_chapter.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/providers/series_reading_order_provider.dart';
import 'package:manhwamaniacs/features/reader/utils/reader_feed_controller.dart';
import 'package:manhwamaniacs/features/reader/utils/reader_series_navigation.dart';
import 'package:manhwamaniacs/features/reader/utils/reading_clock.dart';
import 'package:manhwamaniacs/features/reader/widgets/reader_content.dart';
import 'package:manhwamaniacs/features/reader/widgets/reader_error_state.dart';
import 'package:manhwamaniacs/features/reader/widgets/reader_skeleton.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';
import 'package:manhwamaniacs/features/sources/providers/source_reader_provider.dart';
import 'package:manhwamaniacs/features/sources/providers/sources_provider.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';

/// Online source chapter reader.
///
/// Reuses [ReaderContent] for the full reading experience (fullscreen, zoom,
/// virtualization, image cache, auto-next). Progress goes to the server
/// through the same on-device outbox the library reader uses — the server's
/// progress is keyed by the source triple and needs no library row — and is
/// also recorded in [sourceProgressProvider], which the series page reads
/// back at once without waiting for the outbox to flush.
///
/// Eagerly queues the next chapter for download the moment this one loads —
/// gated on the "Wi-Fi only downloads" setting so idly reading never burns
/// mobile data the user didn't ask to spend — via the same on-device queue
/// a manual "Download" tap uses (spec §3).
class SourceReaderScreen extends ConsumerStatefulWidget {
  const SourceReaderScreen({
    super.key,
    required this.sourceId,
    required this.seriesId,
    required this.chapterId,
    this.initialPage = 1,
    this.readAll = false,
  });

  final String sourceId;
  final String seriesId;
  final String chapterId;
  final int initialPage;

  /// Read the whole series as one continuous scroll (spec R2) rather than this
  /// chapter and whatever it continues into. The chapter order arrives behind
  /// the first chapter, so the reader still opens in normal time.
  final bool readAll;

  @override
  ConsumerState<SourceReaderScreen> createState() => _SourceReaderScreenState();
}

class _SourceReaderScreenState extends ConsumerState<SourceReaderScreen> {
  /// Guards the eager next-chapter queue so it fires once per chapter shown,
  /// not on every unrelated rebuild of this widget.
  String? _prefetchedFor;

  /// The continuous feed (spec R1). Built the moment the anchor chapter
  /// resolves; null until then.
  ReaderFeedController? _feedController;

  /// How long this reader has been read, for the reading-time statistic. One
  /// clock for the whole feed, exactly as the library reader keeps: reading
  /// across a seam is continuous.
  final ReadingClock _clock = ReadingClock(DateTime.now());

  /// The most recent progress save, and what refreshes the library's shelves
  /// once it lands — both for [dispose], which cannot read a provider.
  Future<void>? _lastSave;
  LibraryReadState? _readState;

  @override
  void didUpdateWidget(covariant SourceReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different chapter in the ROUTE is a different read: the edge prompts
    // `go` to a sibling route, and the router reuses this element for it. The
    // feed belongs to the old read and nothing in it carries over.
    if (oldWidget.chapterId != widget.chapterId) {
      _feedController?.dispose();
      _feedController = null;
    }
  }

  @override
  void dispose() {
    _feedController?.dispose();
    // By now [ReaderContent] has flushed its pending save — children are torn
    // down first — so [_lastSave] is the read's final position. Nothing saved
    // means nothing on the shelves has moved.
    final lastSave = _lastSave;
    if (lastSave != null) unawaited(_readState?.afterReading(lastSave));
    super.dispose();
  }

  SourceReaderChapterKey _keyFor(String chapterId) => (
        sourceId: widget.sourceId,
        seriesId: widget.seriesId,
        chapterId: chapterId,
      );

  /// Reads a provider to completion while keeping it alive for the duration —
  /// a bare `ref.read(p.future)` on an autoDispose family can be torn down out
  /// from under the pending fetch.
  Future<T> _readAlive<T>(AutoDisposeFutureProvider<T> provider) async {
    final subscription = ref.listenManual(provider, (_, __) {});
    try {
      return await ref.read(provider.future);
    } finally {
      subscription.close();
    }
  }

  /// Loads a chapter for the feed through the same disk-first provider the
  /// anchor came through, so a downloaded chapter continues into another
  /// downloaded chapter with no network at all.
  Future<ReaderChapter?> _loadChapter(String chapterId) async {
    try {
      return await _readAlive(sourceReaderChapterProvider(_keyFor(chapterId)));
    } catch (_) {
      // A seam that cannot be crossed leaves the edge prompt as the way over.
      return null;
    }
  }

  Future<({String? prev, String? next})> _neighboursOf(String chapterId) async {
    final neighbours =
        await _readAlive(sourceChapterNeighboursProvider(_keyFor(chapterId)));
    return (
      prev: neighbours.previousChapterId,
      next: neighbours.nextChapterId,
    );
  }

  /// Builds the feed once the anchor is in hand, and keeps its idea of the
  /// anchor's neighbours current as they arrive out of band (spec R3).
  ///
  /// Built ONCE per route chapter and kept for as long as the route stays on
  /// it — never re-decided per build. This used to keep the feed only while
  /// the window still held the chapter the route opened at, and a Read-all
  /// window slides forward precisely by releasing that chapter: three
  /// chapters in, the very build the slide scheduled found the anchor gone,
  /// threw the window away and started over from the entry chapter. That is
  /// the owner's "after 2-3 chapters it sends me back 2-3 back", recurring
  /// every three chapters for the whole read.
  ///
  /// A re-resolved anchor — the store answering where the network did, or
  /// an equivalent value for no visible reason — is folded in place, and is
  /// a no-op once the window has released it. See
  /// [ReaderFeedController.replaceChapter].
  ReaderFeedController _feedFor(
    ReaderChapter chapter, {
    required String? previousChapterId,
    required String? nextChapterId,
  }) {
    final existing = _feedController;
    if (existing != null) {
      existing
        ..replaceChapter(chapter)
        ..noteNeighbours(
          chapter.id,
          prev: previousChapterId,
          next: nextChapterId,
        );
      return existing;
    }
    final controller = ReaderFeedController(
      anchor: chapter,
      prev: previousChapterId,
      next: nextChapterId,
      neighboursOf: _neighboursOf,
      loadChapter: _loadChapter,
    )..addListener(() {
        if (mounted) setState(() {});
      });
    _feedController = controller;
    return controller;
  }

  /// The number progress is filed under, from the series page's chapter list.
  ///
  /// That list is the only place this reader can learn a number — the online
  /// payload carries none — and it is almost always already loaded, because
  /// this route sits on top of the series page (and Read-all watches it for
  /// the chapter order). [ProviderContainer.exists] first, so a reader opened
  /// without it never fetches a whole chapter list for one label. The number
  /// is what orders a series' chapters on the server; without it a row still
  /// saves, it just cannot say where in the series it falls.
  double? _chapterNumberOf(ProviderContainer container, String chapterId) {
    final series = (sourceId: widget.sourceId, seriesId: widget.seriesId);
    if (!container.exists(sourceSeriesDetailProvider(series))) return null;
    final detail = container.read(sourceSeriesDetailProvider(series));
    final chapters = detail.valueOrNull?.chapters;
    if (chapters == null) return null;
    for (final chapter in chapters) {
      if (chapter.id == chapterId) return chapter.number;
    }
    return null;
  }

  /// Saves [page] of [chapter] to the server outbox and to this phone's
  /// record.
  ///
  /// Everything it touches is handed in, resolved in [build]: [ReaderContent]
  /// flushes its last save from its own dispose(), by which point this state's
  /// element may already be deactivated, and a `ref.read` there throws. That
  /// used to be swallowed, so the save made on the way out of the reader — the
  /// one most likely to be the chapter's last page — was dropped.
  ///
  /// Filed against the chapter the PAGE belongs to: a continuous feed spans
  /// several, and recording all of them against the one the reader opened
  /// would put resume in the wrong place.
  Future<void> _saveProgress(
    ReaderChapter chapter,
    int page, {
    required ProgressOutboxController outbox,
    required SourceProgressNotifier localProgress,
    required DownloadsStore? downloadsStore,
    required ProviderContainer container,
  }) async {
    final pageCount = chapter.pageCount;
    // Guarded on a real count: a chapter that reports none must not be pushed
    // as finished the moment it opens.
    final isCompleted = pageCount > 0 && page >= pageCount;
    // Local-first (spec §3), like the library reader: the outbox stores the
    // push on the phone and flushes it best-effort, so the web, the home
    // shelf, history and the reading-time statistic all see this read.
    //
    // Started before anything here is awaited. On the way out of the reader
    // this runs inside a teardown, and the outbox looks up the downloads
    // store as it starts — a lookup that has to happen now, not after the
    // local write below has given the teardown time to finish.
    final pushed = outbox.save(
      ProgressPush(
        sourceId: widget.sourceId,
        seriesKey: widget.seriesId,
        chapterKey: chapter.id,
        chapterNumber: _chapterNumberOf(container, chapter.id),
        lastPage: page,
        pageCount: pageCount,
        isCompleted: isCompleted,
        timeSpentSeconds: _clock.elapsed(DateTime.now()),
      ),
    );
    try {
      // Kept alongside the push: the series page merges this record with the
      // server's, and it is the half that updates the moment the page turns
      // rather than when the outbox next reaches the server.
      await localProgress.record(
        sourceId: widget.sourceId,
        seriesId: widget.seriesId,
        chapterId: chapter.id,
        page: page,
        pageCount: pageCount,
      );
    } catch (_) {
      // ignore: best-effort client-side progress persistence
    }
    await pushed;
    if (isCompleted) {
      // Read-then-expire (spec §3/§3b): starts the 48h phone-copy timer.
      // A no-op if this chapter was never downloaded.
      await downloadsStore?.markRead(
        (
          sourceId: widget.sourceId,
          seriesKey: widget.seriesId,
          chapterKey: chapter.id,
        ),
      );
    }
  }

  Future<void> _maybeQueueNextChapter(String nextId) async {
    if (ref.read(activeDownloadsScopeIdProvider) == null) return;

    if (ref.read(preferencesProvider).wifiOnlyDownloads) {
      final onWifi = await ref.read(networkConnectivityProvider).isOnWifi();
      if (!onWifi) return;
    }

    await ref.read(downloadQueueControllerProvider.notifier).enqueueChapter(
          id: (
            sourceId: widget.sourceId,
            seriesKey: widget.seriesId,
            chapterKey: nextId,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final key = (
      sourceId: widget.sourceId,
      seriesId: widget.seriesId,
      chapterId: widget.chapterId,
    );
    // Resolved here, never inside the save callback — see [_saveProgress].
    final progressOutbox = ref.read(progressOutboxControllerProvider);
    final localProgress = ref.read(sourceProgressProvider.notifier);
    final downloadsStore = ref.read(downloadsStoreProvider);
    final container = ProviderScope.containerOf(context, listen: false);
    _readState = ref.read(libraryReadStateProvider);
    final chapterAsync = ref.watch(sourceReaderChapterProvider(key));
    // Watched, never awaited (spec R3): a chapter served from disk knows its
    // pages but not its neighbours, and waiting on the network to learn them
    // would put the network back in front of first paint.
    final neighbours = ref.watch(sourceChapterNeighboursProvider(key)).valueOrNull;
    final readAllOrder = widget.readAll
        ? ref
            .watch(
              seriesReadingOrderProvider(
                (sourceId: widget.sourceId, seriesId: widget.seriesId),
              ),
            )
            .valueOrNull
        : null;

    void retry() {
      // The payload is its own cache entry — invalidating only the resolved
      // provider would re-read the stored error and the button would do
      // nothing.
      ref.invalidate(sourceReaderPayloadProvider(key));
      ref.invalidate(sourceReaderChapterProvider(key));
    }

    return chapterAsync.when(
      // Only the FIRST resolution may show the skeleton or the error state.
      // A change to one of the provider's dependencies (the downloads scope,
      // the API base URL behind the payload) re-runs it as a *reload*, which
      // `when` does not skip by default the way it skips an invalidate's
      // refresh. Dropping to the skeleton there unmounts the whole reader,
      // and a Read-all window that had slid past the route's chapter comes
      // back rebuilt from that chapter — the same jump backwards by another
      // door. What is on screen stays on screen until the new value lands.
      skipLoadingOnReload: true,
      skipError: true,
      loading: () => const ReaderSkeleton(),
      error: (error, _) {
        final appError = error is AppError
            ? error
            : UnknownError(message: error.toString(), cause: error);
        return ReaderErrorState(
          error: appError,
          onRetry: retry,
          onBack: () => context.go(
            RoutePaths.sourceSeriesDetail(widget.sourceId, widget.seriesId),
          ),
        );
      },
      data: (chapter) {
        if (chapter.pages.isEmpty) {
          return ReaderErrorState(
            error: const UnknownError(
              message: 'This chapter has no pages.',
            ),
            onRetry: retry,
            onBack: () => context.go(
              RoutePaths.sourceSeriesDetail(widget.sourceId, widget.seriesId),
            ),
          );
        }

        final previousChapterId =
            chapter.previousChapterId ?? neighbours?.previousChapterId;
        final nextChapterId = chapter.nextChapterId ?? neighbours?.nextChapterId;

        // Guarded on the id being *known*, not merely on the chapter having
        // been shown: a downloaded chapter paints from disk before anything
        // knows what comes next, and the eager queue must still fire once the
        // neighbours land rather than being marked done against a null.
        if (nextChapterId != null && _prefetchedFor != widget.chapterId) {
          _prefetchedFor = widget.chapterId;
          // Deferred past this build, like every other one-shot side effect
          // triggered from a build method in this codebase (see
          // OpenChapterScope._claim) — reading providers is safe mid-build,
          // but a network/DB-touching side effect belongs after it.
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => unawaited(_maybeQueueNextChapter(nextChapterId)),
          );
        }

        final feedController = _feedFor(
          chapter,
          previousChapterId: previousChapterId,
          nextChapterId: nextChapterId,
        );
        if (readAllOrder != null && readAllOrder.isNotEmpty) {
          feedController.setOrder(readAllOrder);
        }
        // The edge prompts belong to the chapters at the FEED's edges, not to
        // the one the route opened at. A Read-all window that has slid on has
        // left the anchor far behind, and offering its neighbour as the way out
        // of a stalled run walks the reader back to where they started.
        final beforeFeed = feedController.previousBeforeFeed;
        final beyondFeed = feedController.nextBeyondFeed;

        return OpenChapterScope(
          chapterId: (
            sourceId: widget.sourceId,
            seriesKey: widget.seriesId,
            chapterKey: widget.chapterId,
          ),
          // The whole window, republished on every slide. The route's chapter
          // alone would leave the two neighbours on screen exposed to the
          // resume sweep — and in a re-read of a finished series it is exactly
          // those whose 48h timer has already run out.
          feedChapterIds: [
            for (final chapter in feedController.feed.chapters)
              (
                sourceId: widget.sourceId,
                seriesKey: widget.seriesId,
                chapterKey: chapter.id,
              ),
          ],
          child: ReaderContent(
            key: ValueKey(
              '${widget.sourceId}:${widget.seriesId}:${widget.chapterId}',
            ),
            feed: feedController.feed,
            scrollStorageKey:
                '${widget.sourceId}:${widget.seriesId}:${widget.chapterId}',
            initialPage: widget.initialPage,
            // Most reading STARTS here — this is the tab you reach anything you
            // do not already follow through — and this reader was the only one
            // of the three that could not make a bookmark. The bookmarks table
            // had zero rows in production while the empty state told the reader
            // to "tap the bookmark icon in either reader"; one of the two
            // readers simply did not have one.
            //
            // Same outbox as the library reader (reader_screen.dart:442-460):
            // the push is best-effort, so bookmarking with no signal is an
            // ordinary success. `true` means "stored", not "sent".
            onAddBookmark: (chapter, anchor) => ref
                .read(bookmarkOutboxControllerProvider)
                .create(
                  id: (
                    sourceId: widget.sourceId,
                    seriesKey: widget.seriesId,
                    chapterKey: chapter.id,
                  ),
                  media: BookmarkMedia.manga,
                  anchorIndex: anchor.page,
                  anchorFraction: anchor.fraction,
                  // The pages actually in the feed, not the manifest's count:
                  // the anchor was measured against what is on screen, and a
                  // disagreeing total puts "page 9 of 8" on the Bookmarks
                  // screen.
                  anchorTotal: chapter.pages.length,
                  // chapterNumber is left at its default null: this reader
                  // keeps no chapter-number index, so a bookmark from here
                  // reads "62% through this chapter" rather than naming a
                  // number. Carrying it would mean threading the number through
                  // ReaderChapter, which drags it into that model's `==` and
                  // churns replaceChapter — not worth it for a label.
                  seriesTitle: chapter.seriesTitle,
                )
                .then((bookmark) => bookmark != null),
            onReachedFeedEnd: feedController.extendForward,
            onReachedFeedStart: feedController.extendBackward,
            onSaveProgress: (chapter, page) => _lastSave = _saveProgress(
              chapter,
              page,
              outbox: progressOutbox,
              localProgress: localProgress,
              downloadsStore: downloadsStore,
              container: container,
            ),
            onBack: () => context.go(
              RoutePaths.sourceSeriesDetail(widget.sourceId, widget.seriesId),
            ),
            // Straight to this source's series page — the connector series id can
            // contain `/`, so the encoding in RoutePaths is what keeps it intact.
            onOpenSeries: () => openSeriesFromReader(
              context,
              sourceId: widget.sourceId,
              seriesKey: widget.seriesId,
            ),
            onPreviousChapter: beforeFeed != null
                ? () => context.go(
                      RoutePaths.sourceReader(
                        widget.sourceId,
                        widget.seriesId,
                        beforeFeed,
                      ),
                    )
                : null,
            onNextChapter: beyondFeed != null
                ? () => context.go(
                      RoutePaths.sourceReader(
                        widget.sourceId,
                        widget.seriesId,
                        beyondFeed,
                      ),
                    )
                : null,
          ),
        );
      },
    );
  }
}
