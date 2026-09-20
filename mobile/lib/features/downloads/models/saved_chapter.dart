import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_db.dart';

/// A `saved_chapters` row — one chapter's on-device download record for one
/// `(user, profile)` scope. Mirrors `docs/superpowers/specs/…mobile-source-native-design.md`
/// §3's schema.
/// What a saved chapter's blobs hold.
///
/// A novel chapter is stored as ONE blob of paragraph JSON, so its
/// [SavedChapter.pageCount] is 1 and means "one blob", not "one page". Nothing
/// in the store needed to change for that — refcounting, the read-then-expire
/// sweep and the storage cap all work on blobs and bytes, and text blobs are
/// tiny next to page images. What needed to change is that the row can now
/// SAY which it is, so the reader and the Downloads screen do not have to
/// guess from a page count of 1.
enum DownloadKind {
  manga,
  novel,

  /// A chapter read aloud. One opus blob, stored as its own row beside the
  /// text — see [kAudioDownloadKind] for why it is not a second page on the
  /// novel row.
  audio;

  static DownloadKind fromWire(String? value) => switch (value) {
    kNovelDownloadKind => DownloadKind.novel,
    kAudioDownloadKind => DownloadKind.audio,
    _ => DownloadKind.manga,
  };

  String get wire => switch (this) {
    DownloadKind.novel => kNovelDownloadKind,
    DownloadKind.audio => kAudioDownloadKind,
    DownloadKind.manga => kMangaDownloadKind,
  };

  bool get isNovel => this == DownloadKind.novel;

  bool get isAudio => this == DownloadKind.audio;

  /// Prose or narration — either way, not a page loop.
  bool get isNovelSide => this == DownloadKind.novel || this == DownloadKind.audio;
}

class SavedChapter {
  const SavedChapter({
    required this.rowId,
    required this.scopeId,
    required this.sourceId,
    required this.seriesKey,
    required this.chapterKey,
    required this.chapterNumber,
    required this.title,
    required this.seriesTitle,
    required this.pageCount,
    required this.bytes,
    required this.state,
    required this.pinned,
    required this.readAt,
    required this.createdAt,
    required this.retryCount,
    required this.error,
    this.kind = DownloadKind.manga,
  });

  final int rowId;
  final String scopeId;
  final String sourceId;
  final String seriesKey;
  final String chapterKey;
  final double? chapterNumber;
  final String? title;
  final String? seriesTitle;
  final int pageCount;
  final int bytes;
  final DownloadChapterState state;
  final bool pinned;

  /// Stamped when the chapter is finished reading; cleared on re-open. Drives
  /// the read-then-expire sweep. `null` means "never finished" — the sweep
  /// and pressure eviction must never touch such a row.
  final DateTime? readAt;
  final DateTime createdAt;

  /// Consecutive manifest/page failures for this chapter. Reset to 0 on a
  /// manual retry or a successful page fetch.
  final int retryCount;

  /// Last failure message, surfaced by the Downloads screen. Only meaningful
  /// when [state] is [DownloadChapterState.failed].
  final String? error;

  /// What this row's blobs hold — page images, or one blob of paragraph JSON.
  ///
  /// Stored on the row rather than looked up through the sources listing,
  /// because the whole point of a download is that it reads with no network:
  /// on a plane there is no listing to ask, and a chapter that could not say
  /// which reader to open in would be a chapter that could not be opened.
  final DownloadKind kind;

  ChapterIdentity get identity =>
      (sourceId: sourceId, seriesKey: seriesKey, chapterKey: chapterKey);

  factory SavedChapter.fromRow(Map<String, Object?> row) => SavedChapter(
        rowId: row['id']! as int,
        scopeId: row['scope_id']! as String,
        sourceId: row['source_id']! as String,
        seriesKey: row['series_key']! as String,
        chapterKey: row['chapter_key']! as String,
        chapterNumber: (row['chapter_number'] as num?)?.toDouble(),
        title: row['title'] as String?,
        seriesTitle: row['series_title'] as String?,
        pageCount: row['page_count']! as int,
        bytes: row['bytes']! as int,
        state: DownloadChapterState.fromWire(row['state']! as String),
        pinned: (row['pinned']! as int) != 0,
        readAt: (row['read_at'] as String?) != null
            ? DateTime.parse(row['read_at']! as String)
            : null,
        createdAt: DateTime.parse(row['created_at']! as String),
        retryCount: row['retry_count']! as int,
        error: row['error'] as String?,
        // Absent only when read back from a row written before the v2
        // migration ran, which is a manga chapter by definition.
        kind: DownloadKind.fromWire(row[DownloadsSchema.colKind] as String?),
      );
}
