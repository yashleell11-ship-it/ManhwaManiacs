import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/models/retention_policy.dart';
import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';
import 'package:manhwamaniacs/features/downloads/models/storage_cap.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_storage_providers.dart';
import 'package:manhwamaniacs/features/downloads/providers/retention_maintenance_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/series_download_status_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/storage_settings_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_constants.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
import 'package:manhwamaniacs/features/downloads/services/chapter_page_fetcher.dart';
import 'package:manhwamaniacs/features/downloads/services/device_storage_info.dart';
import 'package:manhwamaniacs/features/downloads/services/retention_maintenance.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';
import 'package:manhwamaniacs/features/reader/models/bookmark.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest_window.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/repositories/reader_repository.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

import '../../support/downloads_test_support.dart';

const _id = (sourceId: 'asura', seriesKey: 'solo-leveling', chapterKey: 'c1');

/// A [ReaderRepository] whose `manifest()` behaviour is fully scripted —
/// letting a test simulate a flaky or permanently-broken chapter without a
/// real network.
class _ScriptedReaderRepository implements ReaderRepository {
  _ScriptedReaderRepository(this._manifest);

  final Future<Result<ChapterManifest>> Function() _manifest;
  int calls = 0;

  @override
  Future<Result<ChapterManifest>> manifest({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) {
    calls++;
    return _manifest();
  }

  @override
  Future<Result<ReadingProgress>> saveProgress(ProgressPush push) =>
      throw UnimplementedError();

  @override
  Future<Result<({int saved, int advanced})>> saveProgressBatch(
    List<ProgressPush> pushes,
  ) =>
      throw UnimplementedError();

  @override
  Future<Result<List<ReadingProgress>>> seriesProgress({
    required String sourceId,
    required String seriesKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<BookmarkSyncResult>> syncBookmarks(List<BookmarkOp> ops) =>
      throw UnimplementedError();

  @override
  Future<Result<List<Bookmark>>> listBookmarks({
    String? sourceId,
    String? seriesKey,
    DateTime? since,
    bool includeDeleted = false,
    int? limit,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> deleteBookmark(int bookmarkId) =>
      throw UnimplementedError();

  @override
  Future<Result<ChapterManifestWindow>> manifestWindow({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) =>
      throw UnimplementedError();
}

ChapterManifest _manifestWithPages(int pageCount) => ChapterManifest(
      sourceId: _id.sourceId,
      seriesKey: _id.seriesKey,
      chapterKey: _id.chapterKey,
      chapterNumber: 1,
      pageCount: pageCount,
      prev: null,
      next: null,
      pages: [
        for (var i = 1; i <= pageCount; i++)
          ManifestPage(number: i, url: '/sources/asura/pages/$i/image'),
      ],
    );

/// A [ChapterPageFetcher] whose behaviour per URL is fully scripted.
class _ScriptedPageFetcher implements ChapterPageFetcher {
  _ScriptedPageFetcher(this._fetch, {this.onFetch});

  final Future<List<int>> Function(String url) _fetch;
  final void Function(String url)? onFetch;

  @override
  Future<List<int>> fetchPageBytes(String url) {
    onFetch?.call(url);
    return _fetch(url);
  }
}

class _FixedDeviceStorageInfo implements DeviceStorageInfo {
  _FixedDeviceStorageInfo(this.bytes);
  int? bytes;

  @override
  Future<int?> freeSpaceBytes() async => bytes;
}

void main() {
  initSqfliteFfiForTests();

  late TestDownloadsHarness harness;

  setUp(() async {
    harness = await TestDownloadsHarness.create();
  });

  tearDown(() async {
    await harness.dispose();
  });

  ProviderContainer buildContainer({
    required ReaderRepository readerRepository,
    required ChapterPageFetcher pageFetcher,
    DeviceStorageInfo? deviceStorageInfo,
    StorageCap storageCap = StorageCap.unlimited,
    Override? storeOverride,
  }) {
    final container = ProviderContainer(
      overrides: [
        storeOverride ??
            downloadsStoreProvider.overrideWithValue(harness.storeFor('u1p1')),
        retentionMaintenanceProvider.overrideWithValue(
          RetentionMaintenance(
            database: harness.openDatabase(),
            blobStore: harness.openBlobStore(),
          ),
        ),
        readerRepositoryProvider.overrideWithValue(readerRepository),
        chapterPageFetcherProvider.overrideWithValue(pageFetcher),
        deviceStorageInfoProvider.overrideWithValue(
          deviceStorageInfo ?? _FixedDeviceStorageInfo(10 * 1024 * 1024 * 1024),
        ),
        storageCapProvider.overrideWith(
          () => _FixedStorageCapNotifier(storageCap),
        ),
        // Only "Free up space" reads it; Off keeps its sweep out of the way
        // of the cap eviction those tests are about.
        retentionIntervalProvider.overrideWith(_FixedRetentionIntervalNotifier.new),
        downloadConcurrencyOverride(),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('downloads every page and marks the chapter complete', () async {
    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(3)),
      ),
      pageFetcher: _ScriptedPageFetcher((url) async => [1, 2, 3]),
    );

    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapter(id: _id);
    await controller.debugWaitUntilIdle();

    final store = harness.storeFor('u1p1');
    final chapter = await store.getChapter(_id);
    expect(chapter!.state, DownloadChapterState.complete);
    expect(chapter.pageCount, 3);

    final state = container.read(downloadQueueControllerProvider);
    expect(state.isDownloading, isFalse);
    expect(state.pauseReason, DownloadQueuePauseReason.none);
  });

  test('resumes only the missing pages after a simulated kill mid-chapter',
      () async {
    final store = harness.storeFor('u1p1');
    final rowId = await store.ensureQueued(id: _id);
    await store.updateManifestInfo(rowId: rowId, pageCount: 3);
    await store.savePage(rowId: rowId, pageNumber: 1, bytes: [1]);
    // Page 2 and 3 never landed — simulating an app kill.

    final requestedUrls = <String>[];
    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(3)),
      ),
      pageFetcher: _ScriptedPageFetcher(
        (url) async => [9],
        onFetch: requestedUrls.add,
      ),
    );

    final controller = container.read(downloadQueueControllerProvider.notifier);
    controller.resumePendingOnLaunch();
    await controller.debugWaitUntilIdle();

    // Only pages 2 and 3 should ever have been requested — page 1 was
    // already on disk.
    expect(requestedUrls, hasLength(2));
    expect(requestedUrls.any((u) => u.contains('/1/image')), isFalse);

    final resumedStore = harness.storeFor('u1p1');
    expect((await resumedStore.getChapter(_id))!.state,
        DownloadChapterState.complete,);
  });

  test('fetches at most kPageFetchConcurrency pages at once', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(6)),
      ),
      pageFetcher: _ScriptedPageFetcher((url) async {
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        return [1];
      }),
    );

    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapter(id: _id);
    await controller.debugWaitUntilIdle();

    expect(maxInFlight, lessThanOrEqualTo(kPageFetchConcurrency));
    expect(maxInFlight, greaterThan(0));
  });

  test(
      'bounded retry: a permanently-broken manifest is marked failed, not '
      'retried forever', () async {
    final repo = _ScriptedReaderRepository(
      () async => const Err(NetworkError(message: 'offline')),
    );
    final container = buildContainer(
      readerRepository: repo,
      pageFetcher: _ScriptedPageFetcher((url) async => [1]),
    );

    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapter(id: _id);
    // 3 retries with a real 2s backoff between them — fake_async/clock
    // control isn't wired up here, so this genuinely waits.
    await controller.debugWaitUntilIdle();

    expect(repo.calls, kMaxChapterManifestRetries);
    final store = harness.storeFor('u1p1');
    final chapter = await store.getChapter(_id);
    expect(chapter!.state, DownloadChapterState.failed);
    expect(chapter.error, isNotNull);

    final state = container.read(downloadQueueControllerProvider);
    expect(state.pauseReason, DownloadQueuePauseReason.none,
        reason: 'a failed chapter must not block the rest of the queue',);
  }, timeout: const Timeout(Duration(seconds: 15)),);

  test('retrying a failed chapter resets it and downloads successfully',
      () async {
    var shouldFail = true;
    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(() async {
        if (shouldFail) return const Err(NetworkError(message: 'offline'));
        return Ok(_manifestWithPages(1));
      }),
      pageFetcher: _ScriptedPageFetcher((url) async => [1]),
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);

    await controller.enqueueChapter(id: _id);
    await controller.debugWaitUntilIdle();
    final store = harness.storeFor('u1p1');
    expect((await store.getChapter(_id))!.state, DownloadChapterState.failed);

    shouldFail = false;
    await controller.retryChapter(_id);
    await controller.debugWaitUntilIdle();

    expect((await store.getChapter(_id))!.state, DownloadChapterState.complete);
  }, timeout: const Timeout(Duration(seconds: 15)),);

  test('pauses at the free-space floor without dropping the queued chapter',
      () async {
    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(2)),
      ),
      pageFetcher: _ScriptedPageFetcher((url) async => [1]),
      deviceStorageInfo: _FixedDeviceStorageInfo(kFreeSpaceFloorBytes - 1),
    );

    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapter(id: _id);
    await controller.debugWaitUntilIdle();

    final state = container.read(downloadQueueControllerProvider);
    expect(state.pauseReason, DownloadQueuePauseReason.freeSpaceFloor);
    expect(state.isDownloading, isFalse);

    // The chapter was never even started — still queued, not dropped.
    final store = harness.storeFor('u1p1');
    expect((await store.getChapter(_id))!.state, DownloadChapterState.queued);
  });

  test('pauses at the storage cap without dropping the queued chapter',
      () async {
    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(2)),
      ),
      pageFetcher: _ScriptedPageFetcher((url) async => [1]),
      storageCap: StorageCap.gb2,
    );
    // Force totalDeviceBytes() (via the harness's real db) above the 2 GB cap
    // by inserting an oversized blob row directly.
    final db = await harness.openDatabase();
    await db.insert('blobs', {
      'hash': 'huge',
      'refcount': 1,
      'size': 3 * 1024 * 1024 * 1024,
    });

    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapter(id: _id);
    await controller.debugWaitUntilIdle();

    final state = container.read(downloadQueueControllerProvider);
    expect(state.pauseReason, DownloadQueuePauseReason.cap);

    final store = harness.storeFor('u1p1');
    expect((await store.getChapter(_id))!.state, DownloadChapterState.queued);
  });

  test('a backgrounded app pauses the queue instead of downloading', () async {
    var fetchCount = 0;
    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(2)),
      ),
      pageFetcher: _ScriptedPageFetcher((url) async {
        fetchCount++;
        return [1];
      }),
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);
    controller.setForeground(false);

    await controller.enqueueChapter(id: _id);
    await controller.debugWaitUntilIdle();

    expect(fetchCount, 0);
    expect(container.read(downloadQueueControllerProvider).pauseReason,
        DownloadQueuePauseReason.backgrounded,);

    controller.setForeground(true);
    await controller.debugWaitUntilIdle();

    expect(fetchCount, 2);
  });

  test('pause holds the queue mid-chapter; resume finishes what it started',
      () async {
    late DownloadQueueController controller;
    final requested = <String>[];
    var pausedOnce = false;
    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(6)),
      ),
      pageFetcher: _ScriptedPageFetcher(
        (url) async {
          // Pause once, as soon as the first chunk is in flight: the queue
          // must stop at the next chunk boundary, not abandon what it has.
          if (!pausedOnce) {
            pausedOnce = true;
            controller.pause();
          }
          return [1];
        },
        onFetch: requested.add,
      ),
    );
    controller = container.read(downloadQueueControllerProvider.notifier);

    await controller.enqueueChapter(id: _id);
    await controller.debugWaitUntilIdle();

    expect(requested, hasLength(kPageFetchConcurrency));
    expect(
      container.read(downloadQueueControllerProvider).pauseReason,
      DownloadQueuePauseReason.userPaused,
    );
    final store = harness.storeFor('u1p1');
    final held = await store.getChapter(_id);
    // Held, not dropped and not falsely completed.
    expect(held!.state, DownloadChapterState.downloading);
    expect(await store.existingPageNumbers(held.rowId), {1, 2});

    controller.resume();
    await controller.debugWaitUntilIdle();

    expect((await store.getChapter(_id))!.state, DownloadChapterState.complete);
    // The two pages already on disk were never re-fetched.
    expect(requested, hasLength(6));
  });

  test('a user pause outlives a trip to the home screen', () async {
    var fetchCount = 0;
    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(2)),
      ),
      pageFetcher: _ScriptedPageFetcher((url) async {
        fetchCount++;
        return [1];
      }),
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);
    controller.pause();

    await controller.enqueueChapter(id: _id);
    await controller.debugWaitUntilIdle();
    expect(fetchCount, 0);

    // Backgrounding and returning must not silently undo a deliberate pause:
    // every other pause reason clears itself, this one only clears on resume.
    controller.setForeground(false);
    controller.setForeground(true);
    await controller.debugWaitUntilIdle();

    expect(fetchCount, 0);
    expect(
      container.read(downloadQueueControllerProvider).pauseReason,
      DownloadQueuePauseReason.userPaused,
    );

    controller.resume();
    await controller.debugWaitUntilIdle();
    expect(fetchCount, 2);
  });

  test('cancelling a queued chapter removes its row and frees its bytes',
      () async {
    final store = harness.storeFor('u1p1');
    final rowId = await store.ensureQueued(id: _id);
    await store.updateManifestInfo(rowId: rowId, pageCount: 3);
    await store.savePage(rowId: rowId, pageNumber: 1, bytes: [1, 2, 3]);

    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(3)),
      ),
      pageFetcher: _ScriptedPageFetcher((url) async => [9]),
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);
    // Deliberately not running: this is the "cancel something waiting in the
    // queue" path, which deletes inline.
    controller.pause();

    await controller.cancelChapter(_id);

    expect(await store.getChapter(_id), isNull);
    final db = await harness.openDatabase();
    expect(await db.query('saved_pages'), isEmpty);
    expect(await db.query('blobs'), isEmpty);
  });

  test('cancelling the chapter being fetched leaks no pages, blobs or files',
      () async {
    late DownloadQueueController controller;
    Future<void>? cancelling;
    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(8)),
      ),
      pageFetcher: _ScriptedPageFetcher((url) async {
        // Cancel while the loop still owns this row's writes — the case that
        // would otherwise insert saved_pages rows against a deleted chapter
        // and strand the blob refcounts they hold.
        cancelling ??= controller.cancelChapter(_id);
        return [for (var i = 0; i < 16; i++) url.hashCode & 0xFF];
      }),
    );
    controller = container.read(downloadQueueControllerProvider.notifier);

    await controller.enqueueChapter(id: _id);
    await controller.debugWaitUntilIdle();
    await cancelling;
    // The cancel may have landed after the loop finished the chapter; either
    // way the loop drains once more before it settles.
    await controller.debugWaitUntilIdle();

    final store = harness.storeFor('u1p1');
    expect(await store.getChapter(_id), isNull);

    final db = await harness.openDatabase();
    expect(await db.query('saved_chapters'), isEmpty);
    expect(await db.query('saved_pages'), isEmpty);
    expect(await db.query('blobs'), isEmpty);

    final blobs = await harness.openBlobStore();
    final leftOver = blobs.rootDirectory.existsSync()
        ? blobs.rootDirectory
            .listSync(recursive: true)
            .whereType<File>()
            .toList()
        : <File>[];
    expect(leftOver, isEmpty, reason: 'blob files outlived their last ref');
  });

  test('cancelAll empties the queue but keeps finished downloads', () async {
    const other = (
      sourceId: 'asura',
      seriesKey: 'solo-leveling',
      chapterKey: 'c2',
    );
    final store = harness.storeFor('u1p1');

    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(1)),
      ),
      pageFetcher: _ScriptedPageFetcher((url) async => [7]),
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);

    // One chapter downloaded for real...
    await controller.enqueueChapter(id: _id);
    await controller.debugWaitUntilIdle();
    expect((await store.getChapter(_id))!.state, DownloadChapterState.complete);

    // ...and one left waiting behind a pause.
    controller.pause();
    await controller.enqueueChapter(id: other);
    await controller.debugWaitUntilIdle();

    await controller.cancelAll();

    expect(await store.getChapter(other), isNull);
    expect((await store.getChapter(_id))!.state, DownloadChapterState.complete);
  });

  test('queueing a batch bumps the list revision once, not once per chapter',
      () async {
    final container = buildContainer(
      readerRepository: _ScriptedReaderRepository(
        () async => Ok(_manifestWithPages(1)),
      ),
      pageFetcher: _ScriptedPageFetcher((url) async => [1]),
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);
    controller.pause();

    final before = container.read(downloadQueueControllerProvider).queueRevision;
    await controller.enqueueChapters([
      for (var i = 0; i < 5; i++)
        (
          id: (
            sourceId: 'asura',
            seriesKey: 'solo-leveling',
            chapterKey: 'c$i',
          ),
          chapterNumber: i.toDouble(),
          title: null,
          seriesTitle: 'Solo Leveling',
          kind: DownloadKind.manga,
        ),
    ]);
    await controller.debugWaitUntilIdle();

    // A 200-chapter "download series" must cost the store-backed lists one
    // re-query, not two hundred.
    expect(
      container.read(downloadQueueControllerProvider).queueRevision - before,
      1,
    );
    expect(await harness.storeFor('u1p1').pendingChapters(), hasLength(5));
  });

  group('a chapter whose files were deleted by hand', () {
    Future<DownloadsStore> savedThenEmptied() async {
      final store = harness.storeFor('u1p1');
      final rowId = await store.ensureQueued(id: _id);
      await store.updateManifestInfo(rowId: rowId, pageCount: 3);
      for (var page = 1; page <= 3; page++) {
        await store.savePage(rowId: rowId, pageNumber: page, bytes: [page]);
      }
      expect(await store.markCompleteIfAllPagesPresent(rowId), isTrue);
      await (await store.localPagePaths(_id))[2]!.delete();
      return store;
    }

    test('no longer reads as saved on the series page', () async {
      await savedThenEmptied();
      final container = buildContainer(
        readerRepository: _ScriptedReaderRepository(
          () async => Ok(_manifestWithPages(3)),
        ),
        pageFetcher: _ScriptedPageFetcher((url) async => [2]),
      );

      final statuses = await container.read(
        seriesChapterDownloadStatusProvider(
          (sourceId: _id.sourceId, seriesKey: _id.seriesKey),
        ).future,
      );

      expect(statuses, isEmpty);
    });

    test('downloading it again fetches just the missing page', () async {
      final store = await savedThenEmptied();
      final requested = <String>[];
      final container = buildContainer(
        readerRepository: _ScriptedReaderRepository(
          () async => Ok(_manifestWithPages(3)),
        ),
        pageFetcher: _ScriptedPageFetcher(
          (url) async => [2],
          onFetch: requested.add,
        ),
      );

      final controller =
          container.read(downloadQueueControllerProvider.notifier);
      await controller.enqueueChapter(id: _id);
      await controller.debugWaitUntilIdle();

      expect(requested, hasLength(1));
      expect(requested.single, contains('/2/image'));
      expect(await store.isAvailableOffline(_id), isTrue);
    });
  });

  group('a scope appearing after the first pass', () {
    // Stands in for sign-in: null until the test says the session resolved,
    // which on a cold launch is well after the lifecycle gate's first kick.
    late StateProvider<DownloadsStore?> session;

    setUp(() {
      session = StateProvider<DownloadsStore?>((ref) => null);
    });

    Override sessionStore() =>
        downloadsStoreProvider.overrideWith((ref) => ref.watch(session));

    test('resumes rows left queued by the last run', () async {
      final store = harness.storeFor('u1p1');
      await store.ensureQueued(id: _id);

      final container = buildContainer(
        readerRepository: _ScriptedReaderRepository(
          () async => Ok(_manifestWithPages(2)),
        ),
        pageFetcher: _ScriptedPageFetcher((url) async => [1]),
        storeOverride: sessionStore(),
      );
      final controller =
          container.read(downloadQueueControllerProvider.notifier);
      controller.resumePendingOnLaunch();
      await controller.debugWaitUntilIdle();
      expect(
        container.read(downloadQueueControllerProvider).pauseReason,
        DownloadQueuePauseReason.noScope,
      );

      container.read(session.notifier).state = store;
      await container.pump();
      await controller.debugWaitUntilIdle();

      expect(
        (await store.getChapter(_id))!.state,
        DownloadChapterState.complete,
      );
      expect(
        container.read(downloadQueueControllerProvider).pauseReason,
        DownloadQueuePauseReason.none,
      );
    });

    test('leaves a deliberate pause alone', () async {
      final store = harness.storeFor('u1p1');
      await store.ensureQueued(id: _id);
      var fetchCount = 0;

      final container = buildContainer(
        readerRepository: _ScriptedReaderRepository(
          () async => Ok(_manifestWithPages(2)),
        ),
        pageFetcher: _ScriptedPageFetcher((url) async {
          fetchCount++;
          return [1];
        }),
        storeOverride: sessionStore(),
      );
      final controller =
          container.read(downloadQueueControllerProvider.notifier);
      controller.pause();

      container.read(session.notifier).state = store;
      await container.pump();
      await controller.debugWaitUntilIdle();

      expect(fetchCount, 0);
      expect(
        (await store.getChapter(_id))!.state,
        DownloadChapterState.queued,
      );
    });
  });

  group('a storage pause clears once the user makes room', () {
    // Pushes the device total past a 2 GB cap without writing 3 GB: the cap
    // is enforced against the blobs table, so one oversized row is enough.
    Future<void> fillPastTwoGigabytes() async {
      final db = await harness.openDatabase();
      await db.insert('blobs', {
        'hash': 'huge',
        'refcount': 1,
        'size': 3 * 1024 * 1024 * 1024,
      });
    }

    Future<(ProviderContainer, DownloadQueueController)> pausedAtCap() async {
      final container = buildContainer(
        readerRepository: _ScriptedReaderRepository(
          () async => Ok(_manifestWithPages(2)),
        ),
        pageFetcher: _ScriptedPageFetcher((url) async => [1]),
        storageCap: StorageCap.gb2,
      );
      await fillPastTwoGigabytes();
      final controller =
          container.read(downloadQueueControllerProvider.notifier);
      await controller.enqueueChapter(id: _id);
      await controller.debugWaitUntilIdle();
      expect(
        container.read(downloadQueueControllerProvider).pauseReason,
        DownloadQueuePauseReason.cap,
      );
      return (container, controller);
    }

    test('raising the cap restarts the queue', () async {
      final (container, controller) = await pausedAtCap();

      await container
          .read(storageCapProvider.notifier)
          .setCap(StorageCap.unlimited);
      await controller.debugWaitUntilIdle();

      expect(
        (await harness.storeFor('u1p1').getChapter(_id))!.state,
        DownloadChapterState.complete,
      );
      expect(
        container.read(downloadQueueControllerProvider).pauseReason,
        DownloadQueuePauseReason.none,
      );
    });

    test('a cap still too low pauses again with the same reason', () async {
      final (container, controller) = await pausedAtCap();

      await container.read(storageCapProvider.notifier).setCap(StorageCap.gb2);
      await controller.debugWaitUntilIdle();

      expect(
        container.read(downloadQueueControllerProvider).pauseReason,
        DownloadQueuePauseReason.cap,
      );
      expect(
        (await harness.storeFor('u1p1').getChapter(_id))!.state,
        DownloadChapterState.queued,
      );
    });

    test('deleting downloads and retrying restarts the queue', () async {
      final (container, controller) = await pausedAtCap();

      // What any delete path does to the device total.
      final db = await harness.openDatabase();
      await db.delete('blobs', where: 'hash = ?', whereArgs: ['huge']);
      controller.retryAfterStorageChange();
      await controller.debugWaitUntilIdle();

      expect(
        (await harness.storeFor('u1p1').getChapter(_id))!.state,
        DownloadChapterState.complete,
      );
    });

    test('"Free up space" restarts the queue once it has made room',
        () async {
      // A chapter already read, holding the bytes that put the device over
      // the cap — exactly what eviction is allowed to take.
      const read = (
        sourceId: 'asura',
        seriesKey: 'omniscient-reader',
        chapterKey: 'c9',
      );
      final store = harness.storeFor('u1p1');
      final readRow = await store.ensureQueued(id: read);
      await store.updateManifestInfo(rowId: readRow, pageCount: 1);
      await store.savePage(rowId: readRow, pageNumber: 1, bytes: [5, 5]);
      expect(await store.markCompleteIfAllPagesPresent(readRow), isTrue);
      await store.markRead(read);
      final db = await harness.openDatabase();
      await db.update('blobs', {'size': 3 * 1024 * 1024 * 1024});

      final container = buildContainer(
        readerRepository: _ScriptedReaderRepository(
          () async => Ok(_manifestWithPages(2)),
        ),
        pageFetcher: _ScriptedPageFetcher((url) async => [1]),
        storageCap: StorageCap.gb2,
      );
      final controller =
          container.read(downloadQueueControllerProvider.notifier);
      await controller.enqueueChapter(id: _id);
      await controller.debugWaitUntilIdle();
      expect(
        container.read(downloadQueueControllerProvider).pauseReason,
        DownloadQueuePauseReason.cap,
      );

      final removed =
          await container.read(downloadsStorageActionsProvider).freeUpSpace();
      await controller.debugWaitUntilIdle();

      expect(removed, 1);
      expect(
        (await store.getChapter(_id))!.state,
        DownloadChapterState.complete,
      );
    });

    test('a user pause is not undone by a storage change', () async {
      final (container, controller) = await pausedAtCap();
      controller.pause();

      await container
          .read(storageCapProvider.notifier)
          .setCap(StorageCap.unlimited);
      controller.retryAfterStorageChange();
      await controller.debugWaitUntilIdle();

      expect(
        container.read(downloadQueueControllerProvider).pauseReason,
        DownloadQueuePauseReason.userPaused,
      );
      expect(
        (await harness.storeFor('u1p1').getChapter(_id))!.state,
        DownloadChapterState.queued,
      );
    });
  });
}

class _FixedRetentionIntervalNotifier extends RetentionIntervalNotifier {
  @override
  RetentionInterval build() => RetentionInterval.off;
}

class _FixedStorageCapNotifier extends StorageCapNotifier {
  _FixedStorageCapNotifier(this._cap);
  final StorageCap _cap;

  @override
  StorageCap build() => _cap;

  /// The real one also writes SharedPreferences, which these tests never
  /// stand up; the queue only ever sees the state change.
  @override
  Future<void> setCap(StorageCap cap) async => state = cap;
}
