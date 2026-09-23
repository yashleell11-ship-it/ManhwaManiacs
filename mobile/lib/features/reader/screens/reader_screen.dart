import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/logging/app_logger.dart';
import 'package:manhwamaniacs/features/downloads/providers/bookmark_outbox_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/progress_outbox_provider.dart';
import 'package:manhwamaniacs/features/downloads/widgets/open_chapter_scope.dart';
import 'package:manhwamaniacs/features/library/providers/library_read_state.dart';
import 'package:manhwamaniacs/features/reader/models/bookmark.dart';
import 'package:manhwamaniacs/features/reader/models/reader_chapter.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/providers/reader_chapter_provider.dart';
import 'package:manhwamaniacs/features/reader/providers/series_reading_order_provider.dart';
import 'package:manhwamaniacs/features/reader/utils/reader_anchor.dart';
import 'package:manhwamaniacs/features/reader/utils/reader_feed_controller.dart';
import 'package:manhwamaniacs/features/reader/utils/reader_series_navigation.dart';
import 'package:manhwamaniacs/features/reader/utils/reading_clock.dart';
import 'package:manhwamaniacs/features/reader/widgets/reader_content.dart';
import 'package:manhwamaniacs/features/reader/widgets/reader_error_state.dart';
import 'package:manhwamaniacs/features/reader/widgets/reader_skeleton.dart';

/// The manifest-driven reader for a followed series' chapter — the one
/// reader every non-source-browsing entry point (series detail, continue
/// reading, bookmarks, history) links to. Identity is the opaque
/// `(sourceId, seriesKey, chapterKey)` triple; see [Routes.reader].
///
/// Renders offline when the chapter is downloaded — see
/// [resolvedReaderChapterProvider] for how the manifest fetch and the
/// on-device store fallback are reconciled.
class ReaderScreen extends ConsumerWidget {
  const ReaderScreen({
    super.key,
    required this.sourceId,
    required this.seriesKey,
    required this.chapterKey,
    this.initialPage = 1,
    this.initialAnchor,
    this.readAll = false,
  });

  final String sourceId;
  final String seriesKey;
  final String chapterKey;
  final int initialPage;

  /// The exact position to open at, when the reader was entered from a
  /// bookmark. [initialPage] alone would land at the top of the page, which
  /// on a webtoon strip can be thousands of pixels from where the reader
  /// actually was — the whole point of the anchor.
  final ReaderAnchor? initialAnchor;

  /// Read the whole series as one continuous scroll (spec R2), rather than
  /// this chapter and whatever it happens to continue into.
  ///
  /// The difference is only that the reader is handed the series' chapter
  /// order, so it knows what follows without asking per boundary. The order
  /// arrives *behind* the first chapter: the reader opens in normal time and
  /// the rest fills in, which is exactly what the owner accepted ("it doesnt
  /// matter if it takes some time to load ... but i want that mode too") and
  /// is why a spinner in front of 300 chapters was never on the table.
  final bool readAll;

  ChapterManifestKey get _key =>
      (sourceId: sourceId, seriesKey: seriesKey, chapterKey: chapterKey);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolvedAsync = ref.watch(resolvedReaderChapterProvider(_key));
    // Watched, never awaited (spec R3). A chapter rendered from disk knows its
    // own pages but not its neighbours; this fills them in whenever the
    // network can supply them, and stays null forever if it cannot — which
    // costs the reader nothing but the prev/next affordances.
    final neighbours = ref.watch(chapterNeighboursProvider(_key)).valueOrNull;
    final readAllOrder = readAll
        ? ref
            .watch(
              seriesReadingOrderProvider(
                (sourceId: sourceId, seriesId: seriesKey),
              ),
            )
            .valueOrNull
        : null;

    void retry() {
      // Both, not just the resolved provider: the manifest is a separate
      // cache entry and a retry that re-read its stored error would be a
      // button that does nothing.
      ref.invalidate(chapterManifestProvider(_key));
      ref.invalidate(resolvedReaderChapterProvider(_key));
    }

