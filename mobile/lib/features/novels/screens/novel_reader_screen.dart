import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/platform/system_ui.dart';
import 'package:manhwamaniacs/features/downloads/providers/bookmark_outbox_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/progress_outbox_provider.dart';
import 'package:manhwamaniacs/features/downloads/widgets/open_chapter_scope.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter.dart';
import 'package:manhwamaniacs/features/novels/models/novel_palette.dart';
import 'package:manhwamaniacs/features/novels/models/novel_typography.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_chapter_provider.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_preferences_provider.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_book.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_progress.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_snippet.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_chapter_view.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_reader_chrome.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_type_panel.dart';
import 'package:manhwamaniacs/features/reader/models/bookmark.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/utils/reader_series_navigation.dart';
import 'package:manhwamaniacs/features/reader/utils/reader_wakelock.dart';
import 'package:manhwamaniacs/features/reader/utils/reading_clock.dart';
import 'package:manhwamaniacs/features/reader/widgets/reader_error_state.dart';
import 'package:manhwamaniacs/features/settings/providers/settings_provider.dart';

/// How often a scroll is turned into a progress position. The manga reader
/// uses the same 500 ms, and for the same reason: often enough that a kill
/// loses nothing worth noticing, rare enough that it is not per-frame work.
const _progressSaveMs = 500;

/// The pause at the end of a chapter before the next one opens.
///
/// This is the manga reader's `_autoNextChapterMs`, deliberately the same
/// number: it is the beat that makes the transition feel like turning a page
/// rather than the app navigating, and two different beats for the two readers
/// would be two different feelings in one app.
const _autoNextChapterMs = 900;

/// Frames a deferred restore is allowed to home in for before it settles
/// wherever it has got to — the same budget and the same reasoning as the
/// manga reader's `_maxRestoreFrames`.
const _maxRestoreFrames = 30;

/// Fraction of the viewport height that counts as the reading line: the
/// paragraph a reader is actually on is the one just below the top edge, not
/// the one clipped by it.
const _readingLineFraction = 0.25;

/// The novel reader.
///
/// Identity is the same opaque `(sourceId, seriesKey, chapterKey)` triple as
/// the manga reader's, and [initialBucket] is the progress BUCKET (see
/// `utils/novel_progress.dart`) carried in the same `?page=` query parameter —
/// so a "Continue" link needs no novel-specific branch to build.
class NovelReaderScreen extends ConsumerWidget {
  const NovelReaderScreen({
    super.key,
    required this.sourceId,
    required this.seriesKey,
    required this.chapterKey,
    this.initialBucket = 1,
    this.initialParagraph,
    this.initialFraction,
  });

  final String sourceId;
  final String seriesKey;
  final String chapterKey;
  final int initialBucket;

  /// The exact paragraph (1-based) to open on — what tapping a bookmark
  /// hands over, and what [initialBucket] deliberately is not. A bucket is at
  /// worst ~1% of the chapter; a bookmark is a line.
  ///
  /// When set it wins over [initialBucket]: the reader asked for one place.
  final int? initialParagraph;

  /// How far into [initialParagraph], 0.0–1.0. A long paragraph on a phone is
  /// several screens, so its top is not the same place as its middle.
  final double? initialFraction;

  NovelChapterKey get _key =>
      (sourceId: sourceId, seriesKey: seriesKey, chapterKey: chapterKey);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapterAsync = ref.watch(resolvedNovelChapterProvider(_key));
    // Watched, never awaited (spec R3): a downloaded chapter opens off the
    // phone, and what comes next is filled in whenever the network can say.
    final neighbours =
        ref.watch(novelChapterNeighboursProvider(_key)).valueOrNull;

    void retry() {
      // The payload is its own cache entry; invalidating only the resolved
      // provider would re-read its stored error and do nothing visible.
      ref.invalidate(novelChapterPayloadProvider(_key));
      ref.invalidate(resolvedNovelChapterProvider(_key));
    }

