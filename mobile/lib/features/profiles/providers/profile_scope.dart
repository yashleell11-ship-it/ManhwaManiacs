import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/features/collections/providers/collection_detail_provider.dart';
import 'package:manhwamaniacs/features/collections/providers/collections_provider.dart';
import 'package:manhwamaniacs/features/library/providers/bookmarks_provider.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/library/providers/intelligence_providers.dart';
import 'package:manhwamaniacs/features/library/providers/library_list_provider.dart';
import 'package:manhwamaniacs/features/library/providers/series_detail_provider.dart';
import 'package:manhwamaniacs/features/profiles/providers/profiles_providers.dart';
import 'package:manhwamaniacs/features/settings/providers/settings_provider.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';

/// Every provider whose data is scoped to the active reading profile.
///
/// When the active profile changes (via the picker ceremony or the app-bar
/// switcher chip) these must be dropped so profile B never renders profile A's
/// follows, progress, bookmarks, library, collections, history or the mature
/// preference. Most are `autoDispose`, so invalidating them while unwatched is a
/// harmless no-op; the next screen that reads one refetches with the new
/// `X-Profile-Id` header.
///
/// Kept as a top-level list (mirroring `metadataCacheInvalidators`) so the exact
/// set is auditable and testable without triggering a real profile switch.
final List<void Function(Ref ref)> profileScopedInvalidators = [
  // Follows + update notifications.
  (ref) => ref.invalidate(updatesProvider),
  // Continue-reading / dashboard rails.
  (ref) => ref.invalidate(continueReadingProvider),
  // Library lists + search results.
  (ref) => ref.invalidate(libraryListProvider),
  (ref) => ref.invalidate(searchListProvider),
  // Reading intelligence surfaces.
  (ref) => ref.invalidate(statisticsProvider),
  (ref) => ref.invalidate(recommendationsProvider),
  (ref) => ref.invalidate(readingHistoryProvider),
  // Bookmarks.
  (ref) => ref.invalidate(bookmarksProvider),
  // Per-series detail (progress/bookmark state, and the `is_followed` /
  // `follow_tracker_id` the local series page seeds its Follow button from —
  // follows are per (user, profile), so profile A's must never seed B's
  // button) — family, all instances.
  (ref) => ref.invalidate(seriesDetailProvider),
  // Collections list + open collection detail.
  (ref) => ref.invalidate(collectionsProvider),
  (ref) => ref.invalidate(collectionDetailProvider),
  // Per-profile mature-content preference.
  (ref) => ref.invalidate(matureContentProvider),
  // NOTE: the Downloads queue is intentionally NOT here. Downloads are an
  // account-level (per-user) queue on the backend — the Download model is keyed
  // by user_id only, has no profile_id column, and the profile-scoping migration
  // deliberately omits it. Switching profiles must not drop the downloads cache,
  // so do not add ref.invalidate(downloadsProvider) to this list.
];

/// Drop every profile-scoped cache. Called when the active profile changes.
void invalidateProfileScopedProviders(Ref ref) {
  for (final invalidate in profileScopedInvalidators) {
    invalidate(ref);
  }
}

/// True when [error] is the backend's per-profile guard rejecting a mutation
/// because no (or a foreign) profile was in scope: 400 `profile_required` or
/// 404 `profile_not_found`.
bool isProfileScopeError(AppError error) =>
    error is ApiError &&
    (error.code == 'profile_required' || error.code == 'profile_not_found');

/// If [error] is a per-profile guard rejection, drop the stale selection and
/// close the session gate so the router redirects back to the profile picker
/// (mirroring the 401 session-expiry recovery). Returns whether it handled the
/// error, so callers can skip a generic snackbar when the picker is taking over.
bool recoverFromProfileScopeError(WidgetRef ref, AppError error) {
  if (!isProfileScopeError(error)) return false;
  ref.read(activeProfileProvider.notifier).clear();
  ref.read(profileSessionReadyProvider.notifier).reset();
  // Force a fresh profile list so a rejected/foreign profile can't keep the
  // picker rendering the stale (kept-alive) list and loop on the same error.
  ref.invalidate(profilesProvider);
  return true;
}
