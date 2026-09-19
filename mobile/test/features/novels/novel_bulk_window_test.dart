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
import 'package:manhwamaniacs/features/downloads/services/offline_novel_reader.dart';
import 'package:manhwamaniacs/features/downloads/services/retention_maintenance.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter_window.dart';
import 'package:manhwamaniacs/features/novels/repositories/novels_repository.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

import '../../support/downloads_test_support.dart';

/// Whole-novel download (spec R5): "add download whole series for novels too".
///
/// A book is hundreds of chapters of a few kilobytes each, so the thing that
/// makes it reasonable is not the storage — it is not paying a round trip per
/// chapter. These tests are about the window: that it is used, that its size
/// comes from the server, and — the part that actually matters — that it is
/// *only* an optimisation. Every guard the single-chapter path has must still
/// be the guard, because a whole-book download is the ordinary queue with
/// fewer requests, not a second pipeline.

const _series = (sourceId: 'royalroad', seriesKey: '21220/mother-of-learning');

({String sourceId, String seriesKey, String chapterKey}) _id(int n) => (
      sourceId: _series.sourceId,
      seriesKey: _series.seriesKey,
      chapterKey: 'ch-$n',
    );

NovelChapter _chapter(int n, {int paragraphs = 3}) => NovelChapter(
      sourceId: _series.sourceId,
      seriesKey: _series.seriesKey,
      chapterKey: 'ch-$n',
      chapterNumber: n.toDouble(),
      title: 'Chapter $n',
      paragraphs: [
        for (var i = 0; i < paragraphs; i++) 'Paragraph $i of chapter $n.',
      ],
      previousChapterKey: null,
      nextChapterKey: null,
      wordCount: paragraphs * 5,
    );