    void back() =>
        leaveReader(context, sourceId: sourceId, seriesKey: seriesKey);

    // The Android back gesture and the hardware key never reach the chrome's
    // button — they go to the router, which for this top-level route has
    // nothing to pop after a chapter change and would close the app instead.
    // This is what routes them through the same exit as everything else.
    //
    // Unconditionally `canPop: false` rather than `context.canPop()`: this
    // route is either the whole stack or not depending on how the reader was
    // reached, the two answers disagree for the frame a chapter change is
    // fading out, and a back pressed in that frame is precisely the one that
    // must not be wrong. [leaveReader] pops for itself when it can, so the
    // destination is identical either way.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        back();
      },
      child: chapterAsync.when(
        loading: () => const _NovelReaderSkeleton(),
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
        data: (chapter) {
          if (chapter.paragraphs.isEmpty) {
            return ReaderErrorState(
              error: const UnknownError(message: 'This chapter has no text.'),
              onRetry: retry,
              onBack: back,
            );
          }
          return OpenChapterScope(
            chapterId: (
              sourceId: sourceId,
              seriesKey: seriesKey,
              chapterKey: chapterKey,
            ),
            child: _NovelReaderBody(
              key: ValueKey('$sourceId:$seriesKey:$chapterKey'),
              chapter: chapter,
              neighbours: neighbours,
              initialBucket: initialBucket,
              initialParagraph: initialParagraph,
              initialFraction: initialFraction,
            ),
          );
        },
      ),
    );
  }
}

class _NovelReaderBody extends ConsumerStatefulWidget {
  const _NovelReaderBody({
    super.key,
    required this.chapter,
    required this.neighbours,
    required this.initialBucket,
    this.initialParagraph,
    this.initialFraction,
  });

  final NovelChapter chapter;

  /// Adjacent keys, when the network has supplied them. Kept beside the
  /// chapter rather than folded into it so a later arrival never replaces the
  /// paragraph list this state is measuring against — the reading position
  /// would jump.
  final NovelChapterNeighbours? neighbours;
  final int initialBucket;
  final int? initialParagraph;
  final double? initialFraction;

  @override
  ConsumerState<_NovelReaderBody> createState() => _NovelReaderBodyState();
}

class _NovelReaderBodyState extends ConsumerState<_NovelReaderBody> {
  final _scrollController = ScrollController();
  late List<GlobalKey> _paragraphKeys;

  bool _chromeVisible = false;

  /// The furthest bucket already handed to the outbox for this chapter.
  /// Scrolling back up must never tell the server the reader is earlier than
  /// they got to — see [nextProgressPush].
  int _furthestSent = 0;

  /// The bucket currently under the reading line, for the read-out.
  /// The progress bucket, as a notifier rather than a field.
  ///
  /// Buckets are 1% of a chapter (kMaxProgressBuckets = 100) and the scroll
  /// debounce fires every 500 ms, so during ordinary reading the bucket changes
  /// on nearly every tick. As setState that rebuilt the whole body — the
  /// CustomScrollView and every built paragraph — about twice a second, for the
  /// entire session. Only the chrome's percent actually depends on it.
  final ValueNotifier<int> _bucket = ValueNotifier<int>(1);

  /// How long this reader has been read, for the reading-time statistic.
  final ReadingClock _clock = ReadingClock(DateTime.now());

  Timer? _progressTimer;
  Timer? _autoNextTimer;
  bool _autoNextTriggered = false;

  /// The chapter to continue into, from whichever source knows it: the
  /// online payload carries its own, a disk copy learns it out of band.
  String? get _nextKey =>
      widget.chapter.nextChapterKey ?? widget.neighbours?.nextChapterKey;

  String? get _previousKey =>
      widget.chapter.previousChapterKey ?? widget.neighbours?.previousChapterKey;

  int? _pendingRestoreParagraph;
  int _restoreFrames = 0;
  double _lastRestoreMaxExtent = -1;

