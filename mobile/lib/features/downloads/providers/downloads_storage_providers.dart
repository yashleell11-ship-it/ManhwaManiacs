import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/downloads/models/series_storage_usage.dart';
import 'package:manhwamaniacs/features/downloads/providers/currently_open_chapter_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/retention_maintenance_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/storage_settings_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';

/// Real, dedup-aware on-device bytes — what the cap in Settings → Storage is
/// enforced against. Device-wide (every profile), not just the active one —
/// see [RetentionMaintenance]'s doc comment. Re-fetches whenever a chapter
/// row's state changes (queued, finished, failed, cancelled) so the storage
/// figures never show a stale total.
final totalDeviceDownloadBytesProvider = FutureProvider.autoDispose<int>((ref) {
  ref.watch(downloadQueueControllerProvider.select((s) => s.queueRevision));
  return ref.watch(retentionMaintenanceProvider).totalDeviceBytes();
});

/// Per-series on-device footprint for the active scope, largest first —
/// the storage card's breakdown. Empty with no active scope.
final seriesStorageBreakdownProvider =
    FutureProvider.autoDispose<List<SeriesStorageUsage>>((ref) async {
  final store = ref.watch(downloadsStoreProvider);
  ref.watch(downloadQueueControllerProvider.select((s) => s.queueRevision));
  if (store == null) return const [];
  return store.seriesBreakdown();
});

class DownloadsStorageActions {
  DownloadsStorageActions(this.ref);

  final Ref ref;

  /// The Storage screen's "Free up space": runs the read-then-expire sweep
  /// immediately (rather than waiting for the next launch/resume), then — if
  /// a cap is configured — evicts oldest-read-first until back under it.
  /// Pinned series and unread chapters are never touched by either step; nor
  /// is any chapter a reader currently has on screen. Returns how many
  /// chapters were removed, for the confirmation snackbar.
  Future<int> freeUpSpace() async {
    final maintenance = ref.read(retentionMaintenanceProvider);
    final openChapters = ref.read(currentlyOpenChaptersProvider);
    final interval = ref.read(retentionIntervalProvider).duration;

    var removed = await maintenance.sweepExpired(
      interval: interval,
      excludeOpen: openChapters,
    );

    final cap = ref.read(storageCapProvider).bytes;
    if (cap != null) {
      removed += await maintenance.evictOldestReadFirst(
        targetBytes: cap,
        excludeOpen: openChapters,
      );
    }

    ref.invalidate(totalDeviceDownloadBytesProvider);
    ref.invalidate(seriesStorageBreakdownProvider);
    // "Free up space" is one of the two remedies the cap pause names; a queue
    // stopped there would otherwise stay stopped until the next foreground.
    ref.read(downloadQueueControllerProvider.notifier).retryAfterStorageChange();
    return removed;
  }
}

final downloadsStorageActionsProvider = Provider<DownloadsStorageActions>(
  DownloadsStorageActions.new,
  name: 'downloadsStorageActions',
);
