/// Models for the federated `/sources/search` endpoint, which merges results
/// from the local library and every enabled remote source into a single feed.
///
/// `series_id` is always a STRING here (local ids are numeric strings, source
/// ids are opaque source-defined strings). `cover_url` is the backend's
/// relative `/sources/.../cover` proxy path; the cards resolve it against the
/// API base with `searchResultCoverUrl` rather than reconstructing it.
class GlobalSearchItem {
  const GlobalSearchItem({
    required this.kind,
    required this.seriesId,
    required this.title,
    this.source,
    this.coverUrl,
    this.author,
    this.extra,
  });

  /// `"local"` for a library series, `"source"` for a remote source series.
  final String kind;

  /// Source id (e.g. `mangadex`) for `kind == "source"`; null for local items.
  final String? source;

  /// Opaque string id — numeric for local series, source-defined otherwise.
  final String seriesId;
  final String title;

  /// Cover URL as served — relative from the backend, absolute when a retry
  /// rebuilt the row. Paint it through `searchResultCoverUrl`.
  final String? coverUrl;
  final String? author;
  final Map<String, dynamic>? extra;

  bool get isLocal => kind == 'local';
  bool get isSource => kind == 'source';

  factory GlobalSearchItem.fromJson(Map<String, dynamic> json) {
    final cover = json['cover_url'] as String?;
    return GlobalSearchItem(
      kind: json['kind'] as String? ?? 'source',
      source: json['source'] as String?,
      seriesId: '${json['series_id']}',
      title: json['title'] as String? ?? '',
      coverUrl: (cover != null && cover.isNotEmpty) ? cover : null,
      author: json['author'] as String?,
      extra: json['extra'] as Map<String, dynamic>?,
    );
  }
}

class GlobalSearchResult {
  const GlobalSearchResult({
    this.items = const [],
    this.sourcesQueried = 0,
    this.sourcesFailed = 0,
    this.page = 1,
    this.hasMore = false,
    this.isLoadingMore = false,
  });

  final List<GlobalSearchItem> items;
  final int sourcesQueried;
  final int sourcesFailed;
  final int page;
  final bool hasMore;

  /// UI-only flag toggled while a `loadMore` page request is in flight.
  final bool isLoadingMore;

  bool get isEmpty => items.isEmpty;

  GlobalSearchResult copyWith({
    List<GlobalSearchItem>? items,
    int? sourcesQueried,
    int? sourcesFailed,
    int? page,
    bool? hasMore,
    bool? isLoadingMore,
  }) {
    return GlobalSearchResult(
      items: items ?? this.items,
      sourcesQueried: sourcesQueried ?? this.sourcesQueried,
      sourcesFailed: sourcesFailed ?? this.sourcesFailed,
      page: page ?? this.page,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    );
  }

  factory GlobalSearchResult.fromJson(Map<String, dynamic> json) {
    return GlobalSearchResult(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => GlobalSearchItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      sourcesQueried: (json['sources_queried'] as num?)?.toInt() ?? 0,
      sourcesFailed: (json['sources_failed'] as num?)?.toInt() ?? 0,
      page: (json['page'] as num?)?.toInt() ?? 1,
      hasMore: json['has_more'] as bool? ?? false,
    );
  }
}
