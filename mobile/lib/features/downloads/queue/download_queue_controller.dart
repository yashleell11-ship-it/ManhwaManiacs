import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';
import 'package:manhwamaniacs/features/downloads/models/storage_cap.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/retention_maintenance_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/storage_settings_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_constants.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_request_gate.dart';
import 'package:manhwamaniacs/features/downloads/services/chapter_page_fetcher.dart';
import 'package:manhwamaniacs/features/downloads/services/device_storage_info.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio_format.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

/// Why the queue isn't actively fetching right now.
enum DownloadQueuePauseReason {
  /// Nothing queued, or actively downloading.
  none,

  /// No active `(user, profile)` session — nothing to download into.
  noScope,

  /// Sideloaded iOS (and this app generally) has no dependable background
  /// execution — see `docs/OFFLINE_READING.md` "Known limitation". The queue
  /// resumes automatically the moment the app is foregrounded again.
  backgrounded,

  /// The ~1.5 GB free-space floor — independent of the user's cap, always
  /// enforced.
  freeSpaceFloor,

  /// The user's configured storage cap.
  cap,

  /// The user tapped Pause. The only reason that survives backgrounding and
  /// relaunch-free resumes untouched — every other one clears itself as soon
  /// as its condition lifts, and this one must not.
  userPaused,
}

class DownloadQueueState {
  const DownloadQueueState({
    this.isDownloading = false,
    this.pauseReason = DownloadQueuePauseReason.none,
    this.currentChapter,
    this.pagesDone = 0,
    this.pageTotal = 0,
    this.activeChapterCount = 0,
    this.queueRevision = 0,
  });

  /// True only while a page fetch is actually in flight — distinct from
  /// "has queued work", which the Downloads screen reads straight from the
  /// store instead (queued rows persist across app restarts; this flag does
  /// not).
  final bool isDownloading;
  final DownloadQueuePauseReason pauseReason;

  /// The chapter whose progress this state reports — the **lead** of the batch
  /// in flight, not the only member of it. With
  /// [downloadConcurrencyProvider] above one, siblings download alongside it;
  /// [activeChapterCount] is how many, and their rows read `downloading` in
  /// the store. Only the lead moves [pagesDone] so the bar stays monotonic
  /// instead of two workers taking turns overwriting each other's count.
  final ChapterIdentity? currentChapter;

  /// Pages of [currentChapter] already on disk, and how many it has in total.
  /// Both zero when nothing is downloading. [pageTotal] is 0 until the
  /// manifest lands, which is exactly the window where the UI should show an
  /// indeterminate bar rather than a misleading "0 of 0".
  final int pagesDone;
  final int pageTotal;

  /// How many chapters are mid-download right now, [currentChapter] included.
  /// 0 when idle, 1 on the serial setting. Exists so the UI can say that more
  /// is happening than the one chapter it has room to draw a bar for.
  final int activeChapterCount;

  /// Bumped on every change to *which rows exist and in what state* — a
  /// chapter queued, completed, failed or cancelled — and deliberately **not**
  /// on page-by-page progress.
  ///
  /// The store-backed providers (the downloads list, the per-series
  /// breakdown, the device byte total) re-query on this rather than on the
  /// whole state, so a 40-page chapter costs them one refresh instead of
  /// forty. Widgets that want the live page counter watch the state itself.
  final int queueRevision;

  bool get isPaused => pauseReason != DownloadQueuePauseReason.none;

  /// True when the pause is something the user can act on from the Downloads
  /// screen, as opposed to a transient state the queue clears by itself.
  bool get isBlocked =>
      pauseReason == DownloadQueuePauseReason.cap ||
      pauseReason == DownloadQueuePauseReason.freeSpaceFloor ||
      pauseReason == DownloadQueuePauseReason.userPaused;

  DownloadQueueState copyWith({
    bool? isDownloading,
    DownloadQueuePauseReason? pauseReason,
    ChapterIdentity? currentChapter,
    bool clearCurrentChapter = false,
    int? pagesDone,
    int? pageTotal,
    int? activeChapterCount,
    int? queueRevision,
  }) {
    return DownloadQueueState(
      isDownloading: isDownloading ?? this.isDownloading,
      pauseReason: pauseReason ?? this.pauseReason,
      currentChapter:
          clearCurrentChapter ? null : (currentChapter ?? this.currentChapter),
      pagesDone: pagesDone ?? this.pagesDone,
      pageTotal: pageTotal ?? this.pageTotal,
      activeChapterCount: activeChapterCount ?? this.activeChapterCount,
      queueRevision: queueRevision ?? this.queueRevision,
    );
  }
}

enum _ChapterOutcome {
  completed,
  failed,
  cancelled,
  pausedFloor,
  pausedCap,
  pausedUser,
}

