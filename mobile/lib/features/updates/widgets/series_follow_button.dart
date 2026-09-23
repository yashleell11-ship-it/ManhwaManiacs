import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/features/profiles/providers/profile_scope.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';

/// Follow / Unfollow control for a series, identified by the opaque
/// `(sourceId, seriesKey)` pair `POST /library/follow` is keyed by.
///
/// Shared by the source-browse series page and the library (followed) series
/// page so the two read as one feature: same control, same labels, same place.
/// Following is what schedules update checks and new-chapter notifications.
///
/// Follow state comes from [updatesProvider] (the shared followed-series
/// cache) via [UpdatesNotifier.followedFor] -- the single lookup
/// implementation, not duplicated here -- and the mutations go through the
/// same notifier, so a follow made on either page lands in the one cache that
/// the Updates tab and the Library (followed) shelf both watch. That is why
/// no extra invalidation is needed here: `followSeries`/`unfollow` already
/// refresh it.
///
/// This widget is the only part of either screen that watches [updatesProvider],
/// so notification/followed-list changes elsewhere never rebuild the rest of
/// the page.
///
/// The button is disabled while a follow or unfollow is in flight
/// (`actionPending`, which doubles as the double-tap guard) and while the
/// followed-series cache has not loaded yet.
class SeriesFollowButton extends ConsumerWidget {
  const SeriesFollowButton({
    super.key,
    required this.sourceId,
    required this.seriesKey,
    this.seriesIdentity,
    this.initialIsFollowed,
    this.initialFollowedId,
  });

  /// Connector id the series belongs to.
  final String sourceId;

  /// The connector's own id for the series.
  final String seriesKey;

  /// The page payload's `series_identity`, when it has one. Finds a follow
  /// made under an older key of the same series (Asura rotates its slugs);
  /// see [UpdatesNotifier.followedFor].
  final String? seriesIdentity;

  /// Follow state already known from the page's own payload, used only until
  /// the followed-series cache resolves. `GET /library/series/{id}` is
  /// reached only once already following, so the library series page can
  /// seed a truthful "Unfollow" on the very first frame instead of flashing
  /// "Follow" at a series the user already follows.
  ///
  /// Null means "the caller has no payload to seed from" — the source-browse
  /// page, which learns follow state only from the followed-series cache.
  /// That is a third state, not the same as `false`: `false` is an answer,
  /// null is the absence of one, and only the latter warrants a placeholder
  /// label.
  final bool? initialIsFollowed;

  /// Followed-row id matching [initialIsFollowed]; non-null iff that is true.
  final int? initialFollowedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updatesAsync = ref.watch(updatesProvider);
    final state = updatesAsync.valueOrNull;
    final loading = updatesAsync.isLoading;
    final actionPending = state?.actionPending ?? false;

    // Once the followed-series list has loaded it is authoritative -- it
    // reflects follows/unfollows made on other screens since this page was
    // built, which the payload seed cannot. Before then fall back to the
    // seed, which may itself be null when the caller had nothing to seed from.
    final series = state == null
        ? null
        : ref
            .read(updatesProvider.notifier)
            .followedFor(
              sourceId: sourceId,
              seriesKey: seriesKey,
              seriesIdentity: seriesIdentity,
            );
    final bool? followed = state == null ? initialIsFollowed : series != null;
    final followedId = state == null ? initialFollowedId : series?.id;
    final isFollowed = followed ?? false;

    // Disabled while an action is in flight -- which is also the double-tap
    // guard -- and until the followed-series cache lands, so a tap can never
    // act on a seeded id the server may have changed since the page loaded.
    final disabled = actionPending || (loading && state == null);

    final String label;
    if (actionPending) {
      label = isFollowed ? 'Unfollowing…' : 'Following…';
    } else if (followed == null && disabled) {
      // Neither cache nor seed: we genuinely do not know yet, so show the
      // placeholder rather than assert "Follow" at a series the user may
      // already follow. With a seed we do know, and say so plainly.
      label = 'Following…';
    } else {
      label = isFollowed ? 'Unfollow' : 'Follow';
    }

    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: disabled
            ? null
            : () => _toggle(context, ref, isFollowed, followedId),
        icon: isFollowed
            ? const Icon(Icons.notifications_off_outlined)
            : const Icon(Icons.notifications_active_outlined),
        label: Text(label),
      ),
    );
  }

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    bool isFollowed,
    int? followedId,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(updatesProvider.notifier);
    final AppError? error;
    if (isFollowed && followedId != null) {
      error = await notifier.unfollow(followedId);
    } else {
      error = await notifier.followSeries(sourceId: sourceId, seriesKey: seriesKey);
    }
    if (error == null) {
      // The followed-series cache was refreshed by the action, so the button
      // label already reflects the new followed state; confirm it to the user.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            isFollowed
                ? 'Unfollowed'
                : 'Following — you\'ll be notified of new chapters',
          ),
        ),
      );
      return;
    }
    // A per-profile guard rejection hands off to the picker instead of a raw
    // error; anything else surfaces inline.
    if (recoverFromProfileScopeError(ref, error)) return;
    messenger.showSnackBar(
      SnackBar(content: Text(error.userMessage)),
    );
  }
}
