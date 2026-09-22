import 'dart:convert';
import 'dart:io';

import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';
import 'package:manhwamaniacs/features/downloads/models/series_storage_usage.dart';
import 'package:manhwamaniacs/features/downloads/services/blob_store.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_db.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_deletion.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:sqflite/sqflite.dart';

/// The on-device chapter store for exactly one `(user, profile)` scope.
///
/// **Isolation is structural, not conventional.** [scopeId] is fixed at
/// construction and every query below adds `WHERE scope_id = ?scopeId`
/// itself — there is no method on this class that accepts a caller-supplied
/// scope, so there is no call site that could pass the wrong one. The
/// [DownloadsStore] provider (`providers/downloads_scope.dart`) returns
/// `null` — no instance at all — when either half of the scope is missing,
/// so a screen with no resolvable store renders "nothing downloaded" rather
/// than falling back to some default scope.
///
/// The one exception is [blobs]: content-addressed and refcounted *across*
/// scopes on purpose, so two profiles downloading the same chapter store one
/// copy. A blob's bytes carry no per-profile information — only the
/// `saved_pages` row that references it does, and that row is scoped.
class DownloadsStore {
  DownloadsStore({
    required this.scopeId,
    required this.database,
    required this.blobStore,
  });

  final String scopeId;
  final Future<Database> database;
  final Future<BlobStore> blobStore;

  // ── Queueing ───────────────────────────────────────────────────────────

  /// Ensures a chapter has a row in this scope, in the [DownloadChapterState.queued]
  /// state, ready for the queue engine to pick up. Idempotent:
  ///
  /// - Already `queued`/`downloading`/`complete` → left untouched, so a
  ///   double-tap on "Download" never restarts an in-flight fetch or
  ///   re-queues a finished chapter.
  /// - `failed` → reset to `queued` with `retry_count` and `error` cleared —
  ///   this is also what a manual "Retry" tap calls.
  ///
  /// Returns the row id.
  Future<int> ensureQueued({
    required ChapterIdentity id,
    double? chapterNumber,
    String? title,
    String? seriesTitle,
    DownloadKind kind = DownloadKind.manga,
  }) async {
    final db = await database;
    final existing = await _getRow(db, id);
    if (existing != null) {
      final state = DownloadChapterState.fromWire(
        existing[DownloadsSchema.colState]! as String,
      );
      if (state == DownloadChapterState.failed) {
        await db.update(
          DownloadsSchema.savedChapters,
          {
            DownloadsSchema.colState: DownloadChapterState.queued.wire,
            DownloadsSchema.colRetryCount: 0,
            DownloadsSchema.colError: null,
          },
          where: '${DownloadsSchema.colId} = ?',
          whereArgs: [existing[DownloadsSchema.colId]],
        );
      }
      return existing[DownloadsSchema.colId]! as int;
    }

    return db.insert(DownloadsSchema.savedChapters, {
      DownloadsSchema.colScopeId: scopeId,
      DownloadsSchema.colSourceId: id.sourceId,
      DownloadsSchema.colSeriesKey: id.seriesKey,
      DownloadsSchema.colChapterKey: id.chapterKey,
      DownloadsSchema.colChapterNumber: chapterNumber,
      DownloadsSchema.colTitle: title,
      DownloadsSchema.colSeriesTitle: seriesTitle,
      DownloadsSchema.colPageCount: 0,
      DownloadsSchema.colBytes: 0,
      DownloadsSchema.colState: DownloadChapterState.queued.wire,
      DownloadsSchema.colPinned: 0,
      DownloadsSchema.colReadAt: null,
      DownloadsSchema.colCreatedAt: DateTime.now().toUtc().toIso8601String(),
      DownloadsSchema.colRetryCount: 0,
      DownloadsSchema.colError: null,
      DownloadsSchema.colKind: kind.wire,
    });
  }

  /// Chapters waiting for or mid-download, oldest first — the durable queue.
  /// Re-read on every app launch so a kill mid-download resumes rather than
  /// vanishing.
  Future<List<SavedChapter>> pendingChapters() async {
    final db = await database;
    final rows = await db.query(
      DownloadsSchema.savedChapters,
      where: '${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colState} IN (?, ?)',
      whereArgs: [
        scopeId,
        DownloadChapterState.queued.wire,
        DownloadChapterState.downloading.wire,
      ],
      orderBy: DownloadsSchema.colCreatedAt,
    );
    return rows.map(SavedChapter.fromRow).toList();
  }