/// The foreground-only download queue engine (spec §3): fetch manifest,
/// fetch pages at concurrency [kPageFetchConcurrency], write blobs, resume by
/// skipping pages already on disk, bounded retry, and hard-stop at the
/// free-space floor / storage cap without ever dropping a queued chapter or
/// touching an unread one.
///
/// Chapters are taken a batch at a time — [downloadConcurrencyProvider] wide —
/// and run concurrently, but every guard is still per chapter and unchanged:
/// each has its own row, its own retry bound, its own completeness check, and
/// re-checks the free-space floor, the storage cap, a pause and a cancel
/// between page chunks. A sibling failing, or being cancelled mid-flight,
/// costs that chapter and nothing else.
///
/// What the setting does *not* do is raise the request rate: every outbound
/// call goes through one [DownloadRequestGate] of [kQueueRequestConcurrency]
/// slots shared by the whole batch, so widening the batch overlaps the dead
/// time between chapters — manifest round trips, retry backoffs, blob writes —
/// rather than multiplying what lands on the server.
///
/// A durable queue, not an in-memory one: every "queued" row lives in
/// `saved_chapters` the instant [enqueueChapter] returns, so a kill mid-run
/// loses at most the current page — never the fact that a chapter was asked
/// for. [resumePendingOnLaunch] re-discovers that work on the next start.
///
/// Deliberately operates on whichever store `downloadsStoreProvider` reports
/// *right now* on every loop pass, rather than a store captured once: a
/// profile switch mid-download simply pauses that profile's queue (its rows
/// stay `queued`/`downloading`, resumed next time that profile — or a fresh
/// launch — reaches it) rather than juggling two profiles' fetches at once.
class DownloadQueueController extends Notifier<DownloadQueueState> {
  bool _foreground = true;
  bool _userPaused = false;
  bool _loopRunning = false;
  Future<void>? _activeRun;

  /// Row ids the user cancelled while the loop still owned their writes. See
  /// [cancelChapter] for why the deletion is deferred to the loop.
  final Set<int> _cancelledRowIds = {};

  /// Row ids of the batch currently mid-download. What [cancelChapter] tests
  /// to decide whether it may delete inline — the loop owns these rows' writes
  /// until it clears them, and with a batch wider than one that is no longer
  /// the same question as "is this the chapter on the progress bar".
  final Set<int> _inFlightRowIds = {};

  /// The one ceiling every outbound call in this queue passes through, shared
  /// across the whole batch so the user's chapter setting cannot multiply it.
  final DownloadRequestGate _gate =
      DownloadRequestGate(kQueueRequestConcurrency);

  /// Novel chapter text fetched ahead of the loop by [_primeNovelWindow],
  /// waiting for the pass that owns its row. Entries are removed as they are
  /// consumed, so this holds at most one window (a few tens of kilobytes of
  /// prose) and never a whole book.
  final Map<ChapterIdentity, NovelChapter> _novelWindow = {};

  /// How many chapters the next window asks for. Starts at the compiled-in
  /// guess and is replaced by the server's own `max_chapters` on the first
  /// success, or shrunk if the server rejects the batch as too large — so the
  /// stride is the deployment's, not the app's.
  int _novelWindowSize = kNovelWindowChapters;

  /// Chapter manifests fetched ahead of the loop by [_primeManifestWindow],
  /// waiting for the pass that owns their row. Held in memory only and never
  /// written to the store — see [_downloadOneChapter] for why a manifest that
  /// outlives the run that fetched it is not trustworthy.
  final Map<ChapterIdentity, ChapterManifest> _manifestWindow = {};

  /// [_novelWindowSize]'s counterpart for `POST /reader/chapters/manifest`.
  /// Separate because the two endpoints are capped by two separate settings
  /// server-side, so one deployment can raise one and not the other.
  int _manifestWindowSize = kManifestWindowChapters;

  /// When the queue may next spend a token on the shared `bulk` bucket, or
  /// null when it is free. Set by [_blockBulkWindows].
  DateTime? _bulkWindowBlockedUntil;

  /// Awaits the current processing pass, if one is running — **test-only**.
  /// Production callers must never await the queue draining: `enqueueChapter`
  /// et al. are deliberately fire-and-forget so the UI stays responsive while
  /// the reactive [DownloadQueueState] reports progress.
  @visibleForTesting
  Future<void> debugWaitUntilIdle() => _activeRun ?? Future<void>.value();

  @override
  DownloadQueueState build() {
    // A pass with no store stops at `noScope`, and nothing else would ever
    // start the next one: on a cold launch the lifecycle gate's first kick
    // lands before sign-in has resolved, and switching back to a profile with
    // pending rows kicks nothing at all. So a store appearing — or changing
    // to another scope's — is itself a reason to look for work. The store,
    // not the scope id, because it is what the loop reads and what tests pin.
    //
    // `listen`, never `watch`, here and below: a rebuild would reset the
    // pause flag, the in-flight bookkeeping and the prefetched windows.
    ref.listen<DownloadsStore?>(downloadsStoreProvider, (previous, next) {
      if (next == null || identical(previous, next)) return;
      if (!_foreground || _userPaused) return;
      unawaited(_kick());
    });
    // Raising (or lifting) the cap is the remedy the cap pause tells the user
    // to reach for; the loop re-checks the cap itself, so a kick that is still
    // over it simply pauses again with the same reason.
    ref.listen<StorageCap>(storageCapProvider, (previous, next) {
      if (previous != next) retryAfterStorageChange();
    });
    return const DownloadQueueState();
  }

  /// Restarts a queue that stopped at the storage cap or the free-space floor
  /// once the user has done something about it — deleted downloads, run
  /// "Free up space", or changed the cap. Both pauses only clear on a fresh
  /// pass, and without this one arrives only when the app is next brought to
  /// the foreground.
  ///
  /// Deliberately doesn't clear the pause reason itself: the pass re-checks
  /// every guard and sets whichever still applies. A deliberate pause is left
  /// alone, as it is everywhere else.
  void retryAfterStorageChange() {
    if (_userPaused) return;
    unawaited(_kick());
  }

  /// Marks a chapter for download and (re)starts the loop if it was idle.
  /// A no-op with no active scope — the caller's UI should already be
  /// hiding the download affordance in that case.
  Future<void> enqueueChapter({
    required ChapterIdentity id,
    double? chapterNumber,
    String? title,
    String? seriesTitle,
    DownloadKind kind = DownloadKind.manga,
  }) async {
    final store = ref.read(downloadsStoreProvider);
    if (store == null) return;
    await store.ensureQueued(
      id: id,
      chapterNumber: chapterNumber,
      title: title,
      seriesTitle: seriesTitle,
      kind: kind,
    );
    _bumpRevision();
    unawaited(_kick());
  }

