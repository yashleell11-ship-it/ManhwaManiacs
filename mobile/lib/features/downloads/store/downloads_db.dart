import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Table/column names as bare constants — every query in [DownloadsStore]
/// goes through these instead of inline string literals, so a rename is a
/// one-file change.
abstract final class DownloadsSchema {
  static const savedChapters = 'saved_chapters';
  static const savedPages = 'saved_pages';
  static const blobs = 'blobs';
  static const progressOutbox = 'progress_outbox';

  /// Bookmarks and their outbox, added in schema v3. Both are `scope_id`-led
  /// like every other content table here, so one profile's bookmarks are not
  /// merely hidden from another's — they are unreachable, because no query in
  /// [DownloadsStore] can name a scope other than its own.
  static const bookmarks = 'bookmarks';
  static const bookmarkOutbox = 'bookmark_outbox';

  static const colId = 'id';
  static const colScopeId = 'scope_id';
  static const colSourceId = 'source_id';
  static const colSeriesKey = 'series_key';
  static const colChapterKey = 'chapter_key';
  static const colChapterNumber = 'chapter_number';
  static const colTitle = 'title';
  static const colSeriesTitle = 'series_title';
  static const colPageCount = 'page_count';
  static const colBytes = 'bytes';
  static const colState = 'state';
  static const colPinned = 'pinned';
  static const colReadAt = 'read_at';
  static const colCreatedAt = 'created_at';
  static const colRetryCount = 'retry_count';
  static const colError = 'error';

  /// What the saved blobs hold: `'manga'` (one blob per page image) or
  /// `'novel'` (one blob of paragraph JSON for the whole chapter). Added in
  /// schema v2; every pre-existing row is manga, which is what the column
  /// default says.
  static const colKind = 'kind';

  static const colChapterRowId = 'chapter_rowid';
  static const colPageNumber = 'page_number';
  static const colBlobHash = 'blob_hash';
  static const colSize = 'size';

  static const colHash = 'hash';
  static const colRefcount = 'refcount';

  static const colPayloadJson = 'payload_json';

  // ── bookmarks (v3) ───────────────────────────────────────────────────────

  /// The sync identity: client-generated, opaque, never parsed. The primary
  /// key alongside `scope_id`, which is what makes "do I already hold this
  /// bookmark?" structurally incapable of finding another profile's row.
  static const colClientId = 'client_id';

  /// The server's row id once a flush has come back with one, else NULL. Not
  /// an identity — a bookmark made on a plane has none for as long as the
  /// plane is in the air.
  static const colServerId = 'server_id';

  /// `'manga'` / `'novel'` — what [colAnchorIndex] counts.
  static const colMediaType = 'media_type';

  /// 1-based page (manga) or paragraph (novel).
  static const colAnchorIndex = 'anchor_index';

  /// 0.0–1.0 within the unit [colAnchorIndex] names. A fraction and not
  /// pixels: the same chapter is laid out at different widths on the phone
  /// and on the web.
  static const colAnchorFraction = 'anchor_fraction';

  /// Units in the chapter at capture time; 0 = unknown.
  static const colAnchorTotal = 'anchor_total';

  /// The prose at the bookmarked point, for novels — cached at capture time
  /// so the Bookmarks screen is recognisable with no signal at all.
  static const colSnippet = 'snippet';

  static const colNote = 'note';
  static const colUpdatedAt = 'updated_at';

  /// Tombstone. NULL = live. Rows are never deleted from this table by the
  /// sync path — a delete a device slept through has to be learnable.
  static const colDeletedAt = 'deleted_at';
}

const _dbVersion = 3;

/// The `kind` column's two values. A row's own kind, not a lookup through the
/// sources listing — the offline path has no listing, and a downloaded
/// chapter must be readable on a plane.
const String kMangaDownloadKind = 'manga';
const String kNovelDownloadKind = 'novel';

/// A chapter's NARRATION, stored beside its text rather than inside it.
///
/// Its own row because a novel chapter settles `ready` the moment its one
/// text blob lands. Hanging a 2 MB opus off that row would make the TEXT
/// unreadable offline until the audio finished, and a failed audio fetch
/// would fail the chapter. Separate rows download, retry, fail and delete
/// independently, and both are ordinary rows to refcounting, the storage
/// cap, retention and export.
const String kAudioDownloadKind = 'audio';

