import 'package:manhwamaniacs/features/downloads/services/blob_store.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_db.dart';
import 'package:sqflite/sqflite.dart';

/// Deletes one chapter's on-device bytes: decrements/removes its blob
/// refcounts (freeing the file only once the last referencing profile has
/// let go of it), removes its `saved_pages` rows, then removes the
/// `saved_chapters` row itself.
///
/// **Why the chapter row is deleted outright rather than kept as a
/// "not downloaded" stub:** reading progress (last page, completed, time
/// spent) lives entirely in the separate server-synced progress system
/// (`POST /reader/progress[/batch]` + the local outbox) — it was never
/// stored here. So removing this row loses exactly one thing: the local
/// bookkeeping this table exists to hold (download state, on-device bytes,
/// the pin flag, the read-then-expire timer). The chapter goes back to "on
/// server, not on phone", never to "never read" — the read history that
/// would make it look unread lives elsewhere and is untouched.
///
/// Shared by [DownloadsStore.deleteDownload] (single scope, user-invoked —
/// "remove this download") and `RetentionMaintenance` (cross-scope,
/// automatic — the read-then-expire sweep and cap eviction), so the two
/// paths can never disagree about what "delete a chapter" means.
Future<int> deleteChapterAndBlobs({
  required Database db,
  required BlobStore blobStore,
  required int chapterRowId,
  required String scopeId,
}) async {
  final hashesToMaybeDelete = <String>{};
  var freedBytes = 0;

  await db.transaction((txn) async {
    final pages = await txn.query(
      DownloadsSchema.savedPages,
      where: '${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colChapterRowId} = ?',
      whereArgs: [scopeId, chapterRowId],
    );

    freedBytes = await _releaseBlobRefs(txn, pages, hashesToMaybeDelete);

    await txn.delete(
      DownloadsSchema.savedPages,
      where: '${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colChapterRowId} = ?',
      whereArgs: [scopeId, chapterRowId],
    );
    // Scoped like every other statement here: a row id is not proof of
    // ownership, and the two callers pass one in from different places (a
    // user tap, a cross-scope sweep). Without the predicate a wrong scope
    // still removed the chapter row — the pages and refcounts above are
    // already scoped, so the row would go while its bytes stayed.
    await txn.delete(
      DownloadsSchema.savedChapters,
      where: '${DownloadsSchema.colId} = ? AND ${DownloadsSchema.colScopeId} = ?',
      whereArgs: [chapterRowId, scopeId],
    );
  });

  // File deletion happens after the transaction commits — an orphaned file
  // from a crash between commit and delete is recoverable (BlobStore.write
  // treats "already on disk" as success, and
  // RetentionMaintenance.reclaimOrphanBlobs collects the rest); a file
  // deleted before the transaction commits, on a commit that then rolled
  // back, would not be.
  await reclaimUnreferencedBlobs(
    db: db,
    blobStore: blobStore,
    hashes: hashesToMaybeDelete,
  );

  return freedBytes;
}

/// Unlinks every hash in [hashes] that no `blobs` row still names, and
/// returns how many files it removed.
///
/// **The check and the unlink share one transaction**, and that is the whole
/// point. The gap between them is exactly where another profile's
/// [DownloadsStore.savePage] lands when the launch sweep and
/// `resumePendingOnLaunch` run back to back: it re-references the same blob
/// (a shared credits page, or the same chapter downloaded twice), commits a
/// refcount, and then had its bytes unlinked underneath it — an index that
/// says "downloaded" over a chapter that will not open. Saving a page writes
/// its bytes inside its own transaction, so SQLite serialises the two: either
/// this pass finds the row and leaves the file alone, or the save finds no
/// file and writes it again.
Future<int> reclaimUnreferencedBlobs({
  required Database db,
  required BlobStore blobStore,
  required Iterable<String> hashes,
}) async {
  if (hashes.isEmpty) return 0;
  var removed = 0;
  await db.transaction((txn) async {
    for (final hash in hashes) {
      final referencing = await txn.query(
        DownloadsSchema.blobs,
        columns: [DownloadsSchema.colHash],
        where: '${DownloadsSchema.colHash} = ?',
        whereArgs: [hash],
        limit: 1,
      );
      if (referencing.isNotEmpty) continue;
      if (!blobStore.pathFor(hash).existsSync()) continue;
      await blobStore.delete(hash);
      removed++;
    }
  });
  return removed;
}