  /// How far into [_pendingRestoreParagraph] the restore is aiming, and
  /// whether it is aiming at the reading line rather than the top of the
  /// viewport.
  ///
  /// Both are only ever non-default on the bookmark path. Resuming by bucket
  /// keeps landing the paragraph's top at the top of the screen exactly as it
  /// always has — a bucket is a coarse "about here", and dropping the reader
  /// a quarter of a screen lower would be pretending to a precision it does
  /// not have.
  double _restoreFraction = 0;
  bool _restoreToReadingLine = false;

  /// A save is in flight; the chrome's bookmark button is disabled meanwhile
  /// so a double tap cannot make two bookmarks of one spot.
  bool _bookmarkPending = false;

  /// Resolved once, while the element is alive, because [dispose] has to
  /// release it and cannot ask for it there: `StatefulElement.unmount` marks
  /// the element defunct BEFORE calling `dispose()`, so a `ref.read` from
  /// inside it throws `Cannot use "ref" after the widget was disposed` — in
  /// release as much as in debug, since that check is a plain `throw` and not
  /// an assert. Thrown from there it also skipped `super.dispose()` and left
  /// the screen pinned awake for the rest of the session. The manga reader
  /// resolves its own outbox handles in `build` for the same reason.
  late final ReaderWakelock _wakelock;

  @override
  void initState() {
    super.initState();
    _wakelock = ref.read(readerWakelockProvider);
    _paragraphKeys = List.generate(
      widget.chapter.paragraphs.length,
      (_) => GlobalKey(),
    );
    _scrollController.addListener(_onScroll);
    applyReadingSystemUiMode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyWakelock();
      _beginRestore();
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _autoNextTimer?.cancel();
    _scrollController.dispose();
    _bucket.dispose();
    // Symmetric with initState: leaving a chapter restores exactly what the
    // app launched with rather than permanently changing its shape.
    applyRestingSystemUiMode();
    _wakelock.disable();
    super.dispose();
  }

  void _applyWakelock() {
    final keepAwake = ref.read(readerDefaultsProvider).keepScreenAwake;
    keepAwake ? _wakelock.enable() : _wakelock.disable();
  }

  // ── Restore ──────────────────────────────────────────────────────────────

  /// Resume where the reader left off, never past it.
  ///
  /// The target is a paragraph, but a lazily-built list only knows the offsets
  /// of the paragraphs it has actually laid out — so this homes in the way the
  /// manga reader's restore does: jump as far as the list currently admits,
  /// let that force more paragraphs to lay out, and re-check next frame, under
  /// a hard frame budget so a list whose extent keeps creeping cannot drag the
  /// reader backwards while they are trying to read.
  void _beginRestore() {
    final paragraphs = widget.chapter.paragraphs.length;
    final requested = widget.initialParagraph;
    if (requested != null && paragraphs > 0) {
      // A bookmark: land on the paragraph, at the point within it, at the
      // reading line the position was measured against.
      //
      // The clamp is the honest degradation the design asks for — a chapter
      // an aggregator has since re-split may hold fewer paragraphs than it
      // did, and the nearest surviving one (with a quiet word about it) beats
      // both failing to open and silently starting from the top.
      final target = (requested - 1).clamp(0, paragraphs - 1);
      _restoreFraction = widget.initialFraction ?? 0;
      _restoreToReadingLine = true;
      _pendingRestoreParagraph = target;
      _bucket.value = bucketForParagraph(target, paragraphs);
      _furthestSent = _bucket.value;
      _restoreFrames = 0;
      _lastRestoreMaxExtent = -1;
      if (requested > paragraphs) _reportStaleAnchor(requested, paragraphs);
      _attemptRestore();
      return;
    }
    final target = paragraphForBucket(widget.initialBucket, paragraphs);
    if (target <= 0) {
      _bucket.value = bucketForParagraph(0, paragraphs);
      // Opening at the top is still progress worth remembering as "seen", but
      // never as further than the reader actually got.
      _furthestSent = 0;
      return;
    }
    _pendingRestoreParagraph = target;
    _furthestSent = widget.initialBucket;
    _bucket.value = widget.initialBucket;
    _restoreFrames = 0;
    _lastRestoreMaxExtent = -1;
    _attemptRestore();
  }