    // This route is nested under the library tab root, so `go`-ing between
    // chapters always rebuilds the shell beneath it and a plain pop has
    // somewhere to land — unlike the novel reader, which is top-level and
    // where the same shape left Back doing nothing at all. Routed through
    // [leaveReader] anyway so one function owns the answer for both readers
    // and this one cannot acquire the bug by being re-parented later.
    void back() =>
        leaveReader(context, sourceId: sourceId, seriesKey: seriesKey);

    return resolvedAsync.when(
      // Only the FIRST resolution may show the skeleton or the error state.
      // The provider re-runs whenever one of its dependencies changes (the
      // downloads scope, the API base URL, the manifest behind it), and
      // Riverpod hands `when` an AsyncLoading for that — a *reload*, which
      // unlike the refresh an `invalidate` produces is not skipped by
      // default. Falling back to the skeleton there unmounts the feed body,
      // and a Read-all window that had slid two or three chapters past the
      // route's chapter is rebuilt from that chapter when the data lands
      // again: the reported "it sends me back 2-3 chapters". The value that
      // is already on screen stays on screen until the new one replaces it.
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
          onBack: back,
        );
      },
      data: (resolved) {
        if (resolved.chapter.pages.isEmpty) {
          return ReaderErrorState(
            error: const UnknownError(message: 'This chapter has no pages.'),
            onRetry: retry,
            onBack: back,
          );
        }

        // The "currently open" claim lives inside the body, not here: it has
        // to name every chapter the feed is holding, and the feed is the
        // body's own state.
        return _ManifestReaderBody(
          sourceId: sourceId,
          seriesKey: seriesKey,
          chapterKey: chapterKey,
          resolved: resolved,
          neighbours: neighbours,
          initialPage: initialPage,
          initialAnchor: initialAnchor,
          readAllOrder: readAllOrder,
        );
      },
    );
  }
}

class _ManifestReaderBody extends ConsumerStatefulWidget {
  const _ManifestReaderBody({
    required this.sourceId,
    required this.seriesKey,
    required this.chapterKey,
    required this.resolved,
    required this.neighbours,
    required this.initialPage,
    this.initialAnchor,
    this.readAllOrder,
  });

  final String sourceId;
  final String seriesKey;
  final String chapterKey;
  final ResolvedReaderChapter resolved;

  /// Adjacent keys from the manifest, or null while (or if) it never lands.
  /// Only ever *adds* to what [resolved] already carries — a chapter resolved
  /// online got them in the same payload.
  final ChapterNeighbours? neighbours;
  final int initialPage;
  final ReaderAnchor? initialAnchor;

  /// Every chapter of the series in reading order — Read-all (spec R2). With
  /// it the feed knows where it is going without a round trip per boundary;
  /// without it the reader is an ordinary one-chapter read that happens to
  /// continue when it reaches the end.
  final List<String>? readAllOrder;

  @override
  ConsumerState<_ManifestReaderBody> createState() => _ManifestReaderBodyState();
}

class _ManifestReaderBodyState extends ConsumerState<_ManifestReaderBody> {
  late ReaderFeedController _controller;

