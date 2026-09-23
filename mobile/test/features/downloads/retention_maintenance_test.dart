import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/services/retention_maintenance.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';

import '../../support/downloads_test_support.dart';

Future<int> _download(
  DownloadsStore store, {
  required String chapterKey,
  required String seriesKey,
  int pageCount = 1,
  int pageSize = 10,
}) async {
  final id = (sourceId: 'asura', seriesKey: seriesKey, chapterKey: chapterKey);
  final rowId = await store.ensureQueued(id: id);
  await store.updateManifestInfo(rowId: rowId, pageCount: pageCount);
  for (var page = 1; page <= pageCount; page++) {
    await store.savePage(
      rowId: rowId,
      pageNumber: page,
      bytes: List.filled(pageSize, page + chapterKey.hashCode),
    );
  }
  await store.markCompleteIfAllPagesPresent(rowId);
  return rowId;
}

void main() {
  initSqfliteFfiForTests();

  late TestDownloadsHarness harness;
  late RetentionMaintenance maintenance;

  setUp(() async {
    harness = await TestDownloadsHarness.create();
    maintenance = RetentionMaintenance(
      database: harness.openDatabase(),
      blobStore: harness.openBlobStore(),
    );
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('read-then-expire sweep', () {
    test('deletes a chapter only once its read_at is past the interval',
        () async {
      final store = harness.storeFor('u1p1');
      const id = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c1');
      await _download(store, chapterKey: 'c1', seriesKey: 's');
      await store.markRead(id);

      // Not expired yet under a 48h interval — read_at is "now".
      final deletedTooSoon =
          await maintenance.sweepExpired(interval: const Duration(hours: 48));
      expect(deletedTooSoon, 0);
      expect(await store.getChapter(id), isNotNull);

      // Back-date read_at manually (as if 49 hours had passed) — the sweep
      // only has "now vs read_at", so this is the direct way to simulate
      // elapsed time without a fake clock threaded through the store.
      final db = await harness.openDatabase();
      await db.rawUpdate(
        "UPDATE saved_chapters SET read_at = ? WHERE chapter_key = 'c1'",
        [
          DateTime.now()
              .toUtc()
              .subtract(const Duration(hours: 49))
              .toIso8601String(),
        ],
      );

      final deleted =
          await maintenance.sweepExpired(interval: const Duration(hours: 48));
      expect(deleted, 1);
      expect(await store.getChapter(id), isNull);
    });

    test('never touches an unread chapter', () async {
      final store = harness.storeFor('u1p1');
      const id = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c1');
      await _download(store, chapterKey: 'c1', seriesKey: 's');
      // Never marked read — read_at stays null.

      final deleted = await maintenance.sweepExpired(interval: Duration.zero);
      expect(deleted, 0);
      expect(await store.getChapter(id), isNotNull);
    });

    test('never touches a pinned chapter even when expired', () async {
      final store = harness.storeFor('u1p1');
      const id = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c1');
      await _download(store, chapterKey: 'c1', seriesKey: 's');
      await store.markRead(id);
      await store.setSeriesPinned(
        series: (sourceId: 'asura', seriesKey: 's'),
        pinned: true,
      );

      final deleted = await maintenance.sweepExpired(interval: Duration.zero);
      expect(deleted, 0);
      expect(await store.getChapter(id), isNotNull);
    });

    test('never deletes the chapter currently open, even if expired', () async {
      final store = harness.storeFor('u1p1');
      const id = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c1');
      await _download(store, chapterKey: 'c1', seriesKey: 's');
      await store.markRead(id);

      final deleted = await maintenance.sweepExpired(
        interval: Duration.zero,
        excludeOpen: {(scopeId: 'u1p1', id: id)},
      );
      expect(deleted, 0);
      expect(await store.getChapter(id), isNotNull);
    });

    test('re-opening (clearing read_at) cancels a pending expiry', () async {
      final store = harness.storeFor('u1p1');
      const id = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c1');
      await _download(store, chapterKey: 'c1', seriesKey: 's');
      await store.markRead(id);
      await store.clearReadStamp(id); // "re-opened it"

      final deleted = await maintenance.sweepExpired(interval: Duration.zero);
      expect(deleted, 0);
      expect(await store.getChapter(id), isNotNull);
    });

    test('interval null (Settings: Off) never deletes anything', () async {
      final store = harness.storeFor('u1p1');
      const id = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c1');
      await _download(store, chapterKey: 'c1', seriesKey: 's');
      await store.markRead(id);

      final deleted = await maintenance.sweepExpired(interval: null);
      expect(deleted, 0);
      expect(await store.getChapter(id), isNotNull);
    });

    test('sweeps across every profile on the device, not just one', () async {
      final storeA = harness.storeFor('u1p1');
      final storeB = harness.storeFor('u1p2');
      const idA = (sourceId: 'asura', seriesKey: 's', chapterKey: 'a');
      const idB = (sourceId: 'asura', seriesKey: 's', chapterKey: 'b');
      await _download(storeA, chapterKey: 'a', seriesKey: 's');
      await _download(storeB, chapterKey: 'b', seriesKey: 's');
      await storeA.markRead(idA);
      await storeB.markRead(idB);

      // Back-date both stamps explicitly rather than relying on
      // `interval: Duration.zero` comparing against two independent
      // `DateTime.now()` calls a moment apart — under a loaded full-suite
      // run (many sqflite FFI tests running concurrently) that comparison
      // is close enough to the wall clock's resolution to flake.
      final db = await harness.openDatabase();
      final past = DateTime.now().toUtc().subtract(const Duration(seconds: 1)).toIso8601String();
      await db.rawUpdate("UPDATE saved_chapters SET read_at = ? WHERE chapter_key IN ('a', 'b')", [past]);

      final deleted = await maintenance.sweepExpired(interval: Duration.zero);
      expect(deleted, 2);
      expect(await storeA.getChapter(idA), isNull);
      expect(await storeB.getChapter(idB), isNull);
    });
  });

  group('cap pressure eviction', () {
    test('evicts oldest-read-first until under the target', () async {
      final store = harness.storeFor('u1p1');
      const idOld = (sourceId: 'asura', seriesKey: 's', chapterKey: 'old');
      const idMid = (sourceId: 'asura', seriesKey: 's', chapterKey: 'mid');
      const idNew = (sourceId: 'asura', seriesKey: 's', chapterKey: 'new');

      await _download(store, chapterKey: 'old', seriesKey: 's', pageSize: 100);
      await _download(store, chapterKey: 'mid', seriesKey: 's', pageSize: 100);
      await _download(store, chapterKey: 'new', seriesKey: 's', pageSize: 100);

      final now = DateTime.now().toUtc();
      final db = await harness.openDatabase();
      Future<void> stampRead(String key, DateTime at) => db.rawUpdate(
            'UPDATE saved_chapters SET read_at = ? WHERE chapter_key = ?',
            [at.toIso8601String(), key],
          );
      await stampRead('old', now.subtract(const Duration(days: 3)));
      await stampRead('mid', now.subtract(const Duration(days: 2)));
      await stampRead('new', now.subtract(const Duration(days: 1)));

      final totalBefore = await maintenance.totalDeviceBytes();
      // Evict until only the newest ~100 bytes remain.
      final deleted = await maintenance.evictOldestReadFirst(
        targetBytes: totalBefore - 199,
      );

      expect(deleted, 2);
      expect(await store.getChapter(idOld), isNull);
      expect(await store.getChapter(idMid), isNull);
      expect(await store.getChapter(idNew), isNotNull);
    });

    test('pinned series are exempt from pressure eviction', () async {
      final store = harness.storeFor('u1p1');
      const idPinned =
          (sourceId: 'asura', seriesKey: 'pinned-series', chapterKey: 'p1');
      const idPlain =
          (sourceId: 'asura', seriesKey: 'plain-series', chapterKey: 'q1');

      await _download(store,
          chapterKey: 'p1', seriesKey: 'pinned-series', pageSize: 100,);
      await _download(store,
          chapterKey: 'q1', seriesKey: 'plain-series', pageSize: 100,);
      await store.setSeriesPinned(
        series: (sourceId: 'asura', seriesKey: 'pinned-series'),
        pinned: true,
      );

      final now = DateTime.now().toUtc();
      final db = await harness.openDatabase();
      await db.rawUpdate(
        "UPDATE saved_chapters SET read_at = ? WHERE chapter_key = 'p1'",
        [now.subtract(const Duration(days: 5)).toIso8601String()],
      );
      await db.rawUpdate(
        "UPDATE saved_chapters SET read_at = ? WHERE chapter_key = 'q1'",
        [now.subtract(const Duration(days: 1)).toIso8601String()],
      );

      // Try to evict everything — only the unpinned chapter can go.
      final deleted = await maintenance.evictOldestReadFirst(targetBytes: 0);

      expect(deleted, 1);
      expect(await store.getChapter(idPinned), isNotNull);
      expect(await store.getChapter(idPlain), isNull);
    });

    test('never evicts an unread chapter, even under pressure at zero target',
        () async {
      final store = harness.storeFor('u1p1');
      const id = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c1');
      await _download(store, chapterKey: 'c1', seriesKey: 's');
      // Never read.

      final deleted = await maintenance.evictOldestReadFirst(targetBytes: 0);

      expect(deleted, 0);
      expect(await store.getChapter(id), isNotNull);
      expect(
        (await store.getChapter(id))!.state,
        DownloadChapterState.complete,
      );
    });

    test('never evicts the chapter currently open', () async {
      final store = harness.storeFor('u1p1');
      const id = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c1');
      await _download(store, chapterKey: 'c1', seriesKey: 's', pageSize: 100);
      await store.markRead(id);

      final deleted = await maintenance.evictOldestReadFirst(
        targetBytes: 0,
        excludeOpen: {(scopeId: 'u1p1', id: id)},
      );

      expect(deleted, 0);
      expect(await store.getChapter(id), isNotNull);
    });

    test('evicts across every profile to satisfy the device-wide cap',
        () async {
      final storeA = harness.storeFor('u1p1');
      final storeB = harness.storeFor('u1p2');
      const idA = (sourceId: 'asura', seriesKey: 's', chapterKey: 'a');
      const idB = (sourceId: 'asura', seriesKey: 's', chapterKey: 'b');
      await _download(storeA, chapterKey: 'a', seriesKey: 's', pageSize: 100);
      await _download(storeB, chapterKey: 'b', seriesKey: 's', pageSize: 100);
      await storeA.markRead(idA);
      await storeB.markRead(idB);

      final deleted = await maintenance.evictOldestReadFirst(targetBytes: 0);
      expect(deleted, 2);
      expect(await storeA.getChapter(idA), isNull);
      expect(await storeB.getChapter(idB), isNull);
    });
  });

  group('a pinned series with chapters saved before they inherited the pin',
      () {
    const pinnedSeries = (sourceId: 'asura', seriesKey: 's');
    const first = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c1');
    const straggler = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c2');

    /// The mix older builds left behind: the series pinned, then a chapter
    /// downloaded after the pin that went in unpinned.
    Future<DownloadsStore> mixedSeries() async {
      final store = harness.storeFor('u1p1');
      await _download(store, chapterKey: 'c1', seriesKey: 's', pageSize: 100);
      await _download(store, chapterKey: 'c2', seriesKey: 's', pageSize: 100);
      await store.setSeriesPinned(series: pinnedSeries, pinned: true);
      final db = await harness.openDatabase();
      await db.rawUpdate(
        "UPDATE saved_chapters SET pinned = 0 WHERE chapter_key = 'c2'",
      );
      await store.markRead(first);
      await store.markRead(straggler);
      return store;
    }

    test('keeps the straggler through the read-then-expire sweep', () async {
      final store = await mixedSeries();
      const plain = (sourceId: 'asura', seriesKey: 'other', chapterKey: 'o1');
      await _download(store, chapterKey: 'o1', seriesKey: 'other');
      await store.markRead(plain);
      // The same series in another profile, which never pinned it.
      final other = harness.storeFor('u1p2');
      await _download(other, chapterKey: 'c2', seriesKey: 's');
      await other.markRead(straggler);

      final deleted = await maintenance.sweepExpired(interval: Duration.zero);

      expect(deleted, 2);
      expect((await store.getChapter(straggler))!.pinned, isTrue);
      expect(await store.getChapter(plain), isNull);
      expect(await other.getChapter(straggler), isNull);
    });

    test('keeps it through eviction, with the expiry timer off', () async {
      final store = await mixedSeries();

      await maintenance.sweepExpired(interval: null);
      final deleted = await maintenance.evictOldestReadFirst(targetBytes: 0);

      expect(deleted, 0);
      expect(await store.getChapter(straggler), isNotNull);
    });

    test('an unpinned series stays unpinned', () async {
      final store = harness.storeFor('u1p1');
      await _download(store, chapterKey: 'c1', seriesKey: 's');
      await store.setSeriesPinned(series: pinnedSeries, pinned: true);
      await store.setSeriesPinned(series: pinnedSeries, pinned: false);

      expect(await maintenance.repairSeriesPins(), 0);
      expect((await store.getChapter(first))!.pinned, isFalse);
    });
  });

  group('pages whose files were deleted outside the app', () {
    const gone = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c1');
    const intact = (sourceId: 'asura', seriesKey: 's', chapterKey: 'c2');

    Future<void> deletePages(
      DownloadsStore store,
      ChapterIdentity id,
      Set<int> pages,
    ) async {
      final paths = await store.localPagePaths(id);
      for (final page in pages) {
        await paths[page]!.delete();
      }
    }

    test('stop counting at the next sweep, with the expiry timer off',
        () async {
      final store = harness.storeFor('u1p1');
      await _download(store, chapterKey: 'c1', seriesKey: 's', pageCount: 3);
      await _download(store, chapterKey: 'c2', seriesKey: 's', pageSize: 7);
      final before = await maintenance.totalDeviceBytes();
      await deletePages(store, gone, {1, 2, 3});

      await maintenance.sweepExpired(interval: null);

      expect(await maintenance.totalDeviceBytes(), before - 30);
      // Nothing of it is on the phone, so the Downloads screen drops it.
      expect(await store.getChapter(gone), isNull);
      expect(
        (await store.getChapter(intact))!.state,
        DownloadChapterState.complete,
      );
    });

    test('a chapter with some pages left becomes failed, keeping them',
        () async {
      final store = harness.storeFor('u1p1');
      final rowId = await _download(
        store,
        chapterKey: 'c1',
        seriesKey: 's',
        pageCount: 3,
      );
      final before = await maintenance.totalDeviceBytes();
      await deletePages(store, gone, {2});

      await maintenance.sweepExpired(interval: null);

      final chapter = (await store.getChapter(gone))!;
      expect(chapter.state, DownloadChapterState.failed);
      expect(chapter.error, RetentionMaintenance.vanishedPagesError);
      expect(chapter.bytes, 20);
      expect(await store.existingPageNumbers(rowId), {1, 3});
      expect(await maintenance.totalDeviceBytes(), before - 10);
    });

    test('a chapter still downloading only loses the rows', () async {
      final store = harness.storeFor('u1p1');
      final rowId = await store.ensureQueued(id: gone);
      await store.updateManifestInfo(rowId: rowId, pageCount: 3);
      for (final page in [1, 2]) {
        await store.savePage(
          rowId: rowId,
          pageNumber: page,
          bytes: List.filled(10, page),
        );
      }
      await deletePages(store, gone, {1});

      await maintenance.sweepExpired(interval: null);

      final chapter = (await store.getChapter(gone))!;
      expect(chapter.state, DownloadChapterState.downloading);
      // So the queue fetches page 1 again rather than skipping it.
      expect(await store.existingPageNumbers(rowId), {2});
    });
  });
}
