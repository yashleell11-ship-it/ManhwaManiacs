import 'package:manhwamaniacs/core/time/server_instant.dart';

/// `GET /library/continue-reading` item — progress-service shape.
///
/// [title] and [coverUrl] come from the follow row the server joined the
/// progress to. A server older than those fields sends neither, so both are
/// optional: callers then resolve the series by matching `(sourceId,
/// seriesKey)` — or, on Asura, its identity — against the followed-series
/// list they already hold, or render the chapter alone.
class ContinueReadingItem {
  const ContinueReadingItem({
    required this.sourceId,
    required this.seriesKey,
    required this.chapterKey,
    this.chapterNumber,
    required this.lastPage,
    required this.pageCount,
    this.lastReadAt,
    this.title,
    this.coverUrl,
  });

  final String sourceId;
  final String seriesKey;
  final String chapterKey;
  final double? chapterNumber;
  final int lastPage;
  final int pageCount;
  final DateTime? lastReadAt;

  /// The series' title, or null from a server that does not send one.
  final String? title;

  /// The series' cover — the source's absolute URL or the backend's relative
  /// `/sources/.../cover` proxy path, as a followed row carries it — or null.
  final String? coverUrl;

  double get progressPct => pageCount > 0 ? lastPage / pageCount : 0;

  factory ContinueReadingItem.fromJson(Map<String, dynamic> json) =>
      ContinueReadingItem(
        sourceId: json['source_id'] as String,
        seriesKey: json['series_key'] as String,
        chapterKey: json['chapter_key'] as String,
        chapterNumber: (json['chapter_number'] as num?)?.toDouble(),
        lastPage: (json['last_page'] as num?)?.toInt() ?? 1,
        pageCount: (json['page_count'] as num?)?.toInt() ?? 0,
        lastReadAt: serverInstant(json['last_read_at']),
        title: _text(json['title']),
        coverUrl: _text(json['cover_url']),
      );
}

/// A present, non-blank string, else null — an empty title is no title.
String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
