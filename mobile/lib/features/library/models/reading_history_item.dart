import 'package:manhwamaniacs/core/time/server_instant.dart';

/// `GET /reader/history` row — a stored reading-position row
/// (`progress_service.py`'s `_serialize`, same shape as `ReadingProgress`)
/// plus the book it belongs to.
///
/// [seriesTitle] can be null: `source_series_cache` is a TTL cache, so a book
/// read months ago may have aged out. The row still opens — it just cannot
/// say which book it is, and the screen has to handle that rather than
/// rendering a blank line.
class ReadingHistoryItem {
  const ReadingHistoryItem({
    required this.id,
    required this.sourceId,
    required this.seriesKey,
    required this.chapterKey,
    this.chapterNumber,
    required this.lastPage,
    required this.pageCount,
    required this.isCompleted,
    this.lastReadAt,
    this.seriesTitle,
    this.coverUrl,
  });

  final int id;
  final String sourceId;
  final String seriesKey;
  final String chapterKey;
  final double? chapterNumber;
  final int lastPage;
  final int pageCount;
  final bool isCompleted;
  final DateTime? lastReadAt;

  /// The book. Null when it has aged out of the server's series cache.
  final String? seriesTitle;
  final String? coverUrl;

  factory ReadingHistoryItem.fromJson(Map<String, dynamic> json) => ReadingHistoryItem(
        id: json['id'] as int,
        sourceId: json['source_id'] as String,
        seriesKey: json['series_key'] as String,
        chapterKey: json['chapter_key'] as String,
        chapterNumber: (json['chapter_number'] as num?)?.toDouble(),
        lastPage: (json['last_page'] as num?)?.toInt() ?? 1,
        pageCount: (json['page_count'] as num?)?.toInt() ?? 0,
        isCompleted: json['is_completed'] as bool? ?? false,
        lastReadAt: serverInstant(json['last_read_at']),
        seriesTitle: (json['series_title'] as String?)?.trim().isEmpty ?? true
            ? null
            : (json['series_title'] as String).trim(),
        coverUrl: json['cover_url'] as String?,
      );
}
