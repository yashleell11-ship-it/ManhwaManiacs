import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';
import 'package:manhwamaniacs/features/downloads/models/storage_cap.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/retention_maintenance_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/storage_settings_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_constants.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
import 'package:manhwamaniacs/features/downloads/services/chapter_page_fetcher.dart';
import 'package:manhwamaniacs/features/downloads/services/device_storage_info.dart';
import 'package:manhwamaniacs/features/downloads/services/retention_maintenance.dart';
import 'package:manhwamaniacs/features/reader/models/bookmark.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest_window.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/repositories/reader_repository.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

import '../../support/downloads_test_support.dart';

/// Whole-series download over `POST /reader/chapters/manifest`.
///
/// Downloading a 300-chapter series used to open 300 manifest requests, which
/// is exactly what the backend built the bulk window to remove. The win being
/// claimed here is round trips and rate-limit safety, NOT raw speed: on a warm
/// cache the window is no faster server-side, because the floor is our own
/// politeness spacing upstream.
///
/// So these tests are about the window being used, its size coming from the
/// server, and the bulk bucket being respected — and, the part that actually
/// matters, that it is *only* an optimisation. Every guard the single-chapter
/// path has must still be the guard, because a whole-series download is the
/// ordinary queue with fewer requests, not a second pipeline.

const _series = (sourceId: 'asura', seriesKey: 'solo-leveling');

({String sourceId, String seriesKey, String chapterKey}) _id(int n) => (
      sourceId: _series.sourceId,
      seriesKey: _series.seriesKey,
      chapterKey: 'ch-$n',
    );

ChapterManifest _manifest(int n, {int pageCount = 2}) => ChapterManifest(
      sourceId: _series.sourceId,
      seriesKey: _series.seriesKey,
      chapterKey: 'ch-$n',
      chapterNumber: n.toDouble(),
      pageCount: pageCount,
      prev: null,
      next: null,
      pages: [
        for (var i = 1; i <= pageCount; i++)
          ManifestPage(
            number: i,
            url: '/sources/asura/pages/ch-$n-$i/image',
          ),
      ],
    );

/// A reader API that answers windows, and counts both doors so a test can say
/// which one the queue used.
class _WindowingReaderRepository implements ReaderRepository {
  _WindowingReaderRepository({
    this.maxChapters = kManifestWindowChapters,
    this.brokenKeys = const {},
    this.windowFails = false,
    this.everyKeyBroken = false,
  });

  final int maxChapters;

  /// Keys the server reports as per-item errors rather than refusing the whole
  /// window for.
  final Set<String> brokenKeys;

  /// The whole window call fails (offline, rate-limited, an older server with
  /// no such endpoint).
  final bool windowFails;

  /// The window answers 200 but every item in it is an error — a success on
  /// the wire that is worth nothing to the queue.
  final bool everyKeyBroken;

  final List<List<String>> windows = [];
  final List<String> singles = [];

