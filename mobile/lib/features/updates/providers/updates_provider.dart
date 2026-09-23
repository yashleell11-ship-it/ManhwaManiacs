import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/utils/all_followed.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

class UpdatesState {
  const UpdatesState({
    required this.notifications,
    required this.unreadCount,
    required this.followed,
    this.actionPending = false,
    this.checking = false,
  });

  final List<UpdateNotification> notifications;
  final int unreadCount;

  /// Every series the active profile follows — the shared cache the Updates
  /// tab, the Library dashboard's "followed" shelf, and every
  /// `SeriesFollowButton` all watch.
  final List<FollowedSeries> followed;
  final bool actionPending;

  /// A "Check now" is in flight: sent, and — when the server queued it on its
  /// worker — still being waited out. The button says so instead of looking
  /// like a check that finished and found nothing.
  final bool checking;

  UpdatesState copyWith({
    List<UpdateNotification>? notifications,
    int? unreadCount,
    List<FollowedSeries>? followed,
    bool? actionPending,
    bool? checking,
  }) =>
      UpdatesState(
        notifications: notifications ?? this.notifications,
        unreadCount: unreadCount ?? this.unreadCount,
        followed: followed ?? this.followed,
        actionPending: actionPending ?? this.actionPending,
        checking: checking ?? this.checking,
      );
}

final updatesProvider =
    AsyncNotifierProvider.autoDispose<UpdatesNotifier, UpdatesState>(
  UpdatesNotifier.new,
  name: 'updates',
);

/// When to look again after a "Check now" the server queued, as waits between
/// looks: at about 3, 8 and 15 seconds. A queued check runs on the server's
/// worker after the request has already answered (a pass took ~6 s in the run
/// log), so re-reading the list straight away shows the old one. Stops early
/// once the unread count moves. An override point for tests.
final updateCheckPollDelaysProvider = Provider<List<Duration>>(
  (ref) => const [
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 7),
  ],
  name: 'updateCheckPollDelays',
);

class UpdatesNotifier extends AutoDisposeAsyncNotifier<UpdatesState> {
  /// Riverpod 2.6 has no `ref.mounted`, and a queued check's follow-up looks
  /// can outlive the screen. Re-armed on every build, since a rebuild runs the
  /// dispose callbacks on this same instance.
  bool _alive = false;

  @override
  Future<UpdatesState> build() async {
    _alive = true;
    ref.onDispose(() => _alive = false);
    return _fetch();
  }

  Future<void> refresh() async {
    // Keep the current data visible while re-fetching so action-driven reloads
    // (mark read, check now, unfollow) and pull-to-refresh don't blank the
    // whole screen to a skeleton. The RefreshIndicator spinner and optimistic
    // actionPending state provide the loading affordance; first load is
    // covered by build().
    state = await AsyncValue.guard(_fetch);
  }