  /// Queues every chapter in [chapters] — "Download series". Sequential
  /// `await`s rather than `Future.wait`: each call is a single fast insert,
  /// and running them one at a time keeps insertion order equal to queue
  /// order (`created_at`).
  ///
  /// One revision bump for the whole batch, not one per chapter: queueing a
  /// 200-chapter series must cost the store-backed lists a single refresh.
  Future<void> enqueueChapters(Iterable<ChapterQueueRequest> chapters) async {
    final store = ref.read(downloadsStoreProvider);
    if (store == null) return;
    for (final chapter in chapters) {
      await store.ensureQueued(
        id: chapter.id,
        chapterNumber: chapter.chapterNumber,
        title: chapter.title,
        seriesTitle: chapter.seriesTitle,
        kind: chapter.kind,
      );
    }
    _bumpRevision();
    unawaited(_kick());
  }

  /// Resets a failed chapter to `queued` and restarts the loop.
  /// `ensureQueued` already implements the reset — same call, named for the
  /// UI's "Retry" affordance.
  Future<void> retryChapter(ChapterIdentity id) => enqueueChapter(id: id);

  /// Re-discovers any `queued`/`downloading` rows left over from a previous
  /// run (a kill mid-chapter, or the app simply being closed) and resumes
  /// them. Safe to call repeatedly (a no-op once nothing is pending).
  void resumePendingOnLaunch() => unawaited(_kick());

  /// Holds the queue until [resume]. Queued rows are untouched — this is a
  /// pause, never a cancel — and the chapter mid-flight stops at its next
  /// page-chunk boundary with everything already fetched left on disk.
  void pause() {
    if (_userPaused) return;
    _userPaused = true;
    state = state.copyWith(
      isDownloading: false,
      pauseReason: DownloadQueuePauseReason.userPaused,
    );
  }

  void resume() {
    if (!_userPaused) return;
    _userPaused = false;
    state = state.copyWith(pauseReason: DownloadQueuePauseReason.none);
    unawaited(_kick());
  }

  /// Drops [id] from the queue and removes whatever it had already written.
  ///
  /// Cancelling a chapter the loop is *currently* fetching cannot delete its
  /// rows here: pages already in flight would insert `saved_pages` rows
  /// pointing at a chapter row that no longer exists, leaking the blob
  /// refcounts those rows hold. So that case is flagged and the loop performs
  /// the deletion itself once that chapter's worker lands — which it does
  /// whether or not its siblings are still fetching.
  Future<void> cancelChapter(ChapterIdentity id) async {
    final store = ref.read(downloadsStoreProvider);
    if (store == null) return;
    final chapter = await store.getChapter(id);
    if (chapter == null) return;

    if (_loopRunning && _inFlightRowIds.contains(chapter.rowId)) {
      _cancelledRowIds.add(chapter.rowId);
      _bumpRevision();
      return;
    }
    await store.deleteDownload(id);
    _bumpRevision();
  }

  /// Clears every chapter that is queued, mid-download or failed. Completed
  /// downloads are untouched — this empties the queue, it does not delete the
  /// user's library.
  Future<void> cancelAll() async {
    final store = ref.read(downloadsStoreProvider);
    if (store == null) return;
    _novelWindow.clear();
    _manifestWindow.clear();
    for (final chapter in await store.unfinishedChapters()) {
      await cancelChapter(chapter.identity);
    }
  }

