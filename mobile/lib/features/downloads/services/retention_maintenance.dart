import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/services/blob_store.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_db.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_deletion.dart';
import 'package:sqflite/sqflite.dart';

/// Identifies exactly one chapter row: which profile downloaded it, plus its
/// content identity.
typedef ScopedChapterIdentity = ({String scopeId, ChapterIdentity id});

/// Cross-profile storage maintenance: the read-then-expire sweep and cap
/// pressure-eviction. Unlike [DownloadsStore] (bound to one profile's scope
/// for isolation), this operates across every scope on the device — because
/// the storage cap and the free-space floor are **device properties, not
/// per-profile ones** (spec §3b): two profiles share one physical disk, so
/// staying under a shared budget has to be able to reclaim any profile's
/// aged-out chapters, not just the one currently in the foreground.
///
/// This never *displays* another profile's content — it only deletes bytes
/// that are already past their own read-then-expire timer or being evicted
/// under pressure, the same operation [DownloadsStore.deleteDownload]
/// performs for a single scope. Nothing here is reachable from a screen; it
/// is driven only by the launch/resume sweep and the "Free up space" action.
class RetentionMaintenance {
  RetentionMaintenance({required this.database, required this.blobStore});

  final Future<Database> database;
  final Future<BlobStore> blobStore;

