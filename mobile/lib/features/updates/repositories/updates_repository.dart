import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/models/update_settings.dart';

/// Update-check settings, the notifications a check produces, and the run
/// log (spec §4.5). Following a series lives at `POST /library/follow`
/// ([LibraryRepository.follow]) — there are no trackers here.
abstract interface class UpdatesRepository {
  Future<Result<UpdateSettings>> getSettings();

  Future<Result<UpdateSettings>> updateSettings({
    bool? enabled,
    int? checkIntervalMinutes,
    bool? notifyEnabled,
    bool? checkOnStartup,
  });

  Future<Result<List<UpdateNotification>>> listNotifications({
    bool unreadOnly = false,
    int limit = 100,
  });

  Future<Result<int>> getUnreadCount();

  Future<Result<void>> markRead(int notificationId);

  /// `POST /updates/notifications/read-all`. [contentKind] (`'manga'` /
  /// `'novel'`) clears only that content mode's rows; null clears every mode.
  Future<Result<void>> markAllRead({String? contentKind});

  Future<Result<List<UpdateRun>>> listRuns({int limit = 20});

  /// `POST /updates/check`. When a check is already running the backend
  /// queues this one instead of running it inline — `run` is null and
  /// [UpdateCheckOutcome.queued] is true in that case.
  Future<Result<UpdateCheckOutcome>> triggerCheck({List<int>? followedIds});

  Future<Result<UpdateRun>> checkFollowed(int followedId);
}

class UpdateCheckOutcome {
  const UpdateCheckOutcome({required this.queued, this.run});

  final bool queued;
  final UpdateRun? run;
}
