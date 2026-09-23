import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';

/// The server's `per_page` ceiling on `GET /library/series`.
const followedPageSize = 200;

/// Pages past this are not asked for: the 1000-follow cap
/// (`max_follows_per_profile`) is five pages, and a server that kept
/// answering `has_next` would otherwise be asked forever.
const followedMaxPages = 10;

/// Every series the active profile follows, page after page until the server
/// says there is no next one.
///
/// A profile may follow 1000 series and the list serves 200 a page. The
/// follow-state cache and the collection picker read page 1 alone, so past
/// 200 follows a series that sorts late looked unfollowed on its own page and
/// could never be added to a collection.
///
/// A page that fails fails the whole read rather than returning the pages
/// before it: a partial list is the wrong answer this exists to stop, since a
/// missing row reads as "not followed". A row served twice — a follow made
/// between two page reads shifts the rest down a place — is kept once.
Future<Result<List<FollowedSeries>>> listAllFollowed(
  LibraryRepository repo,
) async {
  final rows = <FollowedSeries>[];
  final seen = <(String, String)>{};
  for (var page = 1; page <= followedMaxPages; page++) {
    final result = await repo.listSeries(page: page, perPage: followedPageSize);
    if (result.isErr) return Err(result.error);
    final items = result.value.items;
    for (final series in items) {
      if (seen.add((series.sourceId, series.seriesKey))) rows.add(series);
    }
    if (!result.value.hasNext || items.isEmpty) break;
  }
  return Ok(rows);
}