  /// Re-reads only the followed list, in place, for a reader that has just
  /// closed (see `libraryReadStateProvider`).
  ///
  /// How far the profile has read travels on the followed rows (`read_state`),
  /// and reading moves nothing else this cache holds — so one request instead
  /// of [refresh]'s three. And quiet on failure: the shelf keeps what it shows
  /// rather than turning into an error screen, because coming back from
  /// reading downloaded chapters with no signal is an ordinary case, not a
  /// fault to report.
  Future<void> refreshFollowed() async {
    final result = await listAllFollowed(ref.read(libraryRepositoryProvider));
    if (result.isErr) return;
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(followed: result.value));
  }

  Future<UpdatesState> _fetch() async {
    final updatesRepo = ref.read(updatesRepositoryProvider);
    final libraryRepo = ref.read(libraryRepositoryProvider);
    final notifications = await updatesRepo.listNotifications();
    final unread = await updatesRepo.getUnreadCount();
    // Every page, not the first 200: this is the follow-state cache, and a
    // follow missing from it reads as "not followed" on its own page.
    final followed = await listAllFollowed(libraryRepo);
    if (notifications.isErr) throw notifications.error;
    if (unread.isErr) throw unread.error;
    if (followed.isErr) throw followed.error;
    return UpdatesState(
      notifications: notifications.value,
      unreadCount: unread.value,
      followed: followed.value,
    );
  }

  Future<AppError?> markRead(int id) async {
    final repo = ref.read(updatesRepositoryProvider);
    final result = await repo.markRead(id);
    if (result.isErr) return result.error;
    await refresh();
    return null;
  }

  /// Marks every unread notification read — only [mode]'s when given, which
  /// is what the screen passes while it lists one content mode (see
  /// `markAllReadMode`). Null clears every mode.
  Future<AppError?> markAllRead({ContentMode? mode}) async {
    final repo = ref.read(updatesRepositoryProvider);
    final result = await repo.markAllRead(contentKind: mode?.wire);
    if (result.isErr) return result.error;
    await refresh();
    return null;
  }

  /// "Check now". When the server runs the check inline the answer already
  /// holds its result; when it queues it on its worker (production, with the
  /// scheduler up) nothing has been fetched yet, so this keeps looking for a
  /// few seconds — see [updateCheckPollDelaysProvider] — before the final
  /// reload, instead of reloading once, too early, and showing no new
  /// chapters for a check that found some.
  Future<AppError?> triggerCheck() async {
    final repo = ref.read(updatesRepositoryProvider);
    _setChecking(true);
    final result = await repo.triggerCheck();
    if (result.isErr) {
      _setChecking(false);
      return result.error;
    }
    if (result.value.queued) {
      await _awaitQueuedCheck(before: state.valueOrNull?.unreadCount);
    }
    if (!_alive) return null;
    // A fresh fetch, so `checking` is back to false with the new list.
    await refresh();
    return null;
  }

  Future<void> _awaitQueuedCheck({required int? before}) async {
    final delays = ref.read(updateCheckPollDelaysProvider);
    final repo = ref.read(updatesRepositoryProvider);
    for (final delay in delays) {
      await Future<void>.delayed(delay);
      if (!_alive) return;
      final count = await repo.getUnreadCount();
      if (count.isOk && count.value != before) return;
    }
  }

  void _setChecking(bool checking) {
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(current.copyWith(checking: checking));
    }
  }

  Future<AppError?> unfollow(int followedId) async {
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(current.copyWith(actionPending: true));
    }
    final repo = ref.read(libraryRepositoryProvider);
    final result = await repo.unfollow(followedId);
    if (result.isErr) {
      if (current != null) {
        state = AsyncData(current.copyWith(actionPending: false));
      }
      return result.error;
    }
    await refresh();
    return null;
  }

  /// Follow a source series for new-chapter notifications. Idempotent on the
  /// server side (returns the existing row when already followed), but we
  /// still refresh so the followed list reflects the change immediately.
  /// Sets `actionPending` optimistically so the Follow button shows a busy
  /// state the instant it is tapped, before the network round-trip completes.
  Future<AppError?> followSeries({
    required String sourceId,
    required String seriesKey,
  }) async {
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(current.copyWith(actionPending: true));
    }
    final repo = ref.read(libraryRepositoryProvider);
    final result = await repo.follow(sourceId: sourceId, seriesKey: seriesKey);
    if (result.isErr) {
      if (current != null) {
        state = AsyncData(current.copyWith(actionPending: false));
      }
      return result.error;
    }
    await refresh();
    return null;
  }

  /// Takes [followedId] out of the shared followed list and reports the slot
  /// it held, or -1 when this cache does not have it.
  ///
  /// Spliced rather than invalidated because the Library tab is drawn from
  /// this cache and rebuilding it costs three requests: blanking the whole
  /// shelf to a skeleton to delete one card is how a working delete reads as a
  /// broken one.
  ///
  /// Its notifications go with it, because they go with it on the server —
  /// `update_notifications.followed_series_id` is `ON DELETE CASCADE`, so
  /// keeping them here would leave the Updates tab listing chapters of a
  /// series nobody follows and the unread badge counting rows that no longer
  /// exist. An undo re-follows into a new row with no notification history,
  /// which is exactly what the server will report.
  ///
  /// State only; the removal itself lives in `librarySeriesActionsProvider`,
  /// which is what drives this.
  int forgetFollowed(int followedId) {
    final current = state.valueOrNull;
    if (current == null) return -1;
    final index =
        current.followed.indexWhere((series) => series.id == followedId);
    if (index < 0) return -1;

    var unread = current.unreadCount;
    final notifications = <UpdateNotification>[];
    for (final notification in current.notifications) {
      if (notification.followedSeriesId != followedId) {
        notifications.add(notification);
      } else if (!notification.isRead) {
        unread--;
      }
    }

    state = AsyncData(
      current.copyWith(
        followed: [...current.followed]..removeAt(index),
        notifications: notifications,
        unreadCount: unread < 0 ? 0 : unread,
      ),
    );
    return index;
  }

  /// Puts [series] into the shared followed list: in place when the row is
  /// already there, otherwise back in the slot an undo pulled it from —
  /// clamped, because a refresh may have reshaped the list while the request
  /// was in flight, and appended when there is no slot to honour.
  void rememberFollowed(FollowedSeries series, {int index = -1}) {
    final current = state.valueOrNull;
    if (current == null) return;
    final at = current.followed.indexWhere((item) => item.id == series.id);
    if (at >= 0) {
      state = AsyncData(
        current.copyWith(followed: [...current.followed]..[at] = series),
      );
      return;
    }
    final slot = index < 0
        ? current.followed.length
        : index.clamp(0, current.followed.length);
    state = AsyncData(
      current.copyWith(
        followed: [...current.followed]..insert(slot, series),
      ),
    );
  }

  /// Returns the followed-series row for the given source+series, or null if
  /// the active profile is not following it. Used by [SeriesFollowButton] to
  /// drive the Follow / Unfollow label and action.
  ///
  /// By the exact key first. Failing that, by [seriesIdentity] — the series
  /// page's own `series_identity` — because Asura rotates the suffix on its
  /// slugs: a series followed under last week's key is served this week under
  /// another, and matched by key alone the page offered "Follow" for a series
  /// already followed (and pressing it handed back the old follow, so nothing
  /// changed). The identity is the connector's answer, compared as given.
  FollowedSeries? followedFor({
    required String sourceId,
    required String seriesKey,
    String? seriesIdentity,
  }) {
    final value = state.valueOrNull;
    if (value == null) return null;
    for (final series in value.followed) {
      if (series.sourceId == sourceId && series.seriesKey == seriesKey) {
        return series;
      }
    }
    if (seriesIdentity == null || seriesIdentity.isEmpty) return null;
    for (final series in value.followed) {
      if (series.sourceId == sourceId && series.identity == seriesIdentity) {
        return series;
      }
    }
    return null;
  }
}