  /// Everything the queue still owes the user — queued, mid-download **and**
  /// failed — oldest first, i.e. exactly what the Downloads screen's queue
  /// panel lists and what its badge counts.
  ///
  /// Deliberately wider than [pendingChapters] (which drives the engine and
  /// must never re-pick a chapter that exhausted its retries): a failed
  /// chapter is not work the queue will do on its own, but it is absolutely
  /// still something the user is waiting on and can retry.
  Future<List<SavedChapter>> unfinishedChapters() async {
    final db = await database;
    final rows = await db.query(
      DownloadsSchema.savedChapters,
      where:
          '${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colState} IN (?, ?, ?)',
      whereArgs: [
        scopeId,
        DownloadChapterState.queued.wire,
        DownloadChapterState.downloading.wire,
        DownloadChapterState.failed.wire,
      ],
      orderBy: DownloadsSchema.colCreatedAt,
    );
    return rows.map(SavedChapter.fromRow).toList();
  }

  Future<void> updateManifestInfo({
    required int rowId,
    required int pageCount,
    double? chapterNumber,
    String? title,
    String? seriesTitle,
  }) async {
    final db = await database;
    await db.update(
      DownloadsSchema.savedChapters,
      {
        DownloadsSchema.colPageCount: pageCount,
        DownloadsSchema.colState: DownloadChapterState.downloading.wire,
        if (chapterNumber != null) DownloadsSchema.colChapterNumber: chapterNumber,
        if (title != null) DownloadsSchema.colTitle: title,
        if (seriesTitle != null) DownloadsSchema.colSeriesTitle: seriesTitle,
      },
      where: '${DownloadsSchema.colId} = ? AND ${DownloadsSchema.colScopeId} = ?',
      whereArgs: [rowId, scopeId],
    );
  }

  /// Page numbers already saved for this chapter — the resume check. Fetching
  /// a manifest again after a kill is cheap; re-fetching pages already on
  /// disk is not, so the queue engine skips every number in this set.
  Future<Set<int>> existingPageNumbers(int rowId) async {
    final db = await database;
    final rows = await db.query(
      DownloadsSchema.savedPages,
      columns: [DownloadsSchema.colPageNumber],
      where: '${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colChapterRowId} = ?',
      whereArgs: [scopeId, rowId],
    );
    return rows.map((r) => r[DownloadsSchema.colPageNumber]! as int).toSet();
  }