  void _attemptRestore() {
    final target = _pendingRestoreParagraph;
    if (target == null) return;
    if (!mounted || !_scrollController.hasClients) {
      _pendingRestoreParagraph = null;
      return;
    }

    final position = _scrollController.position;
    final box = _boxFor(target);
    if (box != null) {
      // The target has been laid out: land on it exactly. The point aimed at
      // and the reference it is aimed at are BOTH the ones the capture used
      // (see [_anchorAtReadingLine]), which is what makes bookmarking a spot
      // and returning to it a round trip rather than an approximation.
      final anchorPoint = box.localToGlobal(Offset.zero).dy +
          _restoreFraction * box.size.height;
      final reference =
          _restoreToReadingLine ? _readingLine() : _viewportTop();
      final delta = anchorPoint - reference;
      _scrollController.jumpTo(
        (position.pixels + delta).clamp(0.0, position.maxScrollExtent),
      );
      _pendingRestoreParagraph = null;
      return;
    }

    final maxExtent = position.maxScrollExtent;
    final stoppedGrowing = maxExtent <= _lastRestoreMaxExtent;
    final outOfFrames = ++_restoreFrames >= _maxRestoreFrames;
    if (stoppedGrowing || outOfFrames) {
      _pendingRestoreParagraph = null;
      return;
    }
    _lastRestoreMaxExtent = maxExtent;
    // Jump to where the target is *estimated* to be, which forces the list to
    // build that far and makes the exact answer available next frame.
    final fraction = target / widget.chapter.paragraphs.length;
    _scrollController.jumpTo((maxExtent * fraction).clamp(0.0, maxExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) => _attemptRestore());
  }

  RenderBox? _boxFor(int paragraphIndex) {
    if (paragraphIndex < 0 || paragraphIndex >= _paragraphKeys.length) {
      return null;
    }
    final context = _paragraphKeys[paragraphIndex].currentContext;
    final box = context?.findRenderObject();
    return box is RenderBox && box.hasSize ? box : null;
  }