/// The on-device store's database file name, under
/// `getApplicationSupportDirectory()` — deliberately **not**
/// `getApplicationDocumentsDirectory()` (that's reserved for blob bytes so
/// the Files app can surface them, spec §3b) and never
/// `getTemporaryDirectory()` (iOS purges it under pressure).
///
/// Kept separate from the blob tree on purpose: a user who deletes files by
/// hand from the Files app can only ever orphan a blob (recoverable — the
/// index still knows what *should* be there), never half-delete this index
/// (not recoverable).
Future<Database> openDownloadsDatabase({String? overridePath}) async {
  final path = overridePath ?? await _defaultDbPath();
  return openDatabase(
    path,
    version: _dbVersion,
    onUpgrade: (db, oldVersion, newVersion) => _migrate(db, oldVersion),
    // A sideloaded older APK is a one-way trip without this. sqflite runs no
    // migration on a downgrade and simply stamps `user_version` back down, so
    // the file keeps its newer tables while claiming to be old — and the next
    // launch of the current build re-runs a migration whose change is already
    // there. That threw, during open, forever: a rollback the user made once
    // left them with a store no build could open again. Re-running the
    // migrations (each one a no-op when its change is present) puts the file
    // back at the current version without touching a downloaded byte, which
    // is why every step in [_migrate] must stay idempotent and additive.
    onDowngrade: (db, oldVersion, newVersion) => _migrate(db, 0),
    onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE ${DownloadsSchema.savedChapters} (
          ${DownloadsSchema.colId} INTEGER PRIMARY KEY AUTOINCREMENT,
          ${DownloadsSchema.colScopeId} TEXT NOT NULL,
          ${DownloadsSchema.colSourceId} TEXT NOT NULL,
          ${DownloadsSchema.colSeriesKey} TEXT NOT NULL,
          ${DownloadsSchema.colChapterKey} TEXT NOT NULL,
          ${DownloadsSchema.colChapterNumber} REAL,
          ${DownloadsSchema.colTitle} TEXT,
          ${DownloadsSchema.colSeriesTitle} TEXT,
          ${DownloadsSchema.colPageCount} INTEGER NOT NULL DEFAULT 0,
          ${DownloadsSchema.colBytes} INTEGER NOT NULL DEFAULT 0,
          ${DownloadsSchema.colState} TEXT NOT NULL,
          ${DownloadsSchema.colPinned} INTEGER NOT NULL DEFAULT 0,
          ${DownloadsSchema.colReadAt} TEXT,
          ${DownloadsSchema.colCreatedAt} TEXT NOT NULL,
          ${DownloadsSchema.colRetryCount} INTEGER NOT NULL DEFAULT 0,
          ${DownloadsSchema.colError} TEXT,
          ${DownloadsSchema.colKind} TEXT NOT NULL DEFAULT '$kMangaDownloadKind',
          UNIQUE(
            ${DownloadsSchema.colScopeId},
            ${DownloadsSchema.colSourceId},
            ${DownloadsSchema.colSeriesKey},
            ${DownloadsSchema.colChapterKey}
          )
        )
      ''');
      await db.execute('''
        CREATE TABLE ${DownloadsSchema.savedPages} (
          ${DownloadsSchema.colScopeId} TEXT NOT NULL,
          ${DownloadsSchema.colChapterRowId} INTEGER NOT NULL,
          ${DownloadsSchema.colPageNumber} INTEGER NOT NULL,
          ${DownloadsSchema.colBlobHash} TEXT NOT NULL,
          ${DownloadsSchema.colSize} INTEGER NOT NULL,
          PRIMARY KEY (
            ${DownloadsSchema.colScopeId},
            ${DownloadsSchema.colChapterRowId},
            ${DownloadsSchema.colPageNumber}
          )
        )
      ''');
      await db.execute('''
        CREATE TABLE ${DownloadsSchema.blobs} (
          ${DownloadsSchema.colHash} TEXT PRIMARY KEY,
          ${DownloadsSchema.colRefcount} INTEGER NOT NULL DEFAULT 0,
          ${DownloadsSchema.colSize} INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE ${DownloadsSchema.progressOutbox} (
          ${DownloadsSchema.colId} INTEGER PRIMARY KEY AUTOINCREMENT,
          ${DownloadsSchema.colScopeId} TEXT NOT NULL,
          ${DownloadsSchema.colPayloadJson} TEXT NOT NULL,
          ${DownloadsSchema.colCreatedAt} TEXT NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_saved_pages_chapter '
        'ON ${DownloadsSchema.savedPages}(${DownloadsSchema.colScopeId}, ${DownloadsSchema.colChapterRowId})',
      );
      await db.execute(
        'CREATE INDEX idx_progress_outbox_scope '
        'ON ${DownloadsSchema.progressOutbox}(${DownloadsSchema.colScopeId})',
      );
      await _createBookmarkTables(db);
    },
  );
}

