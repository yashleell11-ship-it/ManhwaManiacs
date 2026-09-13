import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/library/providers/library_list_provider.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

/// Where a row sat in each shelf that was on screen when it was taken out, so
/// an undo can put it back where it was instead of dropping it at the bottom
/// of both. `-1` for a shelf that was not loaded and therefore has no slot to
/// preserve.
typedef ShelfSlots = ({int list, int followed});

const ShelfSlots _noSlots = (list: -1, followed: -1);

/// Everything the per-series menu does to one followed row: star it, take it
/// out of the library, and put it back.
///
/// Deliberately not methods on [libraryListProvider]. Two screens show the
/// followed rows — the Library tab, which renders [updatesProvider]'s shared
/// followed cache, and the browse screen under it, which renders the paged
/// [libraryListProvider] — and each keeps only its own list alive. Hanging the
/// removal off either one would mean the other screen spinning up an
/// autoDispose list it does not render, for a single delete, only to have it
/// collected halfway through the request. Sitting outside both, this splices
/// whichever shelves are actually on screen and leaves the rest to load fresh
/// the next time they are built.
final librarySeriesActionsProvider = Provider<LibrarySeriesActions>(
  LibrarySeriesActions.new,
  name: 'librarySeriesActions',
);

class LibrarySeriesActions {
  LibrarySeriesActions(this._ref);

  final Ref _ref;

  /// Stars or unstars [series]. Returns the error to surface, or null.
  Future<AppError?> setFavorite(
    FollowedSeries series, {
    required bool favorite,
  }) async {
    final result = await _ref
        .read(libraryRepositoryProvider)
        .patchSeries(series.id, isFavorite: favorite);
    if (result.isErr) return result.error;
    _remember(result.value, _noSlots);
    return null;
  }

  /// Removes a series from the library: deletes the `followed_series` row the
  /// shelf is made of. Reading progress is keyed by `(source, series)` rather
  /// than by that row and outlives it (see `FollowedSeriesService.unfollow`),
  /// so the whole cost of a mistaken removal is one re-follow — which is why
  /// the caller offers an undo instead of a confirmation step.
  ///
  /// The card leaves the shelf before the request resolves, so the library
  /// answers the tap at once, and slots back into the place it held if the
  /// server refuses.
  ///
  /// Returns those slots, so an undo can hand them straight back to [restore].
  Future<({AppError? error, ShelfSlots slots})> remove(
    FollowedSeries series,
  ) async {
    final slots = _forget(series.id);
    final result =
        await _ref.read(libraryRepositoryProvider).unfollow(series.id);
    if (result.isErr) {
      _remember(series, slots);
      return (error: result.error, slots: _noSlots);
    }
    _ref.invalidate(continueReadingProvider);
    return (error: null, slots: slots);
  }

  /// Undo of [remove]: re-follow, and put the row back in the slots it was
  /// pulled from rather than refetching — a refetch would blank the whole
  /// shelf to a skeleton to undo one card.
  ///
  /// Following hands back a *new* `followed_series` row, so the shelf metadata
  /// the deleted one carried (favorite, reading status, notify, mature
  /// override) is patched onto it. Without that the undo would quietly return
  /// the series unstarred and back at the default reading status.
  Future<AppError?> restore(
    FollowedSeries series, {
    required ShelfSlots slots,
  }) async {
    final repo = _ref.read(libraryRepositoryProvider);
    final followed = await repo.follow(
      sourceId: series.sourceId,
      seriesKey: series.seriesKey,
    );
    if (followed.isErr) return followed.error;

    var restored = followed.value;
    if (restored.isFavorite != series.isFavorite ||
        restored.readingStatus != series.readingStatus ||
        restored.notify != series.notify ||
        restored.matureOverride != series.matureOverride) {
      final patched = await repo.patchSeries(
        restored.id,
        isFavorite: series.isFavorite,
        readingStatus: series.readingStatus,
        notify: series.notify,
        matureOverride: series.matureOverride,
      );
      // A failed patch still leaves the series back in the library, which is
      // what the undo was for; only the metadata is off, and a refresh will
      // show whatever the server actually kept.
      if (patched.isOk) restored = patched.value;
    }

    _remember(restored, slots);
    _ref.invalidate(continueReadingProvider);
    return null;
  }

  /// Takes [followedId] out of every shelf cache that is currently alive.
  ///
  /// [Ref.exists] rather than a plain read: reading an autoDispose list that
  /// no screen is watching would build it — a wasted fetch whose result
  /// nobody renders, on a provider that would then be collected before this
  /// request even lands.
  ShelfSlots _forget(int followedId) {
    return (
      list: _ref.exists(libraryListProvider)
          ? _ref.read(libraryListProvider.notifier).forgetSeries(followedId)
          : -1,
      followed: _ref.exists(updatesProvider)
          ? _ref.read(updatesProvider.notifier).forgetFollowed(followedId)
          : -1,
    );
  }

  void _remember(FollowedSeries series, ShelfSlots slots) {
    if (_ref.exists(libraryListProvider)) {
      _ref
          .read(libraryListProvider.notifier)
          .rememberSeries(series, index: slots.list);
    }
    if (_ref.exists(updatesProvider)) {
      _ref
          .read(updatesProvider.notifier)
          .rememberFollowed(series, index: slots.followed);
    }
  }
}