  double _viewportTop() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return 0;
    return box.localToGlobal(Offset.zero).dy;
  }

  /// The line a reader is actually reading on — a quarter of the way down,
  /// not the top edge, where the paragraph is half clipped.
  double _readingLine() =>
      _viewportTop() + MediaQuery.sizeOf(context).height * _readingLineFraction;

  /// Tell the reader, once and quietly, that the paragraph the bookmark named
  /// no longer exists and they have been put on the last one that does.
  ///
  /// Never a failure: the chapter opened and is readable. What would be wrong
  /// is landing somewhere else in silence, which reads as the app having lost
  /// their place.
  void _reportStaleAnchor(int requested, int available) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'This chapter changed — opened at paragraph $available '
            'instead of $requested.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  /// The exact reading position: which paragraph is under the reading line,
  /// and how far into it that line falls.
  ///
  /// Only the paragraphs the list has actually built have offsets to measure
  /// — the handful on screen — which is exactly the set the reading line can
  /// be in. `null` when nothing is laid out yet.
  ///
  /// The fraction is of the paragraph's own height and is not pixels: the
  /// same paragraph is three lines on a tablet and nine on a phone, so a
  /// pixel offset would name a different sentence on each.
  ({int index, double fraction})? _anchorAtReadingLine() {
    if (!mounted || !_scrollController.hasClients) return null;
    final readingLine = _readingLine();
    final attached = <int>[];
    final offsets = <double>[];
    for (var i = 0; i < _paragraphKeys.length; i++) {
      final box = _boxFor(i);
      if (box == null) continue;
      attached.add(i);
      offsets.add(box.localToGlobal(Offset.zero).dy);
    }
    if (attached.isEmpty) return null;
    final pick = activeParagraphIndex(offsets, readingLine);
    final index = attached[pick];
    final height = _boxFor(index)?.size.height ?? 0;
    final fraction = height <= 0
        ? 0.0
        : ((readingLine - offsets[pick]) / height).clamp(0.0, 1.0);
    return (index: index, fraction: fraction);
  }

  // ── Bookmark ─────────────────────────────────────────────────────────────

  /// Save the exact spot being read, in ONE action.
  ///
  /// Nothing is asked for — the paragraph, the point within it and the
  /// chapter's paragraph count are all things this screen already knows. The
  /// snippet is cut here, at capture time, and stored with the row: it is
  /// what makes a prose bookmark recognisable, and deriving it later would
  /// need the chapter's text, which is exactly what a phone with no signal
  /// does not have.
  Future<void> _handleBookmark() async {
    if (_bookmarkPending) return;
    final anchor = _anchorAtReadingLine();
    if (anchor == null) return;
    setState(() => _bookmarkPending = true);
    try {
      final chapter = widget.chapter;
      final total = chapter.paragraphs.length;
      final index = anchor.index + 1;
      final (snippet, _) =
          novelSnippetAt(chapter.paragraphs, index, anchor.fraction);
      final saved = await ref.read(bookmarkOutboxControllerProvider).create(
            id: (
              sourceId: chapter.sourceId,
              seriesKey: chapter.seriesKey,
              chapterKey: chapter.chapterKey,
            ),
            media: BookmarkMedia.novel,
            anchorIndex: index,
            anchorFraction: anchor.fraction,
            anchorTotal: total,
            chapterNumber: chapter.chapterNumber,
            snippet: snippet,
          );
      if (!mounted || saved == null || !context.mounted) return;
      final percent = bookmarkPositionPercent(index, anchor.fraction, total);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            percent == null
                ? 'Bookmark saved'
                : 'Bookmarked at $percent% of this chapter',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _bookmarkPending = false);
    }
  }

  // ── Progress ─────────────────────────────────────────────────────────────

  void _onScroll() {
    if (_pendingRestoreParagraph != null) return;
    _progressTimer ??= Timer(
      const Duration(milliseconds: _progressSaveMs),
      () {
        _progressTimer = null;
        _recordPosition();
      },
    );
    _maybeScheduleAutoNext();
  }

  /// Which paragraph is under the reading line, and what that means for
  /// progress.
  ///
  /// Only the paragraphs the list has actually built have offsets to measure,
  /// which is exactly the handful on screen — so the sparse set is collected
  /// here and [activeParagraphIndex] (a pure function, tested without a widget
  /// tree) picks from it.
  void _recordPosition() {
    final anchor = _anchorAtReadingLine();
    if (anchor == null) return;

    final position = progressForParagraph(
      anchor.index,
      widget.chapter.paragraphs.length,
    );
    if (position.bucket != _bucket.value) {
      // No setState: the notifier repaints only the chrome's percent.
      _bucket.value = position.bucket;
    }

    final push = nextProgressPush(position, _furthestSent);
    if (push == null) return;
    _furthestSent = push.bucket;
    unawaited(_saveProgress(push));
  }

  /// Local-first, exactly like the manga reader: every save goes to the
  /// on-device outbox and is flushed best-effort, so the reader never blocks
  /// on — or loses a save to — a flaky connection. The bucket rides in
  /// `last_page` and the bucket count in `page_count`, which is what lets the
  /// server's furthest-wins merge, the library's "continue reading" and the
  /// statistics service all work with no change at all.
  Future<void> _saveProgress(NovelProgressPosition position) async {
    final chapter = widget.chapter;
    await ref.read(progressOutboxControllerProvider).save(
          ProgressPush(
            sourceId: chapter.sourceId,
            seriesKey: chapter.seriesKey,
            chapterKey: chapter.chapterKey,
            chapterNumber: chapter.chapterNumber,
            lastPage: position.bucket,
            pageCount: position.buckets,
            isCompleted: position.completed,
            timeSpentSeconds: _clock.elapsed(DateTime.now()),
          ),
        );
    if (position.completed) {
      // Read-then-expire: starts the 48h phone-copy timer. A no-op when this
      // chapter was never downloaded.
      await ref.read(downloadsStoreProvider)?.markRead(
            (
              sourceId: chapter.sourceId,
              seriesKey: chapter.seriesKey,
              chapterKey: chapter.chapterKey,
            ),
          );
    }
  }

  // ── Seamless continuation ────────────────────────────────────────────────

  /// The manga reader's mechanism, unchanged: at the end of the chapter, if
  /// the user's auto-next preference is on and there is a next chapter, wait
  /// [_autoNextChapterMs] and go. Once per chapter — [_autoNextTriggered]
  /// makes a bounce at the bottom, or a second scroll event in the same
  /// window, incapable of firing it twice.
  void _maybeScheduleAutoNext() {
    final next = _nextKey;
    if (!ref.read(readerDefaultsProvider).autoNextChapter ||
        next == null ||
        _autoNextTriggered ||
        !_atEnd()) {
      _autoNextTimer?.cancel();
      _autoNextTimer = null;
      return;
    }
    if (_autoNextTimer != null) return;
    _autoNextTimer = Timer(
      const Duration(milliseconds: _autoNextChapterMs),
      () {
        if (!mounted || _autoNextTriggered) return;
        _autoNextTriggered = true;
        _openChapter(next);
      },
    );
  }

  bool _atEnd() {
    if (!_scrollController.hasClients) return false;
    final position = _scrollController.position;
    return position.pixels >= position.maxScrollExtent - 8;
  }

  void _openChapter(String chapterKey) {
    // `go`, not `push`: continuing a book replaces the chapter rather than
    // stacking one on top of the last, so Back always leaves the reader
    // instead of walking backwards through everything just read.
    context.go(
      RoutePaths.novelReader(
        widget.chapter.sourceId,
        widget.chapter.seriesKey,
        chapterKey,
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

  NovelSurfaceColors _surface(BuildContext context) {
    final stored = ref.watch(novelPaletteControllerProvider);
    final choice = NovelPalettes.resolveChoice(
      stored,
      appIsDark: Theme.of(context).brightness == Brightness.dark,
    );
    final palette = NovelPalettes.byId(choice);
    if (palette != null) return NovelSurfaceColors.fromPalette(palette);
    // "Follow app theme": inherit the app's own tokens rather than painting a
    // surface, so one rendering path covers both cases.
    final colors = context.colors;
    return NovelSurfaceColors(
      bg: colors.bg,
      ink: colors.fg,
      muted: colors.muted,
      isDark: Theme.of(context).brightness == Brightness.dark,
    );
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.chapter;
    final surface = _surface(context);
    final prefsKey = novelSeriesPrefsKey(chapter.sourceId, chapter.seriesKey);
    final prefs = ref.watch(novelPreferencesControllerProvider(prefsKey));
    final width = MediaQuery.sizeOf(context).width;
    final column = novelColumnWidth(
      measure: prefs.measure,
      fontSize: prefs.fontSize,
      available: width - 40,
    );

    return Scaffold(
      backgroundColor: surface.bg,
      body: Stack(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => setState(() => _chromeVisible = !_chromeVisible),
            child: Scrollbar(
              controller: _scrollController,
              child: CustomScrollView(
                controller: _scrollController,
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.symmetric(
                      horizontal: (width - column) / 2,
                    ),
                    sliver: SliverList.list(
                      children: [
                        SizedBox(height: MediaQuery.paddingOf(context).top + 72),
                        _ChapterHeading(
                          chapter: chapter,
                          surface: surface,
                          preferences: prefs,
                        ),
                      ],
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.symmetric(
                      horizontal: (width - column) / 2,
                    ),
                    sliver: NovelChapterView(
                      paragraphs: chapter.paragraphs,
                      palette: surface,
                      preferences: prefs,
                      paragraphKeys: _paragraphKeys,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _ChapterFoot(
                      chapter: chapter,
                      surface: surface,
                      onNext: _nextKey == null
                          ? null
                          : () => _openChapter(_nextKey!),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Only the percent depends on the bucket, so only this subtree
          // rebuilds when it moves — the paragraph list underneath does not.
          ValueListenableBuilder<int>(
            valueListenable: _bucket,
            builder: (context, bucket, _) => NovelReaderChrome(
              visible: _chromeVisible,
              surface: surface,
              title: chapter.title,
              percent: chapterPercent(bucket, chapter.buckets),
              isOffline: chapter.isOffline,
              onBack: () => leaveReader(
                context,
                sourceId: chapter.sourceId,
                seriesKey: chapter.seriesKey,
              ),
              onPrevious: _previousKey == null
                  ? null
                  : () => _openChapter(_previousKey!),
              onNext: _nextKey == null ? null : () => _openChapter(_nextKey!),
              onBookmark: _bookmarkPending ? null : _handleBookmark,
              onType: () => NovelTypePanel.show(
                context,
                seriesPrefsKey: prefsKey,
                surface: surface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The chapter's own front matter: number, title, length. Set as a book sets a
/// chapter opening — centred, with real air under it, so the first paragraph
/// starts on a clean page rather than immediately under a heading.
class _ChapterHeading extends StatelessWidget {
  const _ChapterHeading({
    required this.chapter,
    required this.surface,
    required this.preferences,
  });

  final NovelChapter chapter;
  final NovelSurfaceColors surface;
  final NovelPreferences preferences;

  @override
  Widget build(BuildContext context) {
    final stack = novelFontStack(preferences.fontFamily);
    final number = chapter.chapterNumber;
    return Padding(
      padding: const EdgeInsets.only(bottom: 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (number != null)
            Text(
              'Chapter ${formatChapterNumber(number)}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 2.4,
                fontWeight: FontWeight.w600,
                color: surface.muted,
              ),
            ),
          const SizedBox(height: 10),
          Text(
            chapter.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: stack.first,
              fontFamilyFallback: stack.sublist(1),
              fontSize: preferences.fontSize * 1.55,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: surface.ink,
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: Container(width: 48, height: 1, color: surface.rule),
          ),
          const SizedBox(height: 14),
          Text(
            formatChapterLength(chapter.wordCount) ?? '',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: surface.muted),
          ),
        ],
      ),
    );
  }
}

class _ChapterFoot extends StatelessWidget {
  const _ChapterFoot({
    required this.chapter,
    required this.surface,
    required this.onNext,
  });

  final NovelChapter chapter;
  final NovelSurfaceColors surface;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        48,
        24,
        MediaQuery.paddingOf(context).bottom + 72,
      ),
      child: Column(
        children: [
          Container(width: 48, height: 1, color: surface.rule),
          const SizedBox(height: 24),
          if (onNext != null)
            OutlinedButton(
              onPressed: onNext,
              style: OutlinedButton.styleFrom(
                foregroundColor: surface.ink,
                side: BorderSide(color: surface.rule),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
              ),
              child: const Text('Next chapter'),
            )
          else
            Text(
              chapter.isOffline
                  ? 'End of the downloaded copy'
                  : 'End of the book, for now',
              style: TextStyle(fontSize: 13, color: surface.muted),
            ),
        ],
      ),
    );
  }
}

class _NovelReaderSkeleton extends StatelessWidget {
  const _NovelReaderSkeleton();

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: NovelPalettes.dusk.bg,
        body: Center(
          child: CircularProgressIndicator(color: NovelPalettes.dusk.muted),
        ),
      );

}