/// Every additive step from [oldVersion] to the current schema.
///
/// Each step checks for its own change first rather than trusting the version
/// stamp, because the stamp is not trustworthy: an older build that opened
/// this file lowered it without undoing anything (see `onDowngrade`). A step
/// that would fail on a change already present is what turns one rollback
/// into a permanently unopenable store.
Future<void> _migrate(Database db, int oldVersion) async {
  // v1 → v2: novels. `ADD COLUMN` with a default is the one schema change
  // SQLite performs without rewriting the table, so an install with thousands
  // of downloaded chapters upgrades instantly — and every row that already
  // exists is a manga chapter, which is exactly what the default backfills.
  if (oldVersion < 2 &&
      !await _hasColumn(db, DownloadsSchema.savedChapters, DownloadsSchema.colKind)) {
    await db.execute(
      'ALTER TABLE ${DownloadsSchema.savedChapters} '
      'ADD COLUMN ${DownloadsSchema.colKind} TEXT NOT NULL '
      "DEFAULT '$kMangaDownloadKind'",
    );
  }
  // v2 → v3: offline bookmarks. Purely additive — two new tables and their
  // indexes, nothing dropped and no table rewritten — because the owner's
  // phone holds real downloads and real reading progress in the tables above,
  // and a destructive recreate would take them with it. The same DDL as
  // `onCreate` runs here, from one place, so a phone that upgrades and a
  // phone installed fresh cannot end up with different columns.
  if (oldVersion < 3) {
    await _createBookmarkTables(db);
  }
}

Future<bool> _hasColumn(Database db, String table, String column) async {
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  return columns.any((row) => row['name'] == column);
}

/// The `bookmarks` + `bookmark_outbox` DDL, run by both `onCreate` and the
/// v2 → v3 `onUpgrade` so the two paths cannot drift.
///
/// `IF NOT EXISTS` throughout: an install that has already been upgraded once
/// and is then opened by a build whose `onCreate` runs (a restored database
/// file, a re-created path) must not fail on a table it already holds.
Future<void> _createBookmarkTables(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS ${DownloadsSchema.bookmarks} (
      ${DownloadsSchema.colScopeId} TEXT NOT NULL,
      ${DownloadsSchema.colClientId} TEXT NOT NULL,
      ${DownloadsSchema.colServerId} INTEGER,
      ${DownloadsSchema.colSourceId} TEXT NOT NULL,
      ${DownloadsSchema.colSeriesKey} TEXT NOT NULL,
      ${DownloadsSchema.colChapterKey} TEXT NOT NULL,
      ${DownloadsSchema.colSeriesTitle} TEXT,
      ${DownloadsSchema.colChapterNumber} REAL,
      -- Literal rather than [kMangaDownloadKind]: the two vocabularies happen
      -- to spell manga the same way, but a downloaded chapter's kind and a
      -- bookmark's medium are different facts and must be free to diverge.
      ${DownloadsSchema.colMediaType} TEXT NOT NULL DEFAULT 'manga',
      ${DownloadsSchema.colAnchorIndex} INTEGER NOT NULL DEFAULT 1,
      ${DownloadsSchema.colAnchorFraction} REAL NOT NULL DEFAULT 0,
      ${DownloadsSchema.colAnchorTotal} INTEGER NOT NULL DEFAULT 0,
      ${DownloadsSchema.colSnippet} TEXT,
      ${DownloadsSchema.colNote} TEXT,
      ${DownloadsSchema.colCreatedAt} TEXT NOT NULL,
      ${DownloadsSchema.colUpdatedAt} TEXT NOT NULL,
      ${DownloadsSchema.colDeletedAt} TEXT,
      PRIMARY KEY (
        ${DownloadsSchema.colScopeId},
        ${DownloadsSchema.colClientId}
      )
    )
  ''');
  // The outbox mirrors `progress_outbox` — an autoincrement id, the scope, an
  // opaque JSON payload and a stamp — with the payload carrying the op
  // (`upsert` / `delete`) as well as the body. One table for both ops, because
  // the ORDER between them is the whole correctness argument: a create
  // followed by a delete has to reach the server in that order, and two
  // tables could not express it.
  await db.execute('''
    CREATE TABLE IF NOT EXISTS ${DownloadsSchema.bookmarkOutbox} (
      ${DownloadsSchema.colId} INTEGER PRIMARY KEY AUTOINCREMENT,
      ${DownloadsSchema.colScopeId} TEXT NOT NULL,
      ${DownloadsSchema.colClientId} TEXT NOT NULL,
      ${DownloadsSchema.colPayloadJson} TEXT NOT NULL,
      ${DownloadsSchema.colCreatedAt} TEXT NOT NULL
    )
  ''');
  // The Bookmarks screen's default order — newest change first, inside one
  // scope. The primary key already covers lookup by client id, which is every
  // other read the sync path does.
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_bookmarks_scope_updated '
    'ON ${DownloadsSchema.bookmarks}('
    '${DownloadsSchema.colScopeId}, ${DownloadsSchema.colUpdatedAt})',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_bookmark_outbox_scope '
    'ON ${DownloadsSchema.bookmarkOutbox}(${DownloadsSchema.colScopeId})',
  );
}

Future<String> _defaultDbPath() async {
  final dir = await getApplicationSupportDirectory();
  final storeDir = Directory(p.join(dir.path, 'mm-store'));
  if (!storeDir.existsSync()) storeDir.createSync(recursive: true);
  return p.join(storeDir.path, 'downloads.db');
}
