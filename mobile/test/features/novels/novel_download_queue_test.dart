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
import 'package:manhwamaniacs/features/novels/models/novel_cast.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter_window.dart';
import 'package:manhwamaniacs/features/novels/repositories/novels_repository.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

import '../../support/downloads_test_support.dart';

const _id = (sourceId: 'royalroad', seriesKey: 'the-gate', chapterKey: 'c1');

/// A [NovelsRepository] whose behaviour is fully scripted — the same seam the
/// manga queue tests use to simulate a flaky or permanently-broken chapter
/// without a real network.
class _ScriptedNovelsRepository implements NovelsRepository {
  @override
  Future<Result<NovelAudio>> audio({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async => const Ok(NovelAudio.none);

  @override
  Future<Result<List<int>>> audioBytes({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async => const Ok(<int>[]);

  @override
  Future<Result<NovelSeriesAudio>> seriesAudio({
    required String sourceId,
    required String seriesKey,
  }) async => const Ok((rendered: <String>{}, narratable: <String>{}));

  @override
  Future<Result<NovelAudioRequest>> requestAudio({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) async => const Ok(
    NovelAudioRequest(queued: <String>[], skipped: <String, String>{}),
  );

  @override
  Future<Result<List<NovelAudioJob>>> audioJobs({
    required String sourceId,
    required String seriesKey,
  }) async => const Ok(<NovelAudioJob>[]);

  @override
  Future<Result<void>> cancelAudioJob(String jobId) async => const Ok(null);

  @override
  Future<Result<NovelAttribution>> attribution({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async => const Ok(NovelAttribution.none);

  @override
  Future<Result<List<NovelVoice>>> voices() async =>
      const Ok(<NovelVoice>[]);

  @override
  Future<Result<void>> setCastVoice({
    required String sourceId,
    required String seriesKey,
    required String name,
    required String? voiceId,
  }) async => const Ok(null);

  @override
  Future<Result<void>> setNarratorVoice({
    required String sourceId,
    required String seriesKey,
    required String? voiceId,
  }) async => const Ok(null);

  _ScriptedNovelsRepository(this._chapter);

  final Future<Result<NovelChapter>> Function() _chapter;
  int calls = 0;

  @override
  Future<Result<NovelChapter>> chapter({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) {
    calls++;
    return _chapter();
  }

  /// Windowed fetching is off in this file: every test here is about the
  /// single-chapter path's retry bound, failure recording and completeness
  /// guard, and a window that answered would take those chapters off it.
  /// `novel_bulk_window_test.dart` covers the windowed path.
  @override
  Future<Result<NovelChapterWindow>> chapterWindow({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) async =>
      const Err(NetworkError(message: 'no window in this test'));
}

/// Fails the test if the queue ever reaches for a page image on a novel.
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

NovelChapter _chapter({int paragraphs = 3}) => NovelChapter(
      sourceId: _id.sourceId,
      seriesKey: _id.seriesKey,
      chapterKey: _id.chapterKey,
      chapterNumber: 1,
      title: 'The Gate Opens',
      paragraphs: [
        for (var i = 0; i < paragraphs; i++) 'Paragraph number $i of the text.',
      ],
      previousChapterKey: null,
      nextChapterKey: 'c2',
      wordCount: paragraphs * 6,
    );

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

  test('downloads a chapter of prose and marks it complete', () async {
    final container = buildContainer(
      novelsRepository: _ScriptedNovelsRepository(() async => Ok(_chapter())),
    );

    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapter(id: _id, kind: DownloadKind.novel);
    await controller.debugWaitUntilIdle();

    final store = harness.storeFor('u1p1');
    final saved = await store.getChapter(_id);
    expect(saved!.state, DownloadChapterState.complete);
    expect(saved.kind, DownloadKind.novel);
    // One blob, and the title the payload carried rather than the queue's.
    expect(saved.pageCount, 1);
    expect(saved.title, 'The Gate Opens');
    expect(saved.chapterNumber, 1);
  });

  test('reads back with no network at all — the whole point', () async {
    final container = buildContainer(
      novelsRepository: _ScriptedNovelsRepository(() async => Ok(_chapter())),
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapter(id: _id, kind: DownloadKind.novel);
    await controller.debugWaitUntilIdle();

    final offline =
        await buildOfflineNovelChapter(harness.storeFor('u1p1'), _id);
    expect(offline, isNotNull);
    expect(offline!.paragraphs, hasLength(3));
    expect(offline.isOffline, isTrue);
  });

  test('a chapter with no text fails rather than completing empty', () async {
    final container = buildContainer(
      novelsRepository: _ScriptedNovelsRepository(
        () async => Ok(_chapter(paragraphs: 0)),
      ),
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapter(id: _id, kind: DownloadKind.novel);
    await controller.debugWaitUntilIdle();

    final saved = await harness.storeFor('u1p1').getChapter(_id);
    expect(saved!.state, DownloadChapterState.failed);
    expect(saved.error, 'This chapter has no text.');
  });

  test('a permanently-broken chapter is bounded, not retried forever',
      () async {
    final repository = _ScriptedNovelsRepository(
      () async => const Err(UnknownError(message: 'gone')),
    );
    final container = buildContainer(novelsRepository: repository);
    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapter(id: _id, kind: DownloadKind.novel);
    await controller.debugWaitUntilIdle();

    final saved = await harness.storeFor('u1p1').getChapter(_id);
    expect(saved!.state, DownloadChapterState.failed);
    // Exactly the manga path's bound — one shared retry rule, not two.
    expect(repository.calls, kMaxChapterManifestRetries);
  });

  test('a retry of a failed chapter succeeds and clears the error', () async {
    var failNext = true;
    final container = buildContainer(
      novelsRepository: _ScriptedNovelsRepository(() async {
        if (failNext) return const Err(UnknownError(message: 'flaky'));
        return Ok(_chapter());
      }),
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapter(id: _id, kind: DownloadKind.novel);
    await controller.debugWaitUntilIdle();
    expect(
      (await harness.storeFor('u1p1').getChapter(_id))!.state,
      DownloadChapterState.failed,
    );

    failNext = false;
    await controller.retryChapter(_id);
    await controller.debugWaitUntilIdle();

    final saved = await harness.storeFor('u1p1').getChapter(_id);
    expect(saved!.state, DownloadChapterState.complete);
    expect(saved.error, isNull);
  });

  test('the free-space floor stops a novel queue exactly as it stops a manga '
      'one', () async {
    final container = buildContainer(
      novelsRepository: _ScriptedNovelsRepository(() async => Ok(_chapter())),
      freeBytes: kFreeSpaceFloorBytes - 1,
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);
    await controller.enqueueChapter(id: _id, kind: DownloadKind.novel);
    await controller.debugWaitUntilIdle();

    expect(
      container.read(downloadQueueControllerProvider).pauseReason,
      DownloadQueuePauseReason.freeSpaceFloor,
    );
    // Paused, never dropped: the row is still queued and resumes when the
    // floor lifts.
    final saved = await harness.storeFor('u1p1').getChapter(_id);
    expect(saved!.state, DownloadChapterState.queued);
  });

  test('a queued batch carries its kind through to each row', () async {
    final container = buildContainer(
      novelsRepository: _ScriptedNovelsRepository(() async => Ok(_chapter())),
    );
    final controller = container.read(downloadQueueControllerProvider.notifier);
    controller.pause();

    await controller.enqueueChapters([
      for (var i = 0; i < 3; i++)
        (
          id: (
            sourceId: _id.sourceId,
            seriesKey: _id.seriesKey,
            chapterKey: 'c$i',
          ),
          chapterNumber: i.toDouble(),
          title: null,
          seriesTitle: 'The Gate',
          kind: DownloadKind.novel,
        ),
    ]);

    final rows = await harness.storeFor('u1p1').listChapters();
    expect(rows, hasLength(3));
    expect(rows.every((r) => r.kind == DownloadKind.novel), isTrue);
  });
}