  /// Toggled by the app-lifecycle gate. Backgrounding pauses the loop before
  /// its next network call; foregrounding restarts it — unless the user
  /// paused it by hand, which outlives a trip to the home screen.
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (foreground) {
      if (_userPaused) return;
      unawaited(_kick());
    } else {
      if (_userPaused) return;
      state = state.copyWith(
        isDownloading: false,
        pauseReason: DownloadQueuePauseReason.backgrounded,
      );
    }
  }

  void _bumpRevision() =>
      state = state.copyWith(queueRevision: state.queueRevision + 1);

  Future<void> _kick() {
    if (_loopRunning) return _activeRun ?? Future<void>.value();
    _loopRunning = true;
    final run = _processLoop().whenComplete(() => _loopRunning = false);
    _activeRun = run;
    return run;
  }

  Future<void> _processLoop() async {
    while (true) {
      if (_userPaused) {
        state = state.copyWith(
          isDownloading: false,
          pauseReason: DownloadQueuePauseReason.userPaused,
          activeChapterCount: 0,
        );
        return;
      }

      if (!_foreground) {
        state = state.copyWith(
          isDownloading: false,
          pauseReason: DownloadQueuePauseReason.backgrounded,
          clearCurrentChapter: true,
          activeChapterCount: 0,
        );
        return;
      }

      final store = ref.read(downloadsStoreProvider);
      if (store == null) {
        state = state.copyWith(
          isDownloading: false,
          pauseReason: DownloadQueuePauseReason.noScope,
          clearCurrentChapter: true,
          activeChapterCount: 0,
        );
        return;
      }

      final pending = await store.pendingChapters();
      if (pending.isEmpty) {
        // Nothing left to hand them to; a window kept past here would be
        // content for chapters the user has since cancelled.
        _novelWindow.clear();
        _manifestWindow.clear();
        state = state.copyWith(
          isDownloading: false,
          pauseReason: DownloadQueuePauseReason.none,
          clearCurrentChapter: true,
          pagesDone: 0,
          pageTotal: 0,
          activeChapterCount: 0,
        );
        return;
      }

      final floorBlocked = await _isBelowFreeSpaceFloor();
      if (floorBlocked) {
        state = state.copyWith(
          isDownloading: false,
          pauseReason: DownloadQueuePauseReason.freeSpaceFloor,
          activeChapterCount: 0,
        );
        return;
      }

      final capBlocked = await _isAtOrOverCap();
      if (capBlocked) {
        state = state.copyWith(
          isDownloading: false,
          pauseReason: DownloadQueuePauseReason.cap,
          activeChapterCount: 0,
        );
        return;
      }

      // The user's setting is read fresh each pass rather than watched: a
      // change takes effect on the next batch instead of disturbing chapters
      // already in flight.
      final width = ref.read(downloadConcurrencyProvider).chapters;
      final batch = pending.take(width).toList();
      final lead = batch.first;

      // Claimed before the priming awaits below, not after: a cancel that
      // lands in that gap must be deferred to this loop like any other, or it
      // deletes a row the batch is about to start writing into.
      _inFlightRowIds.addAll(batch.map((chapter) => chapter.rowId));

      // Windows are primed here, on the loop, with nothing else in flight —
      // never from inside a worker. Two workers on the same series would
      // otherwise each spend a token on the tightest bucket the server has to
      // fetch overlapping halves of one window.
      for (final chapter in batch) {
        if (chapter.kind.isNovel) {
          await _primeNovelWindow(chapter, pending);
        } else if (!chapter.kind.isAudio) {
          // Narration has no window: one file per chapter, fetched on its
          // own. Treated as manga here it asked for manifests of chapter
          // keys no source has, and the failure rested the bulk bucket for
          // every real manga download queued beside it.
          await _primeManifestWindow(chapter, pending);
        }
      }

      state = state.copyWith(
        isDownloading: true,
        pauseReason: DownloadQueuePauseReason.none,
        currentChapter: lead.identity,
        pagesDone: 0,
        pageTotal: lead.pageCount,
        activeChapterCount: batch.length,
      );

      // Every chapter is awaited even once one of them has decided to stop:
      // a sibling abandoned mid-write is how `saved_pages` rows outlive their
      // chapter. They each see the same pause/cancel flags at their next chunk
      // boundary and come back on their own.
      final outcomes = await Future.wait([
        for (final chapter in batch)
          _downloadOneChapter(
            store,
            chapter,
            reportsProgress: chapter.rowId == lead.rowId,
          ),
      ]);
      _inFlightRowIds.removeAll(batch.map((chapter) => chapter.rowId));

      for (final chapter in batch) {
        // A cancel that landed while this chapter was in flight is honoured
        // whatever its outcome was — including a chapter that finished a
        // moment too late to notice it had been cancelled.
        if (_cancelledRowIds.remove(chapter.rowId)) {
          await store.deleteDownload(chapter.identity);
        }
      }
      // One bump for the batch: the rows' states changed on disk and the
      // store-backed lists need to re-read, but three chapters landing
      // together must not cost them three re-queries.
      _bumpRevision();

      final stop = _stopReason(outcomes);
      if (stop != null) {
        state = state.copyWith(
          isDownloading: false,
          pauseReason: stop,
          activeChapterCount: 0,
        );
        return;
      }
      // Deliberately no reset here: the next pass either picks a new batch and
      // overwrites this, or leaves through a guard above that zeroes it. A
      // reset between batches would flicker the count to nothing mid-run.
    }
  }

  /// Why the loop should stop, if any chapter in the batch hit something that
  /// stops it. Ordered the way [_processLoop]'s own guards are — a deliberate
  /// pause outranks a disk limit — so the reason the user is shown is the same
  /// one they would get from a fresh pass.
  DownloadQueuePauseReason? _stopReason(List<_ChapterOutcome> outcomes) {
    if (outcomes.contains(_ChapterOutcome.pausedUser)) {
      return DownloadQueuePauseReason.userPaused;
    }
    if (outcomes.contains(_ChapterOutcome.pausedFloor)) {
      return DownloadQueuePauseReason.freeSpaceFloor;
    }
    if (outcomes.contains(_ChapterOutcome.pausedCap)) {
      return DownloadQueuePauseReason.cap;
    }
    return null;
  }

  Future<bool> _isBelowFreeSpaceFloor() async {
    final free = await ref.read(deviceStorageInfoProvider).freeSpaceBytes();
    // Undeterminable free space fails open — see DeviceStorageInfo's doc
    // comment: refusing to ever download without a working platform channel
    // would be a worse failure mode than the rare case this floor exists to
    // prevent.
    if (free == null) return false;
    return free < kFreeSpaceFloorBytes;
  }

  Future<bool> _isAtOrOverCap() async {
    final cap = ref.read(storageCapProvider).bytes;
    if (cap == null) return false; // StorageCap.unlimited
    final used = await ref.read(retentionMaintenanceProvider).totalDeviceBytes();
    return used >= cap;
  }

  /// Fetches the manifest, fetches every page not already on disk, and marks
  /// the chapter complete once every page is present. No manifest is ever
  /// PERSISTED and re-used — including on a resumed chapter whose page count
  /// is already known — because manifest page URLs can carry short-lived
  /// signed-proxy query parameters; a copy cached from before an app kill is
  /// not trustworthy for a fresh fetch, only
  /// [DownloadsStore.existingPageNumbers] (what's already safely on disk) is.
  ///
  /// [_primeManifestWindow]'s in-memory window is the one thing that may
  /// supply a manifest this pass did not fetch itself, and it stays on the
  /// right side of that rule: it is never written to the store, it is dropped
  /// whenever the queue empties or is cancelled, and it dies with the process.
  /// A window entry is also consumed exactly once, so should a page URL go
  /// stale anyway, the page retries fail, the chapter is re-queued, and the
  /// next pass fetches a fresh manifest over the network.
  Future<_ChapterOutcome> _downloadOneChapter(
    DownloadsStore store,
    SavedChapter chapter, {
    required bool reportsProgress,
  }) async {
    if (_cancelledRowIds.contains(chapter.rowId)) {
      return _ChapterOutcome.cancelled;
    }

    // Prose takes a different fetch and a different blob shape, but the same
    // row, the same retry bound and the same completeness guard — see
    // [_downloadOneNovelChapter].
    if (chapter.kind.isAudio) {
      return _downloadOneAudioChapter(
        store,
        chapter,
        reportsProgress: reportsProgress,
      );
    }
    if (chapter.kind.isNovel) {
      return _downloadOneNovelChapter(
        store,
        chapter,
        reportsProgress: reportsProgress,
      );
    }

    // Already fetched as part of a window. Removed on the way out: a chapter
    // is served from a window exactly once, so a retry after a failed page
    // fetch goes back to the network rather than replaying page URLs that may
    // be the reason the fetch failed.
    var manifest = _manifestWindow.remove(chapter.identity);
    if (manifest == null) {
      final manifestResult = await _gate.run(
        () => ref.read(readerRepositoryProvider).manifest(
              sourceId: chapter.sourceId,
              seriesKey: chapter.seriesKey,
              chapterKey: chapter.chapterKey,
            ),
      );
      if (manifestResult.isErr) {
        return _recordChapterFailure(
          store,
          chapter,
          manifestResult.error.userMessage,
        );
      }
      manifest = manifestResult.value;
    }
    if (manifest.pageCount <= 0 || manifest.pages.isEmpty) {
      return _recordChapterFailure(store, chapter, 'This chapter has no pages.');
    }

    await store.updateManifestInfo(
      rowId: chapter.rowId,
      pageCount: manifest.pageCount,
      chapterNumber: manifest.chapterNumber,
    );

    final pauseOutcome = await _fetchMissingPages(
      store,
      chapter.rowId,
      pages: manifest.pages,
      reportsProgress: reportsProgress,
    );
    if (pauseOutcome != null) return pauseOutcome;

    final completed = await store.markCompleteIfAllPagesPresent(chapter.rowId);
    if (completed) return _ChapterOutcome.completed;
    // One or more pages exhausted their own bounded retries — the chapter
    // itself still needs a bound, or a permanently-broken page would leave
    // this chapter `downloading` forever, re-picked by every loop pass.
    return _recordChapterFailure(
      store,
      chapter,
      'Some pages failed to download.',
    );
  }

  /// Fetches one novel chapter's text and stores it as a single blob.
  ///
  /// Deliberately the same *shape* as the manga path rather than a parallel
  /// pipeline: one row, `page_count = 1` (one blob, not one page), the same
  /// [_recordChapterFailure] retry bound, and the same
  /// [DownloadsStore.markCompleteIfAllPagesPresent] guard — which for a novel
  /// asks "is the one blob on disk?" and is exactly as load-bearing as it is
  /// for a forty-page chapter.
  ///
  /// There is no page loop, so no free-space/cap re-check mid-chapter: a
  /// chapter of prose is a single small write, and the loop already checked
  /// both immediately before picking this chapter up.
  ///
  /// The text may already be in hand from [_primeNovelWindow] — that is the
  /// only difference a window makes down here. Everything after the fetch is
  /// identical either way, deliberately: a whole-book download is not a
  /// separate pipeline, it is this one with fewer round trips.
  /// One chapter's narration: the opus and the timing map it was rendered
  /// with, stored as the audio row's two blobs.
  ///
  /// Its own row rather than a page on the text row, so the two download,
  /// retry, fail and delete independently — and so a reader is never kept
  /// from a chapter's TEXT while two megabytes of speech arrive.
  ///
  /// The server is asked with the CHAPTER's key, never the row's. The row is
  /// keyed `<chapter>:audio` so it cannot collide with the text row; the
  /// server has never heard of that key and answers 404, which is why every
  /// saved narration used to fail as "not narrated yet".
  ///
  /// The timing map is fetched first and saved with the audio: the reader's
  /// follow-along highlight needs it, there is no network to ask when the
  /// phone is offline, and a later re-render on the server would hand back a
  /// map that no longer matches these bytes.
  ///
  /// The bytes are asked for in the container this phone's player reads —
  /// MP4 on an iPhone, whose player cannot open Ogg at all — and checked
  /// before they are kept. A server that predates the `format` parameter
  /// answers Ogg whatever is asked, and a saved file nothing can play is
  /// worse than a failed save: it says "saved" and then plays nothing.
  ///
  /// Nothing else in the queue learns a new shape: the same request gate, the
  /// same retry bound, the same completeness guard, the same blob store with
  /// its refcounting and storage cap.
  Future<_ChapterOutcome> _downloadOneAudioChapter(
    DownloadsStore store,
    SavedChapter chapter, {
    required bool reportsProgress,
  }) async {
    final text = textIdentity(chapter.identity);
    final timing = await _gate.run(
      () => ref.read(novelsRepositoryProvider).audio(
            sourceId: text.sourceId,
            seriesKey: text.seriesKey,
            chapterKey: text.chapterKey,
          ),
    );
    if (timing.isErr) {
      return _recordChapterFailure(store, chapter, timing.error.userMessage);
    }
    if (!timing.value.available) {
      // The server has no audio for this chapter. Not retryable: waiting will
      // not produce it, and a render has to be asked for.
      return _recordChapterFailure(
        store, chapter, 'This chapter has not been narrated yet.',
      );
    }

    final platform = defaultTargetPlatform;
    final result = await _gate.run(
      () => ref.read(novelsRepositoryProvider).audioBytes(
            sourceId: text.sourceId,
            seriesKey: text.seriesKey,
            chapterKey: text.chapterKey,
            format: novelAudioFormatFor(platform),
          ),
    );
    if (result.isErr) {
      return _recordChapterFailure(store, chapter, result.error.userMessage);
    }
    final bytes = result.value;
    if (bytes.isEmpty) {
      return _recordChapterFailure(
        store, chapter, 'This chapter has not been narrated yet.',
      );
    }
    if (!canPlayNovelAudio(sniffNovelAudioFormat(bytes), platform)) {
      return _recordChapterFailure(
        store, chapter, 'The server sent audio this phone cannot play.',
      );
    }

    await store.updateManifestInfo(
      rowId: chapter.rowId,
      pageCount: DownloadsStore.audioBlobCount,
      chapterNumber: chapter.chapterNumber,
      title: chapter.title,
    );
    if (reportsProgress) {
      _reportPageProgress(done: 0, total: DownloadsStore.audioBlobCount);
    }

    try {
      await store.saveAudio(rowId: chapter.rowId, bytes: bytes);
      await store.saveAudioTiming(
        rowId: chapter.rowId,
        timing: timing.value.toJson(),
      );
    } catch (error) {
      return _recordChapterFailure(store, chapter, 'Could not save the audio.');
    }
    if (reportsProgress) {
      _reportPageProgress(
        done: DownloadsStore.audioBlobCount,
        total: DownloadsStore.audioBlobCount,
      );
    }

    if (_cancelledRowIds.contains(chapter.rowId)) {
      return _ChapterOutcome.cancelled;
    }
    final completed = await store.markCompleteIfAllPagesPresent(chapter.rowId);
    if (completed) return _ChapterOutcome.completed;
    return _recordChapterFailure(store, chapter, 'The audio failed to save.');
  }

  Future<_ChapterOutcome> _downloadOneNovelChapter(
    DownloadsStore store,
    SavedChapter chapter, {
    required bool reportsProgress,
  }) async {
    // Already fetched as part of a window (spec R5). Removed on the way out:
    // a chapter is served from a window exactly once, so a retry after a
    // failed WRITE goes back to the network rather than replaying text that
    // may be why the write failed.
    var novel = _novelWindow.remove(chapter.identity);
    if (novel == null) {
      final result = await _gate.run(
        () => ref.read(novelsRepositoryProvider).chapter(
              sourceId: chapter.sourceId,
              seriesKey: chapter.seriesKey,
              chapterKey: chapter.chapterKey,
            ),
      );
      if (result.isErr) {
        return _recordChapterFailure(store, chapter, result.error.userMessage);
      }
      novel = result.value;
    }
    if (novel.paragraphs.isEmpty) {
      return _recordChapterFailure(store, chapter, 'This chapter has no text.');
    }

    await store.updateManifestInfo(
      rowId: chapter.rowId,
      pageCount: 1,
      chapterNumber: novel.chapterNumber,
      title: novel.title,
    );
    if (reportsProgress) _reportPageProgress(done: 0, total: 1);

    try {
      await store.saveNovelText(
        rowId: chapter.rowId,
        chapter: novel.toStoredJson(),
      );
    } catch (error) {
      return _recordChapterFailure(store, chapter, 'Could not save the text.');
    }
    if (reportsProgress) _reportPageProgress(done: 1, total: 1);

    if (_cancelledRowIds.contains(chapter.rowId)) {
      return _ChapterOutcome.cancelled;
    }
    final completed = await store.markCompleteIfAllPagesPresent(chapter.rowId);
    if (completed) return _ChapterOutcome.completed;
    return _recordChapterFailure(store, chapter, 'The text failed to save.');
  }

  /// Fetches the next window of this book's queued chapters in one round trip
  /// (spec R5: "add download whole series for novels too").
  ///
  /// A novel chapter is kilobytes of text, so a 300-chapter book fetched one
  /// request at a time is almost entirely round-trip overhead. This looks
  /// ahead through the pending rows for chapters of the SAME book, asks for up
  /// to [_novelWindowSize] of them at once, and leaves the answers in
  /// [_novelWindow] for the passes that own those rows.
  ///
  /// Deliberately best-effort and invisible to everything downstream. A window
  /// that fails — offline, rate-limited, the endpoint missing on an older
  /// server — simply leaves the cache empty and every chapter takes the
  /// single-chapter path it always took. Nothing here can fail a download, and
  /// nothing here bypasses a guard: each chapter still gets its own row, its
  /// own retry bound and its own completeness check.
  Future<void> _primeNovelWindow(
    SavedChapter head,
    List<SavedChapter> pending,
  ) async {
    if (_novelWindow.containsKey(head.identity)) return;
    if (_bulkWindowBlocked) return;

    final keys = <String>[];
    for (final row in pending) {
      if (!row.kind.isNovel) continue;
      if (row.sourceId != head.sourceId) continue;
      if (row.seriesKey != head.seriesKey) continue;
      if (_novelWindow.containsKey(row.identity)) continue;
      if (keys.contains(row.chapterKey)) continue;
      keys.add(row.chapterKey);
      if (keys.length >= _novelWindowSize) break;
    }
    if (keys.length < kMinNovelWindowChapters) return;

    final result = await ref.read(novelsRepositoryProvider).chapterWindow(
          sourceId: head.sourceId,
          seriesKey: head.seriesKey,
          chapterKeys: keys,
        );

    if (result.isErr) {
      final error = result.error;
      if (error is ApiError && error.code == 'batch_too_large') {
        // The server's cap is lower than ours. Adopt its number when it says
        // one, otherwise halve — either way the next window fits, and this one
        // falls through to single fetches rather than being lost. A refusal
        // that did NOT shrink us is not a renegotiation, it is a wall: rest
        // the bucket rather than asking the same question every pass.
        final before = _novelWindowSize;
        _novelWindowSize =
            _capFromBatchTooLarge(error, kMinNovelWindowChapters) ??
                (keys.length ~/ 2)
                    .clamp(kMinNovelWindowChapters, _novelWindowSize);
        if (_novelWindowSize >= before) _blockBulkWindows();
        return;
      }
      _blockBulkWindows();
      return;
    }

    final window = result.value;
    if (window.maxChapters >= kMinNovelWindowChapters) {
      _novelWindowSize = window.maxChapters;
    }
    if (window.chapters.isEmpty) {
      // Every key came back an error. Asking again on the next pass would
      // spend a bulk token per chapter — more requests than the single-chapter
      // path this replaces, aimed at the tightest bucket we have.
      _blockBulkWindows();
      return;
    }
    for (final entry in window.chapters.entries) {
      _novelWindow[(
        sourceId: head.sourceId,
        seriesKey: head.seriesKey,
        chapterKey: entry.key,
      )] = entry.value;
    }
  }

  /// Fetches the next window of this series' queued chapters' manifests in one
  /// round trip (`POST /reader/chapters/manifest`).
  ///
  /// "Download this series" is the case this exists for: a 300-chapter series
  /// opens 300 manifest requests before a single page is on disk, and
  /// pipelining those to make it quick is what previously drew a real,
  /// minutes-long 429 from a source. Round trips and rate-limit safety are the
  /// win here — on a warm cache the window is not measurably faster
  /// server-side, because the floor is our own politeness spacing upstream.
  ///
  /// Deliberately best-effort and invisible to everything downstream, exactly
  /// as [_primeNovelWindow] is. A window that fails — offline, rate-limited,
  /// an older server without the endpoint — leaves the cache empty and every
  /// chapter takes the single-chapter path it always took. Nothing here can
  /// fail a download and nothing here bypasses a guard: each chapter still
  /// gets its own row, the concurrency cap, the free-space floor, the storage
  /// cap, pause/resume and its own retry bound.
  Future<void> _primeManifestWindow(
    SavedChapter head,
    List<SavedChapter> pending,
  ) async {
    if (_manifestWindow.containsKey(head.identity)) return;
    if (_bulkWindowBlocked) return;

    final keys = <String>[];
    for (final row in pending) {
      if (row.kind.isNovelSide) continue;
      if (row.sourceId != head.sourceId) continue;
      if (row.seriesKey != head.seriesKey) continue;
      if (_manifestWindow.containsKey(row.identity)) continue;
      if (keys.contains(row.chapterKey)) continue;
      keys.add(row.chapterKey);
      if (keys.length >= _manifestWindowSize) break;
    }
    if (keys.length < kMinManifestWindowChapters) return;

    final result = await ref.read(readerRepositoryProvider).manifestWindow(
          sourceId: head.sourceId,
          seriesKey: head.seriesKey,
          chapterKeys: keys,
        );

    if (result.isErr) {
      final error = result.error;
      if (error is ApiError && error.code == 'batch_too_large') {
        final before = _manifestWindowSize;
        _manifestWindowSize =
            _capFromBatchTooLarge(error, kMinManifestWindowChapters) ??
                (keys.length ~/ 2)
                    .clamp(kMinManifestWindowChapters, _manifestWindowSize);
        if (_manifestWindowSize >= before) _blockBulkWindows();
        return;
      }
      _blockBulkWindows();
      return;
    }

    final window = result.value;
    if (window.maxChapters >= kMinManifestWindowChapters) {
      _manifestWindowSize = window.maxChapters;
    }
    if (window.manifests.isEmpty) {
      _blockBulkWindows();
      return;
    }
    for (final entry in window.manifests.entries) {
      _manifestWindow[(
        sourceId: head.sourceId,
        seriesKey: head.seriesKey,
        chapterKey: entry.key,
      )] = entry.value;
    }
  }

  /// The cap the server named in a `batch_too_large` response, when it named
  /// one in the shape the reader/novel endpoints use (`details.max_chapters`)
  /// and it is still worth spending a bulk token on.
  int? _capFromBatchTooLarge(ApiError error, int floor) {
    final details = error.details;
    if (details is! Map) return null;
    final cap = details['max_chapters'];
    if (cap is num && cap >= floor) return cap.toInt();
    return null;
  }

  /// Rests the `bulk` bucket after a window came back useless.
  ///
  /// One cooldown for both window endpoints because the server charges them to
  /// ONE bucket — `core/rate_limit.py`'s `bulk_limit` covers
  /// `POST /reader/chapters/manifest` and `POST /novels/chapters` alike, sized
  /// far tighter than the single-chapter buckets because one call there is
  /// worth up to `max_chapters` upstream scrapes. A window that keeps failing
  /// must not turn into one bulk request per chapter.
  void _blockBulkWindows() =>
      _bulkWindowBlockedUntil = DateTime.now().add(kBulkWindowCooldown);

  bool get _bulkWindowBlocked {
    final until = _bulkWindowBlockedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// Bounded retry at the chapter level: increments `retry_count` and, once
  /// [kMaxChapterManifestRetries] is reached, marks the chapter
  /// [DownloadChapterState.failed] with [error] — visible on the Downloads
  /// screen with a retry action, never silently dropped. Below the bound, a
  /// short backoff runs before returning so a broken chapter can't spin the
  /// loop tight; the row itself is left as-is (still `queued`/`downloading`)
  /// so the next pass picks it back up.
  Future<_ChapterOutcome> _recordChapterFailure(
    DownloadsStore store,
    SavedChapter chapter,
    String error,
  ) async {
    await store.incrementRetry(chapter.rowId);
    final updated = await store.getChapter(chapter.identity);
    final retryCount = updated?.retryCount ?? kMaxChapterManifestRetries;
    if (retryCount >= kMaxChapterManifestRetries) {
      await store.markFailed(rowId: chapter.rowId, error: error);
      return _ChapterOutcome.failed;
    }
    await Future<void>.delayed(kChapterRetryBackoff);
    return _ChapterOutcome.failed;
  }

  /// Fetches every page in [pages] not already on disk, [kPageFetchConcurrency]
  /// at a time, re-checking the free-space floor, the storage cap, a user
  /// pause and a cancel between chunks so a single oversized chapter can
  /// genuinely stop mid-download. Returns a stop outcome when it had to bail
  /// early, or `null` to mean "kept going / finished" — the caller then checks
  /// page completeness.
  ///
  /// [kPageFetchConcurrency] is what this chapter *asks* for; the shared
  /// [DownloadRequestGate] is what it gets. Every sibling chapter runs this
  /// same loop, so the chunk size stays a per-chapter shape while the gate
  /// keeps the sum of them at [kQueueRequestConcurrency].
  Future<_ChapterOutcome?> _fetchMissingPages(
    DownloadsStore store,
    int rowId, {
    required List<ManifestPage> pages,
    required bool reportsProgress,
  }) async {
    final already = await store.existingPageNumbers(rowId);
    final missing = pages.where((p) => !already.contains(p.number)).toList();
    // A resumed chapter starts partway along the bar rather than at zero.
    var done = pages.length - missing.length;
    if (reportsProgress) _reportPageProgress(done: done, total: pages.length);

    for (var i = 0; i < missing.length; i += kPageFetchConcurrency) {
      if (_cancelledRowIds.contains(rowId)) return _ChapterOutcome.cancelled;
      if (_userPaused) return _ChapterOutcome.pausedUser;
      if (await _isBelowFreeSpaceFloor()) return _ChapterOutcome.pausedFloor;
      if (await _isAtOrOverCap()) return _ChapterOutcome.pausedCap;

      final chunk = missing.skip(i).take(kPageFetchConcurrency);
      await Future.wait(
        chunk.map((page) async {
          final saved = await _fetchOnePageWithRetry(
            store,
            rowId,
            number: page.number,
            url: page.url,
          );
          // Only a page actually on disk moves the bar — a page that
          // exhausted its retries must not read as progress.
          if (saved) {
            done++;
            if (reportsProgress) {
              _reportPageProgress(done: done, total: pages.length);
            }
          }
        }),
      );
    }
    return null;
  }

  void _reportPageProgress({required int done, required int total}) {
    state = state.copyWith(pagesDone: done, pageTotal: total);
  }

  /// Returns whether the page ended up on disk.
  Future<bool> _fetchOnePageWithRetry(
    DownloadsStore store,
    int rowId, {
    required int number,
    required String url,
  }) async {
    for (var attempt = 1; attempt <= kMaxPageRetries; attempt++) {
      try {
        // Only the fetch is inside the gate. Holding a slot across the blob
        // write would let SQLite contention — the thing the write is already
        // serialised by — narrow the network ceiling as well.
        final bytes = await _gate.run(
          () => ref.read(chapterPageFetcherProvider).fetchPageBytes(url),
        );
        if (bytes.isEmpty) throw StateError('Empty page response');
        await store.savePage(rowId: rowId, pageNumber: number, bytes: bytes);
        return true;
      } catch (_) {
        if (attempt >= kMaxPageRetries) return false; // leaves the page missing;
        // markCompleteIfAllPagesPresent will correctly refuse to complete,
        // so the chapter is retried (not silently marked done) next pass.
        await Future<void>.delayed(kPageRetryBackoff);
      }
    }
    return false;
  }
}