/// Drops every saved page of [chapterRowId] numbered above [lastPageNumber],
/// releasing their blob references and subtracting their bytes from the
/// chapter's total. Returns the bytes released.
///
/// A manifest can shrink between download passes — a source re-cuts a chapter,
/// or the first pass read a manifest that was itself wrong — and the pages the
/// earlier, longer manifest produced are then bytes nothing will ever read:
/// the reader lays out `page_count` pages, and [DownloadsStore.isAvailableOffline]
/// compares that count against what is on disk, so a leftover page is the
/// difference between "downloaded" and "downloaded and openable".
Future<int> prunePagesBeyond({
  required Database db,
  required BlobStore blobStore,
  required int chapterRowId,
  required String scopeId,
  required int lastPageNumber,
}) async {
  const pageFilter = '${DownloadsSchema.colScopeId} = ? AND '
      '${DownloadsSchema.colChapterRowId} = ? AND '
      '${DownloadsSchema.colPageNumber} > ?';
  final args = [scopeId, chapterRowId, lastPageNumber];
  final unreferenced = <String>{};
  var freedBytes = 0;

  await db.transaction((txn) async {
    final stale = await txn.query(
      DownloadsSchema.savedPages,
      where: pageFilter,
      whereArgs: args,
    );
    if (stale.isEmpty) return;

    freedBytes = await _releaseBlobRefs(txn, stale, unreferenced);
    await txn.delete(DownloadsSchema.savedPages, where: pageFilter, whereArgs: args);
    // The chapter keeps its row, so unlike whole-chapter deletion its byte
    // total has to be corrected here — it is what the per-series breakdown
    // and the storage cap read.
    await txn.rawUpdate(
      'UPDATE ${DownloadsSchema.savedChapters} '
      'SET ${DownloadsSchema.colBytes} = ${DownloadsSchema.colBytes} - ? '
      'WHERE ${DownloadsSchema.colId} = ? AND ${DownloadsSchema.colScopeId} = ?',
      [freedBytes, chapterRowId, scopeId],
    );
  });

  await reclaimUnreferencedBlobs(
    db: db,
    blobStore: blobStore,
    hashes: unreferenced,
  );
  return freedBytes;
}

/// Drops every saved page of [chapterRowId] whose blob file is no longer on
/// disk — deleted by hand through the Files app, which the Storage card
/// tells users they can do — releasing the references those rows held and
/// subtracting their bytes from the chapter's total. Returns how many pages
/// it dropped.
///
/// A row naming a missing file is worse than no row: the queue skips every
/// page number that has one ([DownloadsStore.existingPageNumbers]), so a
/// chapter carrying them can never fetch those pages again, and the storage
/// cap keeps counting bytes that are not there. Only this chapter's rows go;
/// another chapter sharing the same blob keeps its reference, and its file
/// comes back the next time any of them saves that page.
Future<int> pruneVanishedPages({
  required Database db,
  required BlobStore blobStore,
  required int chapterRowId,
  required String scopeId,
}) async {
  const chapterFilter = '${DownloadsSchema.colScopeId} = ? AND '
      '${DownloadsSchema.colChapterRowId} = ?';
  final unreferenced = <String>{};
  var dropped = 0;

  await db.transaction((txn) async {
    final pages = await txn.query(
      DownloadsSchema.savedPages,
      where: chapterFilter,
      whereArgs: [scopeId, chapterRowId],
    );
    final vanished = [
      for (final page in pages)
        if (!blobStore.exists(page[DownloadsSchema.colBlobHash]! as String))
          page,
    ];
    if (vanished.isEmpty) return;

    final freedBytes = await _releaseBlobRefs(txn, vanished, unreferenced);
    for (final page in vanished) {
      await txn.delete(
        DownloadsSchema.savedPages,
        where: '$chapterFilter AND ${DownloadsSchema.colPageNumber} = ?',
        whereArgs: [
          scopeId,
          chapterRowId,
          page[DownloadsSchema.colPageNumber],
        ],
      );
    }
    await txn.rawUpdate(
      'UPDATE ${DownloadsSchema.savedChapters} '
      'SET ${DownloadsSchema.colBytes} = ${DownloadsSchema.colBytes} - ? '
      'WHERE ${DownloadsSchema.colId} = ? AND ${DownloadsSchema.colScopeId} = ?',
      [freedBytes, chapterRowId, scopeId],
    );
    dropped = vanished.length;
  });

  // Nothing to unlink for the missing files themselves; this only settles
  // any hash whose last reference went with them.
  await reclaimUnreferencedBlobs(
    db: db,
    blobStore: blobStore,
    hashes: unreferenced,
  );
  return dropped;
}

/// Drops one reference each from the blobs [pages] name, deleting the `blobs`
/// row of any that reaches zero and collecting that hash into [unreferenced]
/// for the caller's post-commit reclaim. Returns the bytes released.
///
/// Shared by whole-chapter deletion and [prunePagesBeyond] so a page can only
/// ever stop being referenced one way: the refcount is the only thing standing
/// between one profile letting go of a shared page and another profile's
/// chapter losing it.
Future<int> _releaseBlobRefs(
  Transaction txn,
  List<Map<String, Object?>> pages,
  Set<String> unreferenced,
) async {
  var freedBytes = 0;
  for (final page in pages) {
    final hash = page[DownloadsSchema.colBlobHash]! as String;
    freedBytes += page[DownloadsSchema.colSize]! as int;

    await txn.rawUpdate(
      'UPDATE ${DownloadsSchema.blobs} SET ${DownloadsSchema.colRefcount} = ${DownloadsSchema.colRefcount} - 1 '
      'WHERE ${DownloadsSchema.colHash} = ?',
      [hash],
    );
    final refRows = await txn.query(
      DownloadsSchema.blobs,
      columns: [DownloadsSchema.colRefcount],
      where: '${DownloadsSchema.colHash} = ?',
      whereArgs: [hash],
    );
    final refcount =
        refRows.isEmpty ? 0 : (refRows.first[DownloadsSchema.colRefcount]! as int);
    if (refcount <= 0) {
      await txn.delete(
        DownloadsSchema.blobs,
        where: '${DownloadsSchema.colHash} = ?',
        whereArgs: [hash],
      );
      unreferenced.add(hash);
    }
  }
  return freedBytes;
}