/// A novels API that answers windows, and counts both doors so a test can say
/// which one the queue used.
class _WindowingNovelsRepository implements NovelsRepository {
  @override
  Future<Result<NovelAudio>> audio({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async => const Ok(NovelAudio.none);

  _WindowingNovelsRepository({
    this.maxChapters = kNovelWindowChapters,
    this.brokenKeys = const {},
    this.windowFails = false,
  });

  final int maxChapters;

  /// Keys the server reports as per-item errors rather than refusing the whole
  /// window for.
  final Set<String> brokenKeys;

  /// The whole window call fails (offline, rate-limited, an older server with
  /// no such endpoint).
  final bool windowFails;

  final List<List<String>> windows = [];
  final List<String> singles = [];

  @override
  Future<Result<NovelChapter>> chapter({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async {
    singles.add(chapterKey);
    return Ok(_chapter(int.parse(chapterKey.split('-').last)));
  }

  @override
  Future<Result<NovelChapterWindow>> chapterWindow({
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
          message: 'Too many chapters in one batch.',
          details: {'max_chapters': maxChapters, 'received': chapterKeys.length},
        ),
      );
    }
    return Ok(
      NovelChapterWindow(
        maxChapters: maxChapters,
        chapters: {
          for (final key in chapterKeys)
            if (!brokenKeys.contains(key))
              key: _chapter(int.parse(key.split('-').last)),
        },
        errors: {
          for (final key in chapterKeys)
            if (brokenKeys.contains(key)) key: 'Chapter not found.',
        },
      ),
    );
  }
}

class _ForbiddenPageFetcher implements ChapterPageFetcher {
  @override
  Future<List<int>> fetchPageBytes(String url) async {
    fail('A novel chapter must never fetch a page image ($url)');
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
    required NovelsRepository novelsRepository,
    int freeBytes = 10 * 1024 * 1024 * 1024,
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
        novelsRepositoryProvider.overrideWithValue(novelsRepository),
        chapterPageFetcherProvider.overrideWithValue(_ForbiddenPageFetcher()),
        deviceStorageInfoProvider
            .overrideWithValue(_FixedDeviceStorageInfo(freeBytes)),
        storageCapProvider.overrideWith(_FixedStorageCapNotifier.new),
        downloadConcurrencyOverride(),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  List<ChapterQueueRequest> book(int chapters) => [
        for (var n = 1; n <= chapters; n++)
          (
            id: _id(n),
            chapterNumber: n.toDouble(),
            title: 'Chapter $n',
            seriesTitle: 'Mother of Learning',
            kind: DownloadKind.novel,
          ),
      ];

  test('a whole book is fetched in windows, not one request per chapter',
      () async {
    final repository = _WindowingNovelsRepository();
    final container = buildContainer(novelsRepository: repository);
    final controller = container.read(downloadQueueControllerProvider.notifier);

    await controller.enqueueChapters(book(30));
    await controller.debugWaitUntilIdle();

    // 30 chapters at a stride of 20: two windows, and nothing on the
    // single-chapter endpoint at all.
    expect(repository.windows.map((w) => w.length), [20, 10]);
    expect(repository.singles, isEmpty);

    final store = harness.storeFor('u1p1');
    for (var n = 1; n <= 30; n++) {
      final saved = await store.getChapter(_id(n));
      expect(saved!.state, DownloadChapterState.complete, reason: 'chapter $n');
      expect(saved.kind, DownloadKind.novel);
      expect(saved.pageCount, 1, reason: 'one text blob, not one page');
    }
  });

  test('every windowed chapter reads back offline, byte for byte', () async {
    final container = buildContainer(
      novelsRepository: _WindowingNovelsRepository(),
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);

    await controller.enqueueChapters(book(5));
    await controller.debugWaitUntilIdle();

    final store = harness.storeFor('u1p1');
    for (var n = 1; n <= 5; n++) {
      final offline = await buildOfflineNovelChapter(store, _id(n));
      expect(offline, isNotNull, reason: 'chapter $n');
      expect(offline!.title, 'Chapter $n');
      expect(offline.paragraphs, hasLength(3));
      expect(offline.isOffline, isTrue);
    }
  });

  test('one chapter alone does not spend a window', () async {
    final repository = _WindowingNovelsRepository();
    final container = buildContainer(novelsRepository: repository);
    final controller = container.read(downloadQueueControllerProvider.notifier);

    await controller.enqueueChapter(id: _id(1), kind: DownloadKind.novel);
    await controller.debugWaitUntilIdle();

    // The bulk bucket is far tighter than the single-chapter one; spending a
    // token on one chapter is a straight loss.
    expect(repository.windows, isEmpty);
    expect(repository.singles, ['ch-1']);
  });

  test('the stride comes from the server, not from the app', () async {
    // A deployment with a cap of 5 must not need an app release: the first
    // window is refused as too large, the queue adopts the number the refusal
    // named, and every window after it fits.
    final repository = _WindowingNovelsRepository(maxChapters: 5);
    final container = buildContainer(novelsRepository: repository);
    final controller = container.read(downloadQueueControllerProvider.notifier);

    await controller.enqueueChapters(book(12));
    await controller.debugWaitUntilIdle();

    // The first window asks with the app's guess and is refused...
    expect(repository.windows.first.length, greaterThan(5));
    // ...and every window after it fits the cap the refusal named.
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

  test('a window that fails outright costs nothing — every chapter still lands',
      () async {
    // Offline, rate-limited, or an older server with no such endpoint. The
    // window is an optimisation and must never be load-bearing.
    final repository = _WindowingNovelsRepository(windowFails: true);
    final container = buildContainer(novelsRepository: repository);
    final controller = container.read(downloadQueueControllerProvider.notifier);

    await controller.enqueueChapters(book(4));
    await controller.debugWaitUntilIdle();

    expect(repository.windows, isNotEmpty);
    expect(repository.singles, ['ch-1', 'ch-2', 'ch-3', 'ch-4']);
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
    final repository = _WindowingNovelsRepository(brokenKeys: {'ch-3'});
    final container = buildContainer(novelsRepository: repository);
    final controller = container.read(downloadQueueControllerProvider.notifier);

    await controller.enqueueChapters(book(5));
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

  test('the free-space floor still stops a windowed book mid-flight', () async {
    final storage = _FixedDeviceStorageInfo(10 * 1024 * 1024 * 1024);
    final repository = _WindowingNovelsRepository();
    final container = ProviderContainer(
      overrides: [
        downloadsStoreProvider.overrideWithValue(harness.storeFor('u1p1')),
        retentionMaintenanceProvider.overrideWithValue(
          RetentionMaintenance(
            database: harness.openDatabase(),
            blobStore: harness.openBlobStore(),
          ),
        ),
        novelsRepositoryProvider.overrideWithValue(repository),
        chapterPageFetcherProvider.overrideWithValue(_ForbiddenPageFetcher()),
        deviceStorageInfoProvider.overrideWithValue(storage),
        storageCapProvider.overrideWith(_FixedStorageCapNotifier.new),
        downloadConcurrencyOverride(),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapters(book(3));
    await controller.debugWaitUntilIdle();

    // Now the disk fills up. The next pass must stop before it fetches
    // anything at all — a window is not an exemption from the floor.
    storage.bytes = kFreeSpaceFloorBytes - 1;
    final windowsSoFar = repository.windows.length;
    await controller.enqueueChapters(book(6));
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
}
