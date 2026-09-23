import 'package:manhwamaniacs/core/network/api_image.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';

/// Resolves a followed series' cover URL to an absolute one. The backend
/// returns either the source's own absolute URL or a backend-relative
/// `/sources/{source}/series/{series}/cover` proxy path.
String? followedSeriesCoverUrl(String apiBaseUrl, FollowedSeries series) {
  if (series.coverUrl.isEmpty) return null;
  return resolveApiResourceUrl(apiBaseUrl, series.coverUrl);
}

/// Resolves a reading-history row's `cover_url` to an absolute one, or null
/// when the row has none.
///
/// `GET /reader/history` copies the cover straight out of
/// `source_series_cache`, and in production that column holds the backend's
/// RELATIVE `/sources/{source}/series/{series}/cover` proxy path. Handed to
/// the image loader as-is it has no host, so every history cover showed the
/// broken-image placeholder. Resolved here, before `SeriesCoverImage` adds
/// its `?w=` — that only matches a URL ending in `/cover`, which still holds.
String? historyCoverUrl(String apiBaseUrl, String? coverUrl) {
  if (coverUrl == null || coverUrl.trim().isEmpty) return null;
  return resolveApiResourceUrl(apiBaseUrl, coverUrl.trim());
}

/// Resolves a federated search hit's or AI suggestion's `cover_url` to an
/// absolute one, or null when it has none.
///
/// `/sources/search` and `/library/suggest` serve the backend's RELATIVE
/// `/sources/{source}/series/{series}/cover` proxy path. The backend used to
/// build an absolute URL from the host it was reached on, which behind Caddy
/// is plain http — so every cover sent the bearer token in clear text before
/// the redirect to https. Resolved against the app's own (https) API base
/// instead. An absolute URL passes through, which keeps this safe for rows the
/// retry path already resolved.
String? searchResultCoverUrl(String apiBaseUrl, String? coverUrl) {
  if (coverUrl == null || coverUrl.trim().isEmpty) return null;
  return resolveApiResourceUrl(apiBaseUrl, coverUrl.trim());
}

/// Builds the absolute cover image URL for an online source series, matching
/// the backend route `/sources/{source_id}/series/{series_id:path}/cover`.
String sourceSeriesCoverUrl(String apiBaseUrl, String source, String seriesId) {
  final base = apiBaseUrl.endsWith('/') ? apiBaseUrl : '$apiBaseUrl/';
  return '${base}sources/$source/series/${Uri.encodeComponent(seriesId)}/cover';
}

/// Shared Hero tag for a library series' cover (keyed by the follow row's
/// `followed_id`), so the library grid/list and the series detail screen
/// animate as one continuous shared element rather than a hard cut. Both ends
/// must use this exact same helper.
String seriesCoverHeroTag(int followedId) => 'series-cover-$followedId';

/// Resolves a collection cover URL when the backend stores an absolute URL.
String? collectionCoverUrl(String? coverUrl) {
  if (coverUrl == null || coverUrl.isEmpty) return null;
  if (coverUrl.startsWith('http://') || coverUrl.startsWith('https://')) {
    return coverUrl;
  }
  return null;
}