  @override
  Future<Result<ChapterManifest>> manifest({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async {
    singles.add(chapterKey);
    return Ok(_manifest(int.parse(chapterKey.split('-').last)));
  }

  @override
  Future<Result<ChapterManifestWindow>> manifestWindow({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) async {
    windows.add(List.of(chapterKeys));
    if (windowFails) {
      return const Err(NetworkError(message: 'no route to host'));
    }
    if (chapterKeys.length > maxChapters) {
      return Err(
        ApiError(
          statusCode: 413,
          code: 'batch_too_large',
          message: 'Too many chapters in one window.',
          details: {
            'max_chapters': maxChapters,
            'received': chapterKeys.length,
          },
        ),
      );
    }
    final broken = everyKeyBroken ? chapterKeys.toSet() : brokenKeys;
    return Ok(
      ChapterManifestWindow(
        maxChapters: maxChapters,
        manifests: {
          for (final key in chapterKeys)
            if (!broken.contains(key))
              key: _manifest(int.parse(key.split('-').last)),
        },
        errors: {
          for (final key in chapterKeys)
            if (broken.contains(key)) key: 'Chapter not found.',
        },
      ),
    );
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
}

class _CountingPageFetcher implements ChapterPageFetcher {
  final List<String> requested = [];

  @override
  Future<List<int>> fetchPageBytes(String url) async {
    requested.add(url);
    return [1, 2, 3];
  }
}

class _FixedStorageCapNotifier extends StorageCapNotifier {
  @override
  StorageCap build() => StorageCap.unlimited;
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
    ChapterPageFetcher? pageFetcher,
    DeviceStorageInfo? storage,
  }) {
    final container = ProviderContainer(
      overrides: [
        downloadsStoreProvider.overrideWithValue(harness.storeFor('u1p1')),
        retentionMaintenanceProvider.overrideWithValue(
          RetentionMaintenance(
            database: harness.openDatabase(),
            blobStore: harness.openBlobStore(),
          ),
        ),
        readerRepositoryProvider.overrideWithValue(readerRepository),
        chapterPageFetcherProvider
            .overrideWithValue(pageFetcher ?? _CountingPageFetcher()),
        deviceStorageInfoProvider.overrideWithValue(
          storage ?? _FixedDeviceStorageInfo(10 * 1024 * 1024 * 1024),
        ),
        storageCapProvider.overrideWith(_FixedStorageCapNotifier.new),
        downloadConcurrencyOverride(),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  List<ChapterQueueRequest> series(int chapters) => [
        for (var n = 1; n <= chapters; n++)
          (
            id: _id(n),
            chapterNumber: n.toDouble(),
            title: 'Chapter $n',
            seriesTitle: 'Solo Leveling',
            kind: DownloadKind.manga,
          ),
      ];

  group('the window', () {
    test('a whole series is fetched in windows, not one request per chapter',
        () async {
      final repository = _WindowingReaderRepository();
      final container = buildContainer(readerRepository: repository);
      final controller =
          container.read(downloadQueueControllerProvider.notifier);

      await controller.enqueueChapters(series(30));
      await controller.debugWaitUntilIdle();

      // 30 chapters at a stride of 20: two windows, and nothing on the
      // single-chapter endpoint at all. This is the finding — the phone used
      // to open thirty.
      expect(repository.windows.map((w) => w.length), [20, 10]);
      expect(repository.singles, isEmpty);

      final store = harness.storeFor('u1p1');
      for (var n = 1; n <= 30; n++) {
        final saved = await store.getChapter(_id(n));
        expect(
          saved!.state,
          DownloadChapterState.complete,
          reason: 'chapter $n',
        );
        expect(saved.pageCount, 2);
      }
    });

    test("every windowed chapter's pages actually land on disk", () async {
      final fetcher = _CountingPageFetcher();
      final container = buildContainer(
        readerRepository: _WindowingReaderRepository(),
        pageFetcher: fetcher,
      );
      final controller =
          container.read(downloadQueueControllerProvider.notifier);

      await controller.enqueueChapters(series(5));
      await controller.debugWaitUntilIdle();

      // A window supplies the plan, never the bytes: every page is still
      // fetched and stored one at a time through the ordinary page path.
      expect(fetcher.requested, hasLength(10));
      final store = harness.storeFor('u1p1');
      for (var n = 1; n <= 5; n++) {
        final row = await store.getChapter(_id(n));
        expect(
          await store.existingPageNumbers(row!.rowId),
          {1, 2},
          reason: 'chapter $n',
        );
      }
    });

    test('one chapter alone does not spend a bulk token', () async {
      final repository = _WindowingReaderRepository();
      final container = buildContainer(readerRepository: repository);
      final controller =
          container.read(downloadQueueControllerProvider.notifier);

      await controller.enqueueChapter(id: _id(1));
      await controller.debugWaitUntilIdle();

      // The bulk bucket is far tighter than the single-chapter one, because
      // one call there is worth up to `max_chapters` upstream scrapes.
      expect(repository.windows, isEmpty);
      expect(repository.singles, ['ch-1']);
    });

    test('the stride comes from the server, not from the app', () async {
      // A deployment with MM_READER_BULK_MAX_CHAPTERS=5 must not need an app
      // release: the first window is refused as too large, the queue adopts
      // the number the refusal named, and every window after it fits.
      final repository = _WindowingReaderRepository(maxChapters: 5);
      final container = buildContainer(readerRepository: repository);
      final controller =
          container.read(downloadQueueControllerProvider.notifier);

      await controller.enqueueChapters(series(12));
      await controller.debugWaitUntilIdle();

      expect(repository.windows.first.length, greaterThan(5));
      expect(repository.windows.length, greaterThan(1));
      expect(
        repository.windows.skip(1).map((w) => w.length),
        everyElement(lessThanOrEqualTo(5)),
      );
      final store = harness.storeFor('u1p1');
      for (var n = 1; n <= 12; n++) {
        expect(
          (await store.getChapter(_id(n)))!.state,
          DownloadChapterState.complete,
          reason: 'chapter $n must still land, cap or no cap',
        );
      }
    });
  });

  group('partial success and failure', () {
    test('a window that fails outright costs nothing — every chapter lands',
        () async {
      // Offline, rate-limited, or an older server with no such endpoint. The
      // window is an optimisation and must never be load-bearing.
      final repository = _WindowingReaderRepository(windowFails: true);
      final container = buildContainer(readerRepository: repository);
      final controller =
          container.read(downloadQueueControllerProvider.notifier);

      await controller.enqueueChapters(series(4));
      await controller.debugWaitUntilIdle();

      expect(repository.windows, isNotEmpty);
      // Unordered on purpose. A batch runs its chapters concurrently
      // (`Future.wait` in the queue controller), so the order their fallback
      // requests reach the single endpoint is scheduling, not behaviour. An
      // ordered assertion here passed on an idle machine and failed under
      // load — which is exactly when CI runs it.
      expect(
        repository.singles,
        unorderedEquals(['ch-1', 'ch-2', 'ch-3', 'ch-4']),
      );
      final store = harness.storeFor('u1p1');
      for (var n = 1; n <= 4; n++) {
        expect(
          (await store.getChapter(_id(n)))!.state,
          DownloadChapterState.complete,
        );
      }
    });

    test('one broken chapter in a window costs that chapter and no other',
        () async {
      final repository = _WindowingReaderRepository(brokenKeys: {'ch-3'});
      final container = buildContainer(readerRepository: repository);
      final controller =
          container.read(downloadQueueControllerProvider.notifier);

      await controller.enqueueChapters(series(5));
      await controller.debugWaitUntilIdle();

      final store = harness.storeFor('u1p1');
      for (final n in [1, 2, 4, 5]) {
        expect(
          (await store.getChapter(_id(n)))!.state,
          DownloadChapterState.complete,
          reason: 'chapter $n',
        );
      }
      // The chapter the window could not supply falls through to the single
      // endpoint, which owns the retry bound and the failure record. Here that
      // endpoint happens to succeed, which is exactly the point: a per-item
      // window error is not a verdict on the chapter.
      expect(repository.singles, contains('ch-3'));
      expect(
        (await store.getChapter(_id(3)))!.state,
        DownloadChapterState.complete,
      );
    });
  });

  group('the bulk rate-limit bucket', () {
    test('a failed window is not re-asked for on the very next chapter',
        () async {
      // The failure mode this guards: a window that keeps failing turns a
      // whole-series download into ONE BULK REQUEST PER CHAPTER — strictly
      // more requests than the per-chapter path it replaces, aimed at the
      // tightest bucket the server has. That shape has already drawn a real,
      // minutes-long 429 from a source on this project.
      final repository = _WindowingReaderRepository(windowFails: true);
      final container = buildContainer(readerRepository: repository);
      final controller =
          container.read(downloadQueueControllerProvider.notifier);

      await controller.enqueueChapters(series(8));
      await controller.debugWaitUntilIdle();

      expect(repository.windows, hasLength(1));
      expect(repository.singles, hasLength(8));
    });

    test('a window where every item errored also rests the bucket', () async {
      // A 200 whose items are all errors is a success on the wire and worth
      // nothing to the queue; asking again immediately is the same per-chapter
      // hammering as an outright failure.
      final repository = _WindowingReaderRepository(everyKeyBroken: true);
      final container = buildContainer(readerRepository: repository);
      final controller =
          container.read(downloadQueueControllerProvider.notifier);

      await controller.enqueueChapters(series(8));
      await controller.debugWaitUntilIdle();

      expect(repository.windows, hasLength(1));
      expect(repository.singles, hasLength(8));
    });
  });

  group('the queue guards still apply', () {
    test('the free-space floor stops a windowed series mid-flight', () async {
      final storage = _FixedDeviceStorageInfo(10 * 1024 * 1024 * 1024);
      final repository = _WindowingReaderRepository();
      final container = buildContainer(
        readerRepository: repository,
        storage: storage,
      );
      final controller =
          container.read(downloadQueueControllerProvider.notifier);

      await controller.enqueueChapters(series(3));
      await controller.debugWaitUntilIdle();

      // Now the disk fills up. The next pass must stop before it fetches
      // anything at all — a window is not an exemption from the floor.
      storage.bytes = kFreeSpaceFloorBytes - 1;
      final windowsSoFar = repository.windows.length;
      await controller.enqueueChapters(series(6));
      await controller.debugWaitUntilIdle();

      expect(
        container.read(downloadQueueControllerProvider).pauseReason,
        DownloadQueuePauseReason.freeSpaceFloor,
      );
      expect(
        repository.windows.length,
        windowsSoFar,
        reason: 'a blocked queue must not fetch a window either',
      );
    });

    test('a user pause stops a windowed series without losing a row', () async {
      final repository = _WindowingReaderRepository();
      final container = buildContainer(readerRepository: repository);
      final controller =
          container.read(downloadQueueControllerProvider.notifier);

      controller.pause();
      await controller.enqueueChapters(series(6));
      await controller.debugWaitUntilIdle();

      expect(
        repository.windows,
        isEmpty,
        reason: 'a paused queue must not spend a bulk token either',
      );
      expect(await harness.storeFor('u1p1').pendingChapters(), hasLength(6));

      controller.resume();
      await controller.debugWaitUntilIdle();

      expect(repository.windows, hasLength(1));
      final store = harness.storeFor('u1p1');
      for (var n = 1; n <= 6; n++) {
        expect(
          (await store.getChapter(_id(n)))!.state,
          DownloadChapterState.complete,
          reason: 'chapter $n',
        );
      }
    });
  });

  group('ChapterManifestWindow.fromJson', () {
    test('splits a partial-success window into manifests and errors', () {
      final window = ChapterManifestWindow.fromJson({
        'source_id': 'asura',
        'series_key': 'solo-leveling',
        'max_chapters': 20,
        'requested': 3,
        'ok_count': 1,
        'failed_count': 2,
        'items': [
          {
            'chapter_key': 'ch-1',
            'status': 'ok',
            'manifest': {
              'source_id': 'asura',
              'series_key': 'solo-leveling',
              'chapter_key': 'ch-1',
              'chapter_number': 1,
              'page_count': 2,
              'pages': [
                {'number': 1, 'url': '/p/1', 'width': null, 'height': null},
                {'number': 2, 'url': '/p/2', 'width': 800, 'height': 1200},
              ],
              'prev': null,
              'next': 'ch-2',
            },
            'error': null,
          },
          {
            'chapter_key': 'ch-2',
            'status': 'error',
            'manifest': null,
            'error': {
              'code': 'chapter_unavailable',
              'status': 502,
              'message': 'The source did not return this chapter.',
            },
          },
          {
            'chapter_key': 'ch-3',
            'status': 'error',
            'manifest': null,
            'error': null,
          },
        ],
      });

      expect(window.maxChapters, 20);
      expect(window.manifests.keys, ['ch-1']);
      expect(window.manifests['ch-1']!.pages, hasLength(2));
      expect(window.manifests['ch-1']!.next, 'ch-2');
      expect(
        window.errors['ch-2'],
        'The source did not return this chapter.',
      );
      // An error item with no envelope still has to name the chapter, or the
      // caller cannot tell "not in the window" from "broken".
      expect(window.errors['ch-3'], isNotNull);
    });

    test('an ok item with no pages is recorded as an error, not a manifest',
        () {
      // The single-chapter path already treats a page-less chapter as a
      // failure with a retry bound; a window must not smuggle one past it as
      // a success.
      final window = ChapterManifestWindow.fromJson({
        'max_chapters': 20,
        'items': [
          {
            'chapter_key': 'ch-9',
            'status': 'ok',
            'manifest': {
              'source_id': 'asura',
              'series_key': 'solo-leveling',
              'chapter_key': 'ch-9',
              'chapter_number': 9,
              'page_count': 0,
              'pages': <dynamic>[],
              'prev': null,
              'next': null,
            },
            'error': null,
          },
        ],
      });

      expect(window.manifests, isEmpty);
      expect(window.errors['ch-9'], 'This chapter has no pages.');
    });

    test('an empty body parses to an empty window rather than throwing', () {
      final window = ChapterManifestWindow.fromJson(const {});
      expect(window.maxChapters, 0);
      expect(window.manifests, isEmpty);
      expect(window.errors, isEmpty);
    });
  });
}
