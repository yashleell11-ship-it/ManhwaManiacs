import 'package:manhwamaniacs/core/time/server_instant.dart';
import 'package:manhwamaniacs/features/library/models/known_chapter.dart';
import 'package:manhwamaniacs/features/library/models/read_state.dart';

/// A followed series — `backend/services/followed_series_service.py`'s
/// `FollowedSeriesService.serialize`. A series is in the library iff a
/// `followed_series` row exists for `(user_id, profile_id, source_id,
/// series_key)`; [id] is that row's PK (`followed_id`) — a handle for
/// `PATCH`/`DELETE /library/...` and the series-detail route, never domain
/// identity. Domain identity is [sourceId] + [seriesKey].
class FollowedSeries {
  const FollowedSeries({
    required this.id,
    required this.sourceId,
    required this.seriesKey,
    this.seriesIdentity,
    required this.title,
    required this.coverUrl,
    required this.isFavorite,
    required this.readingStatus,
    required this.notify,
    required this.sortOrder,
    required this.contentRating,
    required this.rating,
    this.matureOverride,
    this.knownChapters = const [],
    required this.chapterCount,
    this.lastCheckedAt,
    this.createdAt,
    this.updatedAt,
    this.readState,
  });

  final int id;
  final String sourceId;
  final String seriesKey;

  /// The connector's name for the series [seriesKey] names — equal to it
  /// except on a source whose keys drift (Asura rotates its slug suffixes).
  /// Compared against a series page's own `series_identity` to find a follow
  /// made under an older key; never fetched with. Null from a server or a
  /// library cache older than the field, which [identity] reads as the key.
  final String? seriesIdentity;

  /// [seriesIdentity], or the key itself where none was sent.
  String get identity => seriesIdentity ?? seriesKey;

  final String title;

  /// Ready-to-use cover URL — either the source's own absolute URL or a
  /// backend-relative proxy path; resolve the relative form with
  /// [resolveApiResourceUrl] before rendering.
  final String coverUrl;
  final bool isFavorite;
  final String readingStatus;
  final bool notify;
  final int sortOrder;
  final String contentRating;

  /// Effective rating after gate/override resolution ("mature" | "safe" | …).
  final String rating;
  final bool? matureOverride;
  final List<KnownChapter> knownChapters;
  final int chapterCount;
  final DateTime? lastCheckedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Where this profile stands in the series. Sent by the list, `follow` and
  /// `patch`; null on the detail payload (which has its own progress overlay)
  /// and in a library cache written by an older build.
  final ReadState? readState;

  FollowedSeries copyWith({bool? isFavorite, String? readingStatus, bool? notify}) {
    return FollowedSeries(
      id: id,
      sourceId: sourceId,
      seriesKey: seriesKey,
      seriesIdentity: seriesIdentity,
      title: title,
      coverUrl: coverUrl,
      isFavorite: isFavorite ?? this.isFavorite,
      readingStatus: readingStatus ?? this.readingStatus,
      notify: notify ?? this.notify,
      sortOrder: sortOrder,
      contentRating: contentRating,
      rating: rating,
      matureOverride: matureOverride,
      knownChapters: knownChapters,
      chapterCount: chapterCount,
      lastCheckedAt: lastCheckedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      readState: readState,
    );
  }

  factory FollowedSeries.fromJson(Map<String, dynamic> json) => FollowedSeries(
        id: json['id'] as int,
        sourceId: json['source_id'] as String,
        seriesKey: json['series_key'] as String,
        seriesIdentity: json['series_identity'] as String?,
        title: json['title'] as String,
        coverUrl: json['cover_url'] as String? ?? '',
        isFavorite: json['is_favorite'] as bool? ?? false,
        readingStatus: json['reading_status'] as String? ?? 'unread',
        notify: json['notify'] as bool? ?? false,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        contentRating: json['content_rating'] as String? ?? 'safe',
        rating: json['rating'] as String? ?? 'safe',
        matureOverride: json['mature_override'] as bool?,
        knownChapters: (json['known_chapters'] as List<dynamic>? ?? const [])
            .map((e) => KnownChapter.fromJson(e as Map<String, dynamic>))
            .toList(),
        chapterCount: (json['chapter_count'] as num?)?.toInt() ?? 0,
        lastCheckedAt: serverInstant(json['last_checked_at']),
        createdAt: serverInstant(json['created_at']),
        updatedAt: serverInstant(json['updated_at']),
        readState: json['read_state'] is Map<String, dynamic>
            ? ReadState.fromJson(json['read_state'] as Map<String, dynamic>)
            : null,
      );

  /// Round-trips through [FollowedSeries.fromJson]. Written to the offline
  /// library cache (`utils/followed_series_cache.dart`) on every successful
  /// list fetch, so a launch with the server unreachable still knows which
  /// series this profile follows — and, crucially, which `(sourceId,
  /// seriesKey)` each [id] stands for, the one mapping the on-device chapter
  /// store cannot supply on its own.
  Map<String, dynamic> toJson() => {
        'id': id,
        'source_id': sourceId,
        'series_key': seriesKey,
        'series_identity': seriesIdentity,
        'title': title,
        'cover_url': coverUrl,
        'is_favorite': isFavorite,
        'reading_status': readingStatus,
        'notify': notify,
        'sort_order': sortOrder,
        'content_rating': contentRating,
        'rating': rating,
        'mature_override': matureOverride,
        'known_chapters': [for (final c in knownChapters) c.toJson()],
        'chapter_count': chapterCount,
        'last_checked_at': lastCheckedAt?.toIso8601String(),
        'created_at': createdAt?.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
        'read_state': readState?.toJson(),
      };
}

/// Per-chapter reading position overlaid on the [SeriesDetail] payload.
class ChapterProgressEntry {
  const ChapterProgressEntry({required this.lastPage, required this.isCompleted});

  final int lastPage;
  final bool isCompleted;

  factory ChapterProgressEntry.fromJson(Map<String, dynamic> json) =>
      ChapterProgressEntry(
        lastPage: (json['last_page'] as num?)?.toInt() ?? 1,
        isCompleted: json['is_completed'] as bool? ?? false,
      );
}