/// One chapter to enqueue — the shape `enqueueChapters` (from a "Download
/// series" action) takes, since the store itself has no way to learn a
/// connector's chapter list.
typedef ChapterQueueRequest = ({
  ChapterIdentity id,
  double? chapterNumber,
  String? title,
  String? seriesTitle,
  DownloadKind kind,
});

/// What to queue to keep [chapter]'s narration on the phone: its TEXT as
/// well as its audio.
///
/// Listening offline is the point of saving narration, and the reader opens a
/// chapter from its text — audio alone would be a file the phone cannot play
/// with the network off, and the follow-along highlight has nothing to light
/// up without the words. Both go through `ensureQueued`, so text already on
/// the phone is left exactly as it is. Text first, so the chapter is readable
/// before its megabytes of speech arrive.
List<ChapterQueueRequest> narrationDownloadRequests({
  required ChapterIdentity chapter,
  double? chapterNumber,
  String? title,
  String? seriesTitle,
}) {
  final text = textIdentity(chapter);
  return [
    (
      id: text,
      chapterNumber: chapterNumber,
      title: title,
      seriesTitle: seriesTitle,
      kind: DownloadKind.novel,
    ),
    (
      id: audioIdentity(text),
      chapterNumber: chapterNumber,
      title: title,
      seriesTitle: seriesTitle,
      kind: DownloadKind.audio,
    ),
  ];
}

final downloadQueueControllerProvider =
    NotifierProvider<DownloadQueueController, DownloadQueueState>(
  DownloadQueueController.new,
  name: 'downloadQueueController',
);