  /// Real, dedup-aware disk usage — what the storage cap is enforced
  /// against. Not a per-scope sum: two profiles sharing a chapter contribute
  /// its bytes once, exactly like the disk does.
  Future<int> totalDeviceBytes() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT SUM(${DownloadsSchema.colSize}) AS total FROM ${DownloadsSchema.blobs}',
    );
    return (result.first['total'] as num?)?.toInt() ?? 0;
  }

  /// Deletes every chapter whose read-then-expire timer has elapsed, across
  /// every profile. `null` [interval] disables the sweep entirely (the
  /// Settings "Off" option) without touching cap-pressure eviction.
  ///
  /// [excludeOpen] is every chapter a reader currently has on screen, not
  /// just the one its route opened at — a continuous feed holds a window of
  /// them and slides it (see `currentlyOpenChaptersProvider`).
  ///
  /// Returns how many chapters were deleted.
  Future<int> sweepExpired({
    required Duration? interval,
    Set<ScopedChapterIdentity> excludeOpen = const {},
  }) async {
    // Runs even with the timer switched Off, and before the expiry work: an
    // orphaned blob is not an expiry decision, it is bytes no profile can
    // reach, and this pass is the only one that ever visits the tree.
    await reclaimOrphanBlobs();
    // Same for the pin repair, which has to land before any expiry decision
    // is made: a pinned series' unpinned stragglers are exactly what the
    // expiry below and the eviction that follows it in "Free up space" would
    // take.
    await repairSeriesPins();
    if (interval == null) return 0;
    final db = await database;
    final blob = await blobStore;
    final cutoff = DateTime.now().toUtc().subtract(interval);

    final rows = await db.query(
      DownloadsSchema.savedChapters,
      columns: [
        DownloadsSchema.colId,
        DownloadsSchema.colScopeId,
        DownloadsSchema.colSourceId,
        DownloadsSchema.colSeriesKey,
        DownloadsSchema.colChapterKey,
      ],
      where: '${DownloadsSchema.colPinned} = 0 AND ${DownloadsSchema.colReadAt} IS NOT NULL '
          'AND ${DownloadsSchema.colReadAt} <= ?',
      whereArgs: [cutoff.toIso8601String()],
    );

    var deleted = 0;
    for (final row in rows) {
      if (_isExcluded(row, excludeOpen)) continue;
      await deleteChapterAndBlobs(
        db: db,
        blobStore: blob,
        chapterRowId: row[DownloadsSchema.colId]! as int,
        scopeId: row[DownloadsSchema.colScopeId]! as String,
      );
      deleted++;
    }
    return deleted;
  }

  /// Deletes already-read, unpinned chapters — globally oldest `read_at`
  /// first — until total device usage is at or under [targetBytes]. Never
  /// touches a pinned series or a chapter that has not been read
  /// (`read_at IS NULL`): if pressure remains after every eligible chapter is
  /// gone, that pressure is left in place rather than reaching for unread or
  /// pinned content.
  ///
  /// Returns how many chapters were deleted.
  Future<int> evictOldestReadFirst({
    required int targetBytes,
    Set<ScopedChapterIdentity> excludeOpen = const {},
  }) async {
    final db = await database;
    final blob = await blobStore;
    var deleted = 0;

    while (await totalDeviceBytes() > targetBytes) {
      final rows = await db.query(
        DownloadsSchema.savedChapters,
        columns: [
          DownloadsSchema.colId,
          DownloadsSchema.colScopeId,
          DownloadsSchema.colSourceId,
          DownloadsSchema.colSeriesKey,
          DownloadsSchema.colChapterKey,
        ],
        where: '${DownloadsSchema.colPinned} = 0 AND ${DownloadsSchema.colReadAt} IS NOT NULL',
        orderBy: '${DownloadsSchema.colReadAt} ASC',
        // One more row than there are protected ones, so the oldest
        // *evictable* chapter is always in the page even when every open
        // chapter sorts ahead of it.
        limit: excludeOpen.length + 1,
      );

      final candidate = rows.firstWhere(
        (row) => !_isExcluded(row, excludeOpen),
        orElse: () => <String, Object?>{},
      );
      if (candidate.isEmpty) break; // Nothing left that's safe to evict.

      await deleteChapterAndBlobs(
        db: db,
        blobStore: blob,
        chapterRowId: candidate[DownloadsSchema.colId]! as int,
        scopeId: candidate[DownloadsSchema.colScopeId]! as String,
      );
      deleted++;
    }
    return deleted;
  }

  /// Pins every chapter of a series that has a pinned chapter, in every
  /// scope. Returns how many rows it pinned.
  ///
  /// A pin is on the series ([DownloadsStore.setSeriesPinned] writes every
  /// row), but chapters queued after the pin used to go in unpinned — fixed
  /// in `ensureQueued` for new rows only. An install that downloaded more of
  /// a pinned series before then still holds those rows at `pinned = 0`, and
  /// retention filters row by row, so the sweep and eviction deleted them
  /// once read while the Downloads screen called the series pinned. Nothing
  /// else produces that mix, so evening it out is safe, and once it has run
  /// there is nothing left for it to change.
  ///
  /// The `EXISTS` is re-asked inside each statement rather than trusted from
  /// the list: an unpin that lands between the two clears every row, and
  /// must not be undone by a pass that read the series as pinned first.
  Future<int> repairSeriesPins() async {
    final db = await database;
    final pinned = await db.query(
      DownloadsSchema.savedChapters,
      distinct: true,
      columns: [
        DownloadsSchema.colScopeId,
        DownloadsSchema.colSourceId,
        DownloadsSchema.colSeriesKey,
      ],
      where: '${DownloadsSchema.colPinned} = 1',
    );

    var repaired = 0;
    for (final series in pinned) {
      final args = [
        series[DownloadsSchema.colScopeId],
        series[DownloadsSchema.colSourceId],
        series[DownloadsSchema.colSeriesKey],
      ];
      repaired += await db.rawUpdate(
        'UPDATE ${DownloadsSchema.savedChapters} SET ${DownloadsSchema.colPinned} = 1 '
        'WHERE ${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colSourceId} = ? '
        'AND ${DownloadsSchema.colSeriesKey} = ? AND ${DownloadsSchema.colPinned} = 0 '
        'AND EXISTS (SELECT 1 FROM ${DownloadsSchema.savedChapters} p '
        'WHERE p.${DownloadsSchema.colScopeId} = ? AND p.${DownloadsSchema.colSourceId} = ? '
        'AND p.${DownloadsSchema.colSeriesKey} = ? AND p.${DownloadsSchema.colPinned} = 1)',
        [...args, ...args],
      );
    }
    return repaired;
  }

  /// How long a file must have sat untouched before the reclaim will call it
  /// garbage. A blob's bytes and the row naming them commit together
  /// (`DownloadsStore.savePage`), so a young unreferenced file is far more
  /// likely to belong to work in flight than to a crash — and waiting one
  /// launch longer to reclaim a page costs nothing, while deleting a page a
  /// download is still holding costs that download.
  static const Duration reclaimGrace = Duration(hours: 1);

  /// How many hashes one statement — and one transaction — covers. The
  /// check and the unlink hold a write transaction, and a heavily-downloaded
  /// install has tens of thousands of blobs: long enough for one pass over
  /// the whole tree to stall a download that starts mid-sweep. Also stays
  /// clear of SQLite's variables-per-statement ceiling.
  static const int _reclaimBatch = 200;

  /// How many files one pass will unlink. The reclaim runs on the
  /// launch/resume path, beside the work the user is actually waiting for,
  /// and nothing it skips is lost: a file it did not delete is still there
  /// next launch, so a tree that accumulated a lot of garbage drains over
  /// several runs instead of stalling one.
  static const int _reclaimPerRun = 500;

  /// Reclaims blob files no `blobs` row names, plus the `.part` files
  /// interrupted writes leave behind. Returns how many files it removed.
  ///
  /// The index is the authority, so a file it does not name is unreachable:
  /// no screen can show it, no deletion path will ever revisit it, and
  /// [totalDeviceBytes] — the figure the storage cap is enforced against —
  /// cannot see it. Without this pass a download killed at the wrong instant
  /// leaves storage the user can only get back by reinstalling.
  Future<int> reclaimOrphanBlobs({
    Duration grace = reclaimGrace,
    int perRun = _reclaimPerRun,
  }) async {
    final db = await database;
    final blob = await blobStore;
    var removed = await blob.sweepInterruptedWrites(olderThan: grace);
    final orphans = await _unreferencedOnDisk(db, blob, grace, perRun);
    for (var i = 0; i < orphans.length; i += _reclaimBatch) {
      removed += await reclaimUnreferencedBlobs(
        db: db,
        blobStore: blob,
        hashes: orphans.skip(i).take(_reclaimBatch),
      );
    }
    return removed;
  }

  /// At most [perRun] on-disk blobs that no `blobs` row currently names.
  ///
  /// Asked in batches and **outside** any transaction, unlike the unlink
  /// itself. Almost every file in the tree is perfectly well referenced, and
  /// asking about each of them under a write transaction would put the whole
  /// index behind a multi-second pass for the ordinary case of nothing to
  /// reclaim. Being out of date is fine here precisely because it is only a
  /// filter: [reclaimUnreferencedBlobs] re-asks under the transaction that
  /// unlinks, and that re-ask is what a concurrent save is serialised
  /// against.
  Future<List<String>> _unreferencedOnDisk(
    Database db,
    BlobStore blob,
    Duration grace,
    int perRun,
  ) async {
    final hashes = await blob.hashesOnDisk(untouchedFor: grace);
    final orphans = <String>[];
    for (var i = 0; i < hashes.length && orphans.length < perRun; i += _reclaimBatch) {
      final batch = hashes.skip(i).take(_reclaimBatch).toList();
      final rows = await db.query(
        DownloadsSchema.blobs,
        columns: [DownloadsSchema.colHash],
        where: '${DownloadsSchema.colHash} IN (${List.filled(batch.length, '?').join(',')})',
        whereArgs: batch,
      );
      final referenced = {
        for (final row in rows) row[DownloadsSchema.colHash]! as String,
      };
      for (final hash in batch) {
        if (referenced.contains(hash)) continue;
        orphans.add(hash);
        if (orphans.length == perRun) break;
      }
    }
    return orphans;
  }

  bool _isExcluded(
    Map<String, Object?> row,
    Set<ScopedChapterIdentity> excludeOpen,
  ) {
    if (excludeOpen.isEmpty) return false;
    final identity = (
      scopeId: row[DownloadsSchema.colScopeId]! as String,
      id: (
        sourceId: row[DownloadsSchema.colSourceId]! as String,
        seriesKey: row[DownloadsSchema.colSeriesKey]! as String,
        chapterKey: row[DownloadsSchema.colChapterKey]! as String,
      ),
    );
    return excludeOpen.contains(identity);
  }
}