  /// The most recent progress save, and what refreshes the library's shelves
  /// once it lands — both for [dispose], which cannot read a provider.
  Future<void>? _lastSave;
  LibraryReadState? _readState;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
  }

  @override
  void didUpdateWidget(covariant _ManifestReaderBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final was = oldWidget.resolved.chapter;
    final now = widget.resolved.chapter;

    // A different chapter in the ROUTE is a different read. Everything keyed
    // off it moves with it — the scroll storage key, [ReaderContent]'s own
    // key, and so that widget's whole state — so there is no window left to
    // preserve and a fresh feed is the only honest answer.
    if (oldWidget.chapterKey != widget.chapterKey) {
      // Guarded at the call site, not inside: [kDebugMode] is a compile-time
      // constant, so this way the arguments — which walk a page list — are
      // dropped from a release build along with the call.
      if (kDebugMode) {
        _reportFeedChange(
          reason: 'the route moved to another chapter',
          wasKey: oldWidget.chapterKey,
          nowKey: widget.chapterKey,
          chaptersHeld: _controller.feed.chapters.length,
          outcome: 'feed rebuilt from the new chapter',
        );
      }
      _controller.dispose();
      _controller = _buildController();
      return;
    }

    // Same chapter, resolved again — reported whether or not anything about
    // it actually moved. An EQUIVALENT re-emission is precisely what the old
    // reference-equality guard threw the whole feed away for, so how often
    // one arrives during a real read is the measurement that settles what
    // reading the code could not.
    if (kDebugMode && !identical(was, now)) {
      _reportFeedChange(
        reason: 'the chapter re-resolved — ${_chapterDifference(was, now)}',
        wasKey: was.id,
        nowKey: now.id,
        chaptersHeld: _controller.feed.chapters.length,
        outcome: was == now
            ? 'nothing to do (the old reference guard rebuilt the feed here)'
            : _controller.feed.contains(now.id)
                ? 'swapped in place, window kept'
                : 'dropped, the window has already released this chapter',
      );
    }
    // [resolvedReaderChapterProvider] builds a fresh [ReaderChapter] on every
    // run, so only a change of VALUE is worth acting on — and even then the
    // window survives it: the feed holds chapters either side of the anchor in
    // a Read-all run, and starting over would drop the reader back at the
    // chapter the route opened at.
    if (was != now) _controller.replaceChapter(now);

    // The neighbours the screen watches land after first paint (spec R3), and
    // the feed needs them to know what to continue into.
    _controller.noteNeighbours(
      widget.chapterKey,
      prev: _prev,
      next: _next,
    );
    // Read-all's chapter order arrives behind the first chapter, on purpose.
    final order = widget.readAllOrder;
    if (order != null && order.isNotEmpty) _controller.setOrder(order);
  }

  @override
  void dispose() {
    _controller.dispose();
    // By now [ReaderContent] has flushed its pending save — children are torn
    // down first — so [_lastSave] is the read's final position. Nothing saved
    // means nothing on the shelves has moved.
    final lastSave = _lastSave;
    if (lastSave != null) unawaited(_readState?.afterReading(lastSave));
    super.dispose();
  }

  /// [save], remembering each call's future as [_lastSave].
  Future<void> Function(ReaderChapter, int) _trackSaves(
    Future<void> Function(ReaderChapter chapter, int page) save,
  ) =>
      (chapter, page) => _lastSave = save(chapter, page);

  ReaderFeedController _buildController() => ReaderFeedController(
        anchor: widget.resolved.chapter,
        prev: _prev,
        next: _next,
        order: widget.readAllOrder,
        neighboursOf: _neighboursOf,
        loadChapter: _loadChapter,
      )..addListener(_onFeedChanged);

  void _onFeedChanged() {
    if (mounted) setState(() {});
  }

  String? get _prev => widget.resolved.prev ?? widget.neighbours?.prev;
  String? get _next => widget.resolved.next ?? widget.neighbours?.next;

  /// The number progress is filed under. The store stamps it at download time
  /// from the same manifest, so the two agree; the manifest wins only when the
  /// store had none to stamp.
  double? _chapterNumberOf(ReaderChapter chapter) {
    if (chapter.id == widget.chapterKey) {
      return widget.resolved.chapterNumber ?? widget.neighbours?.chapterNumber;
    }
    return _numbers[chapter.id];
  }

  /// Chapter numbers learned while extending the feed. Progress needs the
  /// number, not just the key — it is the axis that survives a source change.
  final Map<String, double?> _numbers = {};

  /// How long this reader has been read, for the reading-time statistic. One
  /// clock for the whole feed rather than one per chapter: reading across a
  /// seam is continuous, and the delta is filed against whichever chapter the
  /// push that collects it belongs to.
  final ReadingClock _clock = ReadingClock(DateTime.now());

  ChapterManifestKey _keyFor(String chapterKey) => (
        sourceId: widget.sourceId,
        seriesKey: widget.seriesKey,
        chapterKey: chapterKey,
      );

  /// Reads a provider to completion while keeping it alive for the duration.
  /// A bare `ref.read(p.future)` on an autoDispose family can have the
  /// provider torn down out from under the pending fetch.
  Future<T> _readAlive<T>(AutoDisposeFutureProvider<T> provider) async {
    final subscription = ref.listenManual(provider, (_, __) {});
    try {
      return await ref.read(provider.future);
    } finally {
      subscription.close();
    }
  }

  /// Loads a chapter for the feed through the SAME disk-first provider the
  /// anchor came through, so a downloaded chapter continues into another
  /// downloaded chapter with no network involved at all.
  Future<ReaderChapter?> _loadChapter(String chapterKey) async {
    try {
      final resolved = await _readAlive(
        resolvedReaderChapterProvider(_keyFor(chapterKey)),
      );
      _numbers[chapterKey] = resolved.chapterNumber;
      return resolved.chapter;
    } catch (_) {
      // A seam that cannot be crossed leaves the edge prompt as the way over.
      return null;
    }
  }

  Future<({String? prev, String? next})> _neighboursOf(String chapterKey) async {
    final neighbours =
        await _readAlive(chapterNeighboursProvider(_keyFor(chapterKey)));
    _numbers[chapterKey] ??= neighbours.chapterNumber;
    return (prev: neighbours.prev, next: neighbours.next);
  }

  @override
  Widget build(BuildContext context) {
    // Resolved once here rather than via `ref.read(...)` inside the
    // callbacks below: `ReaderContent.dispose()` flushes a pending progress
    // save, and by then this widget's own element may already be
    // deactivated — reading a provider through it at that point throws
    // ("Looking up a deactivated widget's ancestor is unsafe"). Plain
    // objects captured here stay safe to call from anywhere.
    final progressOutbox = ref.read(progressOutboxControllerProvider);
    final bookmarkOutbox = ref.read(bookmarkOutboxControllerProvider);
    final downloadsStore = ref.read(downloadsStoreProvider);
    _readState = ref.read(libraryReadStateProvider);
    final sourceId = widget.sourceId;
    final seriesKey = widget.seriesKey;
    // Taken from the chapters at the FEED's edges rather than from the one the
    // route opened at. In a slid Read-all window the anchor is thirty chapters
    // back, and offering its neighbour as the way out of a run that dead-ended
    // at chapter 30 sends the reader thirty minutes backwards.
    final beforeFeed = _controller.previousBeforeFeed;
    final beyondFeed = _controller.nextBeyondFeed;

    return OpenChapterScope(
      chapterId: (
        sourceId: sourceId,
        seriesKey: seriesKey,
        chapterKey: widget.chapterKey,
      ),
      // Republished from here on every feed change, because a Read-all window
      // slides: the chapters on screen three chapters in are not the one the
      // route opened at, and the sweep has to be told about all of them.
      feedChapterIds: [
        for (final chapter in _controller.feed.chapters)
          (sourceId: sourceId, seriesKey: seriesKey, chapterKey: chapter.id),
      ],
      child: ReaderContent(
        key: ValueKey('$sourceId:$seriesKey:${widget.chapterKey}'),
        feed: _controller.feed,
        scrollStorageKey: '$sourceId:$seriesKey:${widget.chapterKey}',
        initialPage: widget.initialPage,
        initialAnchor: widget.initialAnchor,
        onBack: () => leaveReader(
          context,
          sourceId: sourceId,
          seriesKey: seriesKey,
        ),
        onOpenSeries: () => openSeriesFromReader(
          context,
          sourceId: sourceId,
          seriesKey: seriesKey,
        ),
        // The edge prompts are for a boundary the FEED could not absorb — the
        // ends of the series, or a chapter that would not load. Crossing a
        // loaded boundary is scrolling, and never navigation.
        onPreviousChapter: beforeFeed != null
            ? () => context.go(RoutePaths.reader(sourceId, seriesKey, beforeFeed))
            : null,
        onNextChapter: beyondFeed != null
            ? () => context.go(RoutePaths.reader(sourceId, seriesKey, beyondFeed))
            : null,
        onReachedFeedEnd: _controller.extendForward,
        onReachedFeedStart: _controller.extendBackward,
        onSaveProgress: _trackSaves((chapter, page) async {
          final isCompleted = page >= chapter.pageCount;
          // Local-first (spec §3): every save writes to the on-device outbox
          // and is flushed best-effort — the reader never blocks on, or loses
          // a save to, a flaky or absent connection.
          //
          // Filed against the chapter the PAGE belongs to, which in a continuous
          // feed is not always the one the reader opened: reading into chapter
          // 12 records chapter 12, so resume lands there.
          await progressOutbox.save(
            ProgressPush(
              sourceId: sourceId,
              seriesKey: seriesKey,
              chapterKey: chapter.id,
              chapterNumber: _chapterNumberOf(chapter),
              lastPage: page,
              pageCount: chapter.pageCount,
              isCompleted: isCompleted,
              timeSpentSeconds: _clock.elapsed(DateTime.now()),
            ),
          );
          if (isCompleted) {
            // Read-then-expire (spec §3/§3b): starts the 48h phone-copy timer.
            // A no-op if this chapter was never downloaded.
            await downloadsStore?.markRead(
              (
                sourceId: sourceId,
                seriesKey: seriesKey,
                chapterKey: chapter.id,
              ),
            );
          }
        }),
        // Local-first, exactly like progress: the row lands on the phone and
        // the push is best-effort, so bookmarking with no signal is an ordinary
        // success rather than a silent loss. `true` means "stored", not "sent".
        onAddBookmark: (chapter, anchor) => bookmarkOutbox
            .create(
              id: (
                sourceId: sourceId,
                seriesKey: seriesKey,
                chapterKey: chapter.id,
              ),
              media: BookmarkMedia.manga,
              anchorIndex: anchor.page,
              anchorFraction: anchor.fraction,
              // The pages actually in the feed, not the manifest's reported
              // count: the anchor was measured against what is on screen, and a
              // total that disagreed with it would put "page 9 of 8" on the
              // Bookmarks screen.
              anchorTotal: chapter.pages.length,
              chapterNumber: _chapterNumberOf(chapter),
              seriesTitle: chapter.seriesTitle,
            )
            .then((bookmark) => bookmark != null),
      ),
    );
  }
}