  /// Writes one page's bytes to the blob tree and records it against
  /// [rowId]. Safe to call twice for the same page (e.g. a retry racing a
  /// resume) — the second call is a no-op for both the blob refcount and the
  /// chapter's byte total.
  ///
  /// The bytes are hashed first and written **last, inside the transaction**,
  /// so the disk only ever holds what a row names: a page number re-saved
  /// with different bytes is rejected below and never reaches the tree, and
  /// a write that throws takes the refcount that would have pointed at it
  /// down with it. Writing before the insert is what used to leave a file
  /// with nothing referencing it — invisible to every deletion path and to
  /// `RetentionMaintenance.totalDeviceBytes`.
  Future<void> savePage({
    required int rowId,
    required int pageNumber,
    required List<int> bytes,
  }) async {
    final blob = await blobStore;
    final written = (hash: BlobStore.hashOf(bytes), size: bytes.length);
    final db = await database;
    await db.transaction((txn) async {
      // A page whose chapter row this scope no longer holds — "Remove
      // download" tapped while the queue was still fetching — has nothing to
      // belong to. Storing it anyway files bytes under a row no screen can
      // reach and no deletion path will ever revisit.
      final chapterRows = await txn.query(
        DownloadsSchema.savedChapters,
        columns: [DownloadsSchema.colId],
        where: '${DownloadsSchema.colId} = ? AND ${DownloadsSchema.colScopeId} = ?',
        whereArgs: [rowId, scopeId],
        limit: 1,
      );
      if (chapterRows.isEmpty) return;

      final pageInserted = await txn.insert(
        DownloadsSchema.savedPages,
        {
          DownloadsSchema.colScopeId: scopeId,
          DownloadsSchema.colChapterRowId: rowId,
          DownloadsSchema.colPageNumber: pageNumber,
          DownloadsSchema.colBlobHash: written.hash,
          DownloadsSchema.colSize: written.size,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      // insert() returns the new rowid, but ConflictAlgorithm.ignore returns
      // 0 on a no-op conflict — sqflite's documented way to detect it.
      if (pageInserted == 0) return;

      final blobRow = await txn.query(
        DownloadsSchema.blobs,
        where: '${DownloadsSchema.colHash} = ?',
        whereArgs: [written.hash],
      );
      if (blobRow.isEmpty) {
        await txn.insert(DownloadsSchema.blobs, {
          DownloadsSchema.colHash: written.hash,
          DownloadsSchema.colRefcount: 1,
          DownloadsSchema.colSize: written.size,
        });
      } else {
        await txn.rawUpdate(
          'UPDATE ${DownloadsSchema.blobs} SET ${DownloadsSchema.colRefcount} = ${DownloadsSchema.colRefcount} + 1 '
          'WHERE ${DownloadsSchema.colHash} = ?',
          [written.hash],
        );
      }

      await txn.rawUpdate(
        'UPDATE ${DownloadsSchema.savedChapters} SET ${DownloadsSchema.colBytes} = ${DownloadsSchema.colBytes} + ? '
        'WHERE ${DownloadsSchema.colId} = ? AND ${DownloadsSchema.colScopeId} = ?',
        [written.size, rowId, scopeId],
      );

      // Last, and still inside the transaction: the bytes and the rows that
      // name them commit together. This is also what makes the reclaim in
      // `downloads_deletion.dart` safe to run — a hash it finds unreferenced
      // cannot be picked up by a save that is halfway through, because that
      // save's own transaction has not started or has already finished.
      await blob.writeHashed(written.hash, bytes);
    });
  }

  /// Marks the chapter complete **only if** every page is actually present —
  /// the one guard standing between a race in the queue engine and a chapter
  /// that claims to be downloaded but isn't. Returns whether it did.
  Future<bool> markCompleteIfAllPagesPresent(int rowId) async {
    final db = await database;
    final chapterRows = await db.query(
      DownloadsSchema.savedChapters,
      where: '${DownloadsSchema.colId} = ? AND ${DownloadsSchema.colScopeId} = ?',
      whereArgs: [rowId, scopeId],
    );
    if (chapterRows.isEmpty) return false;
    final pageCount = chapterRows.first[DownloadsSchema.colPageCount]! as int;
    if (pageCount <= 0) return false;

    // Counted against the manifest as it stands NOW, not against every page
    // ever saved for this chapter. A manifest that shrank between passes
    // leaves pages numbered past its end, and counting those would let a
    // chapter go complete with one of the pages it actually needs missing.
    final countResult = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${DownloadsSchema.savedPages} '
      'WHERE ${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colChapterRowId} = ? '
      'AND ${DownloadsSchema.colPageNumber} BETWEEN 1 AND ?',
      [scopeId, rowId, pageCount],
    );
    final present = Sqflite.firstIntValue(countResult) ?? 0;
    if (present < pageCount) return false;

    // Before the state flips, never after: "complete" is read everywhere as
    // "openable offline", and [isAvailableOffline] gets there by comparing
    // the pages on disk against `page_count` — a page left over from a longer
    // manifest fails that comparison for good. A crash between the prune and
    // the update leaves the chapter downloading, which resume already knows
    // how to finish.
    await prunePagesBeyond(
      db: db,
      blobStore: await blobStore,
      chapterRowId: rowId,
      scopeId: scopeId,
      lastPageNumber: pageCount,
    );

    await db.update(
      DownloadsSchema.savedChapters,
      {DownloadsSchema.colState: DownloadChapterState.complete.wire, DownloadsSchema.colError: null},
      where: '${DownloadsSchema.colId} = ? AND ${DownloadsSchema.colScopeId} = ?',
      whereArgs: [rowId, scopeId],
    );
    return true;
  }

  Future<void> incrementRetry(int rowId) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE ${DownloadsSchema.savedChapters} SET ${DownloadsSchema.colRetryCount} = ${DownloadsSchema.colRetryCount} + 1 '
      'WHERE ${DownloadsSchema.colId} = ? AND ${DownloadsSchema.colScopeId} = ?',
      [rowId, scopeId],
    );
  }

  Future<void> markFailed({required int rowId, required String error}) async {
    final db = await database;
    await db.update(
      DownloadsSchema.savedChapters,
      {DownloadsSchema.colState: DownloadChapterState.failed.wire, DownloadsSchema.colError: error},
      where: '${DownloadsSchema.colId} = ? AND ${DownloadsSchema.colScopeId} = ?',
      whereArgs: [rowId, scopeId],
    );
  }

  // ── Novel text ─────────────────────────────────────────────────────────
  //
  // A novel chapter is not made of pages, so it is stored as exactly ONE
  // blob — the chapter's sanitized paragraphs as JSON — under page number
  // [novelTextBlobNumber], with `page_count = 1`. Both helpers below
  // delegate to the page path rather than reimplementing it, which is the
  // whole point: refcounting, cross-profile dedup, the read-then-expire
  // sweep, the per-series byte totals and the storage cap all keep working
  // with no novel-shaped special case anywhere. Text blobs are a few
  // kilobytes next to a page image's megabyte, so the cap barely notices
  // them.

  /// The one blob number a novel chapter's text lives at.
  static const int novelTextBlobNumber = 1;

  /// A chapter's narration, on its own row. Same blob number as the text
  /// because the ROW's kind says which it is.
  static const int audioBlobNumber = 1;

  /// The timing map that audio was rendered with — the second of the audio
  /// row's two blobs (`page_count = 2`).
  ///
  /// Saved WITH the audio rather than fetched at play time, for two reasons:
  /// with no network there is nothing to fetch it from, and a chapter
  /// re-rendered on the server gets a new map that no longer matches the
  /// bytes on the phone. A second blob on the same row keeps every guarantee
  /// the first one has — the completeness check needs both, and deleting the
  /// row releases both.
  static const int audioTimingBlobNumber = 2;

  /// How many blobs an audio row holds: the opus and its timing map.
  static const int audioBlobCount = 2;

  /// Writes [chapter] (a [NovelChapter.toStoredJson] map) as this chapter's
  /// single blob. Idempotent for the same text, exactly like [savePage].
  /// Store one chapter's narration.
  ///
  /// Goes through [savePage] like everything else, so the opus is
  /// content-addressed in the shared `blobs` table: two profiles reading the
  /// same book share one file, and the bytes are released only when the last
  /// row lets go.
  Future<void> saveAudio({required int rowId, required List<int> bytes}) =>
      savePage(rowId: rowId, pageNumber: audioBlobNumber, bytes: bytes);

  /// Store the timing map [saveAudio]'s bytes were rendered with — the JSON
  /// `GET /novels/audio` answered, as `NovelAudio.toJson` writes it.
  Future<void> saveAudioTiming({
    required int rowId,
    required Map<String, dynamic> timing,
  }) =>
      savePage(
        rowId: rowId,
        pageNumber: audioTimingBlobNumber,
        bytes: utf8.encode(jsonEncode(timing)),
      );

  /// A chapter's saved narration: the opus file to play and the timing map
  /// to follow along with, or `null` unless BOTH are on disk and the row is
  /// complete.
  ///
  /// [id] is the CHAPTER's identity, not the audio row's — callers think in
  /// chapters, and the `:audio` suffix is this store's business.
  ///
  /// Never throws. A missing file (deleted by hand through the Files app), a
  /// half-finished download or a corrupt map all read as "not saved", which
  /// sends the reader back to streaming instead of to an error.
  Future<({File audio, Map<String, dynamic> timing})?> readSavedNarration(
    ChapterIdentity id,
  ) async {
    try {
      final audioId = audioIdentity(textIdentity(id));
      final chapter = await getChapter(audioId);
      if (chapter == null ||
          !chapter.kind.isAudio ||
          chapter.state != DownloadChapterState.complete) {
        return null;
      }
      final paths = await localPagePaths(audioId);
      final audio = paths[audioBlobNumber];
      final timingFile = paths[audioTimingBlobNumber];
      if (audio == null || timingFile == null) return null;
      final decoded = jsonDecode(await timingFile.readAsString());
      if (decoded is! Map) return null;
      return (audio: audio, timing: Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveNovelText({
    required int rowId,
    required Map<String, dynamic> chapter,
  }) =>
      savePage(
        rowId: rowId,
        pageNumber: novelTextBlobNumber,
        bytes: utf8.encode(jsonEncode(chapter)),
      );

  /// Reads a downloaded novel chapter's stored JSON back, or `null` when it
  /// is not on disk (never downloaded, mid-download, or the blob file was
  /// deleted by hand through the Files app).
  ///
  /// Corrupt JSON reads as `null` rather than throwing: a damaged blob must
  /// degrade to "not available offline" — which falls back to the network —
  /// not to an exception out of the reader.
  Future<Map<String, dynamic>?> readNovelText(ChapterIdentity id) async {
    final paths = await localPagePaths(id);
    final file = paths[novelTextBlobNumber];
    if (file == null) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  // ── Reading ────────────────────────────────────────────────────────────

  Future<SavedChapter?> getChapter(ChapterIdentity id) async {
    final db = await database;
    final row = await _getRow(db, id);
    return row == null ? null : SavedChapter.fromRow(row);
  }

  /// True when [id] is fully downloaded in this scope and every one of its
  /// blob files still exists on disk (a user can delete files by hand
  /// through the Files app — this is how that shows up as "not actually
  /// available" instead of serving a broken image).
  Future<bool> isAvailableOffline(ChapterIdentity id) async {
    final chapter = await getChapter(id);
    if (chapter == null || chapter.state != DownloadChapterState.complete) {
      return false;
    }
    final paths = await localPagePaths(id);
    return paths.length == chapter.pageCount &&
        paths.values.every((f) => f.existsSync() && f.lengthSync() > 0);
  }

  /// Absolute on-disk paths for every page of [id] currently present in this
  /// scope, keyed by page number. Only includes pages whose blob file still
  /// exists — an orphaned index row (file deleted by hand) is silently
  /// skipped so callers fall back to network for just that page.
  Future<Map<int, File>> localPagePaths(ChapterIdentity id) async {
    final db = await database;
    final chapterRow = await _getRow(db, id);
    if (chapterRow == null) return {};
    final rowId = chapterRow[DownloadsSchema.colId]! as int;

    final rows = await db.query(
      DownloadsSchema.savedPages,
      where: '${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colChapterRowId} = ?',
      whereArgs: [scopeId, rowId],
    );

    final blob = await blobStore;
    final result = <int, File>{};
    for (final row in rows) {
      final hash = row[DownloadsSchema.colBlobHash]! as String;
      final file = blob.pathFor(hash);
      if (file.existsSync() && file.lengthSync() > 0) {
        result[row[DownloadsSchema.colPageNumber]! as int] = file;
      }
    }
    return result;
  }

  /// Every chapter row in this scope, newest first.
  ///
  /// Narration rows are left out unless [includeNarration] asks for them. A
  /// saved narration is not a CHAPTER — it hangs off one, under a key no
  /// source ever issued — and every caller that lists chapters (an offline
  /// series page, a table of contents' download badges) would otherwise grow
  /// a phantom "c120:audio" chapter beside the real one. The Downloads screen
  /// is the one place that asks for them, so the megabytes are never hidden.
  Future<List<SavedChapter>> listChapters({
    bool includeNarration = false,
  }) async {
    final db = await database;
    final rows = await db.query(
      DownloadsSchema.savedChapters,
      where: includeNarration
          ? '${DownloadsSchema.colScopeId} = ?'
          : '${DownloadsSchema.colScopeId} = ? AND '
              '${DownloadsSchema.colKind} IS NOT ?',
      whereArgs: [scopeId, if (!includeNarration) kAudioDownloadKind],
      orderBy: '${DownloadsSchema.colCreatedAt} DESC',
    );
    return rows.map(SavedChapter.fromRow).toList();
  }

  Future<List<SeriesStorageUsage>> seriesBreakdown() async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT ${DownloadsSchema.colSourceId}, ${DownloadsSchema.colSeriesKey},
             MAX(${DownloadsSchema.colSeriesTitle}) AS series_title,
             SUM(${DownloadsSchema.colBytes}) AS total_bytes,
             -- A saved narration's bytes are real and counted above; it is
             -- not another chapter, so it is not counted here.
             SUM(CASE WHEN ${DownloadsSchema.colKind} IS ? THEN 0 ELSE 1 END)
               AS chapter_count,
             SUM(${DownloadsSchema.colPinned}) AS pinned_count
      FROM ${DownloadsSchema.savedChapters}
      WHERE ${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colState} = ?
      GROUP BY ${DownloadsSchema.colSourceId}, ${DownloadsSchema.colSeriesKey}
      ORDER BY total_bytes DESC
      ''',
      [kAudioDownloadKind, scopeId, DownloadChapterState.complete.wire],
    );
    return rows
        .map(
          (row) => SeriesStorageUsage(
            sourceId: row[DownloadsSchema.colSourceId]! as String,
            seriesKey: row[DownloadsSchema.colSeriesKey]! as String,
            seriesTitle: row['series_title'] as String?,
            bytes: (row['total_bytes'] as num?)?.toInt() ?? 0,
            chapterCount: (row['chapter_count'] as num?)?.toInt() ?? 0,
            pinnedChapterCount: (row['pinned_count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList();
  }

  /// This scope's own nominal total (sum of each complete chapter's byte
  /// count). Cross-profile dedup means the *actual* disk usage can be lower
  /// than the sum of every profile's totals — see
  /// `RetentionMaintenance.totalDeviceBytes` for the real figure the cap
  /// enforces against.
  Future<int> scopeBytes() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT SUM(${DownloadsSchema.colBytes}) AS total FROM ${DownloadsSchema.savedChapters} '
      'WHERE ${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colState} = ?',
      [scopeId, DownloadChapterState.complete.wire],
    );
    return (result.first['total'] as num?)?.toInt() ?? 0;
  }

  // ── Pin / read state ───────────────────────────────────────────────────

  Future<void> setSeriesPinned({
    required SeriesIdentity series,
    required bool pinned,
  }) async {
    final db = await database;
    await db.update(
      DownloadsSchema.savedChapters,
      {DownloadsSchema.colPinned: pinned ? 1 : 0},
      where: '${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colSourceId} = ? AND ${DownloadsSchema.colSeriesKey} = ?',
      whereArgs: [scopeId, series.sourceId, series.seriesKey],
    );
  }

  /// Stamps `read_at` — call when a downloaded chapter reaches
  /// `read_complete`. A no-op when [id] has no row in this scope (the
  /// chapter was never downloaded, so there is nothing to expire).
  Future<void> markRead(ChapterIdentity id) async {
    // Best-effort local bookkeeping, called fire-and-forget from reader
    // completion — a platform-channel hiccup here must never surface as an
    // unhandled error in the reader.
    try {
      final db = await database;
      // The chapter and its narration together. The readers only ever know
      // the chapter's own key, so stamping just that row left a saved
      // narration with no `read_at` — exempt from read-then-expire forever,
      // megabytes outliving the text they belong to.
      await db.update(
        DownloadsSchema.savedChapters,
        {DownloadsSchema.colReadAt: DateTime.now().toUtc().toIso8601String()},
        where: '${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colSourceId} = ? AND '
            '${DownloadsSchema.colSeriesKey} = ? AND ${DownloadsSchema.colChapterKey} IN (?, ?)',
        whereArgs: [
          scopeId,
          id.sourceId,
          id.seriesKey,
          id.chapterKey,
          audioIdentity(id).chapterKey,
        ],
      );
    } catch (_) {
      // Retried next time this chapter reaches read_complete.
    }
  }

  /// Clears `read_at` — call when a downloaded chapter is re-opened, so a
  /// deliberate re-read is never deleted out from under the reader.
  Future<void> clearReadStamp(ChapterIdentity id) async {
    // Best-effort local bookkeeping, called fire-and-forget on chapter open
    // (see OpenChapterScope) — must never surface as an unhandled error.
    try {
      final db = await database;
      // Both rows, for the same reason [markRead] stamps both: a re-read
      // must not leave the narration to expire out from under the listener.
      await db.update(
        DownloadsSchema.savedChapters,
        {DownloadsSchema.colReadAt: null},
        where: '${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colSourceId} = ? AND '
            '${DownloadsSchema.colSeriesKey} = ? AND ${DownloadsSchema.colChapterKey} IN (?, ?)',
        whereArgs: [
          scopeId,
          id.sourceId,
          id.seriesKey,
          id.chapterKey,
          audioIdentity(id).chapterKey,
        ],
      );
    } catch (_) {
      // If the read-then-expire sweep beats a retry to it, the chapter is
      // simply re-downloaded — never a data-loss failure mode.
    }
  }

  /// Removes [id]'s on-device bytes from this scope — the user-facing
  /// "Remove download" action. Progress and read history survive (see
  /// [deleteChapterAndBlobs]); a no-op if [id] has no row in this scope.
  Future<void> deleteDownload(ChapterIdentity id) async {
    final db = await database;
    final store = await blobStore;

    // The chapter AND its narration. The audio row is invisible to every
    // screen, so leaving it behind strands a couple of megabytes that nothing
    // will show and nothing will collect — its blob refcount is still held,
    // so the orphan sweep will not take it either.
    //
    // Both go through the same delete, so refcounting, the freed-bytes total
    // and the scope predicate are identical for each.
    for (final target in {id, audioIdentity(id)}) {
      final row = await _getRow(db, target);
      if (row == null) continue;
      await deleteChapterAndBlobs(
        db: db,
        blobStore: store,
        chapterRowId: row[DownloadsSchema.colId]! as int,
        scopeId: scopeId,
      );
    }
  }

  // ── Progress outbox ────────────────────────────────────────────────────
  //
  // Every reader progress save writes here first — the reader must never
  // block on (or lose a save to) a flaky connection. `flushProgressOutbox`
  // (`services/progress_outbox.dart`) drains this on connectivity/app-resume
  // via `POST /reader/progress/batch`; the server's furthest-wins merge
  // makes replaying an already-flushed push harmless, so a crash between a
  // successful POST and this row's deletion self-heals on the next flush.

  Future<void> enqueueProgress(ProgressPush push) async {
    final db = await database;
    await db.insert(DownloadsSchema.progressOutbox, {
      DownloadsSchema.colScopeId: scopeId,
      DownloadsSchema.colPayloadJson: jsonEncode(push.toJson()),
      DownloadsSchema.colCreatedAt: DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Every push still waiting to reach the server, oldest first, alongside
  /// the outbox row id a caller must pass back to [clearProgressOutbox] once
  /// it has actually been accepted.
  Future<List<(int outboxId, ProgressPush push)>> pendingProgressOutbox() async {
    final db = await database;
    final rows = await db.query(
      DownloadsSchema.progressOutbox,
      where: '${DownloadsSchema.colScopeId} = ?',
      whereArgs: [scopeId],
      orderBy: DownloadsSchema.colCreatedAt,
    );
    return [
      for (final row in rows)
        (
          row[DownloadsSchema.colId]! as int,
          ProgressPush.fromJson(
            jsonDecode(row[DownloadsSchema.colPayloadJson]! as String)
                as Map<String, dynamic>,
          ),
        ),
    ];
  }

  Future<void> clearProgressOutbox(List<int> outboxIds) async {
    if (outboxIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(outboxIds.length, '?').join(',');
    await db.delete(
      DownloadsSchema.progressOutbox,
      where: '${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colId} IN ($placeholders)',
      whereArgs: [scopeId, ...outboxIds],
    );
  }

  Future<Map<String, Object?>?> _getRow(Database db, ChapterIdentity id) async {
    final rows = await db.query(
      DownloadsSchema.savedChapters,
      where: '${DownloadsSchema.colScopeId} = ? AND ${DownloadsSchema.colSourceId} = ? AND '
          '${DownloadsSchema.colSeriesKey} = ? AND ${DownloadsSchema.colChapterKey} = ?',
      whereArgs: [scopeId, id.sourceId, id.seriesKey, id.chapterKey],
    );
    return rows.isEmpty ? null : rows.first;
  }
}
