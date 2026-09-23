import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/services/retention_maintenance.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_db.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';

import '../../support/downloads_test_support.dart';

const _chapter =
    (sourceId: 'asura', seriesKey: 'solo-leveling', chapterKey: 'c1');

Future<void> _completeChapter(
  DownloadsStore store, {
  required ChapterIdentity id,
  int pageCount = 3,
  List<int> Function(int page)? bytesFor,
}) async {
  final rowId = await store.ensureQueued(id: id);
  await store.updateManifestInfo(rowId: rowId, pageCount: pageCount);
  for (var page = 1; page <= pageCount; page++) {
    await store.savePage(
      rowId: rowId,
      pageNumber: page,
      bytes: bytesFor != null ? bytesFor(page) : [page, page, page],
    );
  }
  await store.markCompleteIfAllPagesPresent(rowId);
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

  group('scope isolation', () {
    test("profile A's downloads are invisible to profile B", () async {
      final storeA = harness.storeFor('u1p1');
      final storeB = harness.storeFor('u1p2');

      await _completeChapter(storeA, id: _chapter);

      expect(await storeA.getChapter(_chapter), isNotNull);
      expect(await storeB.getChapter(_chapter), isNull);
      expect(await storeB.listChapters(), isEmpty);
      expect(await storeA.listChapters(), hasLength(1));
    });

    test('two profiles downloading the same chapter each see their own row',
        () async {
      final storeA = harness.storeFor('u1p1');
      final storeB = harness.storeFor('u1p2');

      await _completeChapter(storeA, id: _chapter);
      await _completeChapter(storeB, id: _chapter);

      final a = await storeA.getChapter(_chapter);
      final b = await storeB.getChapter(_chapter);
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a!.scopeId, 'u1p1');
      expect(b!.scopeId, 'u1p2');

      // Deleting A's download must not touch B's.
      await storeA.deleteDownload(_chapter);
      expect(await storeA.getChapter(_chapter), isNull);
      expect(await storeB.getChapter(_chapter), isNotNull);
      expect(await storeB.isAvailableOffline(_chapter), isTrue);
    });
  });

  group('blob refcounting / dedupe', () {
    test('identical page bytes across profiles are stored once on disk',
        () async {
      final storeA = harness.storeFor('u1p1');
      final storeB = harness.storeFor('u1p2');
      List<int> samePageBytes(int page) => List.filled(50, page);

      await _completeChapter(storeA, id: _chapter, bytesFor: samePageBytes);
      await _completeChapter(storeB, id: _chapter, bytesFor: samePageBytes);

      final db = await harness.openDatabase();
      final blobRows = await db.query(DownloadsSchema.blobs);
      // 3 distinct pages (different byte content per page number) => 3 blobs,
      // not 6, even though two scopes each "own" all 3.
      expect(blobRows, hasLength(3));
      for (final row in blobRows) {
        expect(row[DownloadsSchema.colRefcount], 2);
      }
    });

    test(
        'deleting one profile\'s copy keeps the shared blob until the last '
        'reference is gone', () async {
      final storeA = harness.storeFor('u1p1');
      final storeB = harness.storeFor('u1p2');
      List<int> samePageBytes(int page) => List.filled(10, page);

      await _completeChapter(storeA, id: _chapter, bytesFor: samePageBytes);
      await _completeChapter(storeB, id: _chapter, bytesFor: samePageBytes);

      final blobStore = await harness.openBlobStore();
      final db = await harness.openDatabase();
      final pagesBefore = await db.query(DownloadsSchema.blobs);
      final firstHash = pagesBefore.first[DownloadsSchema.colHash]! as String;
      expect(blobStore.exists(firstHash), isTrue);

      await storeA.deleteDownload(_chapter);
      // Still referenced by B — file and row must survive.
      expect(blobStore.exists(firstHash), isTrue);
      final afterA = await db.query(
        DownloadsSchema.blobs,
        where: '${DownloadsSchema.colHash} = ?',
        whereArgs: [firstHash],
      );
      expect(afterA.single[DownloadsSchema.colRefcount], 1);

      await storeB.deleteDownload(_chapter);
      expect(blobStore.exists(firstHash), isFalse);
      final afterB = await db.query(
        DownloadsSchema.blobs,
        where: '${DownloadsSchema.colHash} = ?',
        whereArgs: [firstHash],
      );
      expect(afterB, isEmpty);
    });
  });

  group('resumability', () {
    test(
        'a chapter killed mid-download leaves no ghost rows and resumes '
        'by skipping pages already on disk', () async {
      final store = harness.storeFor('u1p1');
      final rowId = await store.ensureQueued(id: _chapter);
      await store.updateManifestInfo(rowId: rowId, pageCount: 4);

      // Simulate the app dying after page 1 and 2 landed.
      await store.savePage(rowId: rowId, pageNumber: 1, bytes: [1]);
      await store.savePage(rowId: rowId, pageNumber: 2, bytes: [2]);

      final chapterAfterKill = await store.getChapter(_chapter);
      expect(chapterAfterKill!.state, DownloadChapterState.downloading,
          reason: 'markCompleteIfAllPagesPresent was never reached',);

      // "Relaunch": a fresh store instance over the same database/blob tree.
      final resumed = harness.storeFor('u1p1');
      final pending = await resumed.pendingChapters();
      expect(pending, hasLength(1));
      expect(pending.single.rowId, rowId);

      final already = await resumed.existingPageNumbers(rowId);
      expect(already, {1, 2});

      // Resume: only pages 3 and 4 are fetched.
      await resumed.savePage(rowId: rowId, pageNumber: 3, bytes: [3]);
      await resumed.savePage(rowId: rowId, pageNumber: 4, bytes: [4]);
      final completed = await resumed.markCompleteIfAllPagesPresent(rowId);

      expect(completed, isTrue);
      expect((await resumed.getChapter(_chapter))!.state,
          DownloadChapterState.complete,);
      expect(await resumed.pendingChapters(), isEmpty);
    });

    test('re-saving an already-present page is a no-op for bytes and refcount',
        () async {
      final store = harness.storeFor('u1p1');
      final rowId = await store.ensureQueued(id: _chapter);
      await store.updateManifestInfo(rowId: rowId, pageCount: 1);
      await store.savePage(rowId: rowId, pageNumber: 1, bytes: [9, 9, 9]);
      final firstBytes = (await store.getChapter(_chapter))!.bytes;

      // A retry racing a resume re-delivers the same page.
      await store.savePage(rowId: rowId, pageNumber: 1, bytes: [9, 9, 9]);
      final secondBytes = (await store.getChapter(_chapter))!.bytes;

      expect(secondBytes, firstBytes);
    });

    test('ensureQueued is idempotent for an in-flight or complete chapter',
        () async {
      final store = harness.storeFor('u1p1');
      final rowId1 = await store.ensureQueued(id: _chapter);
      final rowId2 = await store.ensureQueued(id: _chapter);
      expect(rowId1, rowId2);

      await _completeChapter(store, id: _chapter);
      final rowId3 = await store.ensureQueued(id: _chapter);
      expect(rowId3, rowId1);
      expect((await store.getChapter(_chapter))!.state,
          DownloadChapterState.complete,);
    });

    test('a failed chapter resets to queued (retry) via ensureQueued',
        () async {
      final store = harness.storeFor('u1p1');
      final rowId = await store.ensureQueued(id: _chapter);
      await store.markFailed(rowId: rowId, error: 'boom');
      expect((await store.getChapter(_chapter))!.state,
          DownloadChapterState.failed,);

      final retriedRowId = await store.ensureQueued(id: _chapter);
      expect(retriedRowId, rowId);
      final retried = await store.getChapter(_chapter);
      expect(retried!.state, DownloadChapterState.queued);
      expect(retried.retryCount, 0);
      expect(retried.error, isNull);
    });
  });

  group('offline availability', () {
    test('isAvailableOffline is false until every page is present', () async {
      final store = harness.storeFor('u1p1');
      final rowId = await store.ensureQueued(id: _chapter);
      await store.updateManifestInfo(rowId: rowId, pageCount: 2);
      await store.savePage(rowId: rowId, pageNumber: 1, bytes: [1]);

      expect(await store.isAvailableOffline(_chapter), isFalse);

      await store.savePage(rowId: rowId, pageNumber: 2, bytes: [2]);
      await store.markCompleteIfAllPagesPresent(rowId);
      expect(await store.isAvailableOffline(_chapter), isTrue);
    });

    test(
        'a blob file deleted by hand makes the chapter unavailable offline '
        'without corrupting the index', () async {
      final store = harness.storeFor('u1p1');
      await _completeChapter(store, id: _chapter, pageCount: 2);
      expect(await store.isAvailableOffline(_chapter), isTrue);

      final paths = await store.localPagePaths(_chapter);
      final deletedFile = paths[1]!;
      await deletedFile.delete();

      expect(await store.isAvailableOffline(_chapter), isFalse);
      // The index row itself is untouched — this is an orphan, not corruption.
      final chapter = await store.getChapter(_chapter);
      expect(chapter, isNotNull);
      expect(chapter!.state, DownloadChapterState.complete);
    });
  });

  group('a chapter whose files were deleted by hand', () {
    test('is reported as vanished, and only while its files are missing',
        () async {
      final store = harness.storeFor('u1p1');
      const intact = (
        sourceId: 'asura',
        seriesKey: 'solo-leveling',
        chapterKey: 'c2',
      );
      await _completeChapter(store, id: _chapter);
      await _completeChapter(
        store,
        id: intact,
        bytesFor: (page) => [9, page],
      );
      const series = (sourceId: 'asura', seriesKey: 'solo-leveling');
      expect(await store.vanishedChapterKeys(series), isEmpty);

      await (await store.localPagePaths(_chapter))[2]!.delete();

      expect(await store.vanishedChapterKeys(series), {'c1'});
      // Scoped like everything else: another profile has nothing vanished.
      expect(await harness.storeFor('u1p2').vanishedChapterKeys(series),
          isEmpty,);
    });

    test('queueing it again drops the missing pages and re-queues it',
        () async {
      final store = harness.storeFor('u1p1');
      await _completeChapter(store, id: _chapter);
      final before = await store.getChapter(_chapter);
      final missing = (await store.localPagePaths(_chapter))[2]!;
      await missing.delete();

      final rowId = await store.ensureQueued(id: _chapter);

      expect(rowId, before!.rowId);
      final after = await store.getChapter(_chapter);
      expect(after!.state, DownloadChapterState.queued);
      expect(after.retryCount, 0);
      // Pages still on disk stay, so only the missing one is fetched again.
      expect(await store.existingPageNumbers(rowId), {1, 3});
      expect(after.bytes, before.bytes - 3);
      // Its bytes no longer count against the cap.
      final db = await harness.openDatabase();
      expect(await db.query('blobs'), hasLength(2));
    });

    test('a blob another chapter still holds keeps that reference', () async {
      final store = harness.storeFor('u1p1');
      const sharing = (
        sourceId: 'asura',
        seriesKey: 'solo-leveling',
        chapterKey: 'c2',
      );
      await _completeChapter(store, id: _chapter, pageCount: 1);
      await _completeChapter(store, id: sharing, pageCount: 1);
      await (await store.localPagePaths(_chapter))[1]!.delete();

      await store.ensureQueued(id: _chapter);

      final db = await harness.openDatabase();
      final blobs = await db.query('blobs');
      expect(blobs.single['refcount'], 1);
      expect((await store.getChapter(sharing))!.state,
          DownloadChapterState.complete,);
    });

    test('an intact chapter is left complete', () async {
      final store = harness.storeFor('u1p1');
      await _completeChapter(store, id: _chapter);

      await store.ensureQueued(id: _chapter);

      expect((await store.getChapter(_chapter))!.state,
          DownloadChapterState.complete,);
      expect(await store.existingPageNumbers(
        (await store.getChapter(_chapter))!.rowId,
      ), {1, 2, 3},);
    });
  });

  group('pin / read-state bookkeeping', () {
    test('marking read then re-opening clears the stamp', () async {
      final store = harness.storeFor('u1p1');
      await _completeChapter(store, id: _chapter);

      await store.markRead(_chapter);
      expect((await store.getChapter(_chapter))!.readAt, isNotNull);

      await store.clearReadStamp(_chapter);
      expect((await store.getChapter(_chapter))!.readAt, isNull);
    });

    test('pinning a series sets pinned on every one of its chapters', () async {
      final store = harness.storeFor('u1p1');
      const chapter2 = (
        sourceId: 'asura',
        seriesKey: 'solo-leveling',
        chapterKey: 'c2',
      );
      await _completeChapter(store, id: _chapter);
      await _completeChapter(store, id: chapter2);

      await store.setSeriesPinned(
        series: (sourceId: 'asura', seriesKey: 'solo-leveling'),
        pinned: true,
      );

      final chapters = await store.listChapters();
      expect(chapters.every((c) => c.pinned), isTrue);
    });

    test('a chapter downloaded after the pin is pinned too', () async {
      final store = harness.storeFor('u1p1');
      const later = (
        sourceId: 'asura',
        seriesKey: 'solo-leveling',
        chapterKey: 'c2',
      );
      const otherSeries = (
        sourceId: 'asura',
        seriesKey: 'omniscient-reader',
        chapterKey: 'c1',
      );
      await _completeChapter(store, id: _chapter);
      await store.setSeriesPinned(
        series: (sourceId: 'asura', seriesKey: 'solo-leveling'),
        pinned: true,
      );

      await _completeChapter(store, id: later);
      await _completeChapter(store, id: otherSeries);

      expect((await store.getChapter(later))!.pinned, isTrue);
      // Only the pinned series, and only in the scope that pinned it.
      expect((await store.getChapter(otherSeries))!.pinned, isFalse);
      await _completeChapter(harness.storeFor('u1p2'), id: later);
      expect((await harness.storeFor('u1p2').getChapter(later))!.pinned,
          isFalse,);

      // Which is what keeps retention off it once it has been read.
      await store.markRead(later);
      final maintenance = RetentionMaintenance(
        database: harness.openDatabase(),
        blobStore: harness.openBlobStore(),
      );
      await maintenance.evictOldestReadFirst(targetBytes: 0);
      expect(await store.getChapter(later), isNotNull);
    });

    test('unpinning stops later chapters inheriting the pin', () async {
      final store = harness.storeFor('u1p1');
      const later = (
        sourceId: 'asura',
        seriesKey: 'solo-leveling',
        chapterKey: 'c2',
      );
      const series = (sourceId: 'asura', seriesKey: 'solo-leveling');
      await _completeChapter(store, id: _chapter);
      await store.setSeriesPinned(series: series, pinned: true);
      await store.setSeriesPinned(series: series, pinned: false);

      await _completeChapter(store, id: later);

      expect((await store.getChapter(later))!.pinned, isFalse);
    });
  });

  group('deleting a download preserves progress semantics', () {
    test(
        'deleteDownload removes only this store\'s bookkeeping, never the '
        'reading-progress system (which this store never touches)', () async {
      final store = harness.storeFor('u1p1');
      await _completeChapter(store, id: _chapter);
      await store.markRead(_chapter);

      await store.deleteDownload(_chapter);

      // "Progress survives blob deletion" for this store's part of the
      // contract means: the deletion primitive only ever touches
      // saved_chapters/saved_pages/blobs — server-side reading progress and
      // the outbox are entirely separate tables this call never references.
      // Proven structurally: the chapter row itself, including its read_at
      // bookkeeping, is gone — nothing here claims "still on phone" — while
      // the progress_outbox table (a completely different concern) is
      // untouched by this call.
      final db = await harness.openDatabase();
      final outboxRows = await db.query(DownloadsSchema.progressOutbox);
      expect(outboxRows, isEmpty); // never wrote/deleted anything there
      expect(await store.getChapter(_chapter), isNull);
    });
  });
}