/// Which fields moved between two resolutions of the same chapter, named
/// rather than printed: a webtoon page list is megabytes of URLs, and the
/// question this answers is *what kind* of change fired the reset, not what
/// the new value was.
///
/// "nothing differs" is the interesting answer here, not the boring one: it
/// means the provider re-emitted an equivalent chapter, and every reset the
/// old reference-equality guard fired was for a change that never happened.
String _chapterDifference(ReaderChapter was, ReaderChapter now) {
  final moved = <String>[
    if (was.id != now.id) 'id',
    if (was.seriesId != now.seriesId) 'seriesId',
    if (was.title != now.title) 'title',
    if (was.pageCount != now.pageCount)
      'pageCount ${was.pageCount}->${now.pageCount}',
    if (was.sourceId != now.sourceId) 'sourceId',
    if (was.seriesTitle != now.seriesTitle) 'seriesTitle',
    if (was.previousChapterId != now.previousChapterId) 'previousChapterId',
    if (was.nextChapterId != now.nextChapterId) 'nextChapterId',
    if (was.pages.length != now.pages.length)
      'pages ${was.pages.length}->${now.pages.length}',
    if (was.pages.length == now.pages.length &&
        !listEquals(was.pages, now.pages))
      'page contents',
  ];
  return moved.isEmpty ? 'nothing differs' : 'changed: ${moved.join(', ')}';
}

/// Report a change at the reader's anchor that the feed had to answer for.
///
/// This exists because the reset it describes was invisible: the owner sees
/// the reader jump backwards after a few chapters and there is nothing in a
/// log to say a feed was thrown away, let alone what asked for it. One line
/// per occurrence, naming the trigger, both chapter keys, how much of a
/// Read-all window was at stake and what was actually done with it, is enough
/// to settle in one reading session what reading the code could not.
///
/// Callers guard on [kDebugMode] so this and its arguments leave a release
/// build entirely.
void _reportFeedChange({
  required String reason,
  required String wasKey,
  required String nowKey,
  required int chaptersHeld,
  required String outcome,
}) {
  appLogger.d(
    'reader/feed: $reason — chapter "$wasKey" -> "$nowKey", '
    'feed held $chaptersHeld chapter(s); $outcome.',
  );
}
