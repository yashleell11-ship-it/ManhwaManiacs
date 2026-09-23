import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/downloads/providers/bookmark_outbox_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/currently_open_chapter_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/progress_outbox_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/retention_maintenance_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/storage_settings_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
import 'package:manhwamaniacs/features/ocr/controllers/ocr_run_controller.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_backfill.dart';

/// Wraps the app and drives every piece of 1c-M3 that has to run on a
/// schedule rather than in response to a single user action:
///
/// - **Retention sweep** (read-then-expire) on launch and on every resume —
///   never on a timer, because a sideloaded build has no dependable
///   background execution (spec §3): "48 hours later" honestly means "the
///   first app open after 48 hours have elapsed".
/// - **Download queue resume** on launch (picks up any `queued`/`downloading`
///   row a previous run left behind) and **foreground gating** — paused the
///   instant the app backgrounds, resumed the instant it returns, so a
///   chapter mid-download is a durable, resumable no-op rather than a
///   silent stall.
/// - **Progress outbox flush** on launch, resume, and connectivity regained
///   — a save made offline reaches the server the moment any of those give
///   it a chance, without the reader itself ever blocking on it. The same
///   flush also runs when a session scope appears (sign-in resolving after
///   the first frame, a profile picked or switched to).
/// - **Source-progress backfill** just before that flush: once per profile,
///   the Sources-tab progress builds before 3.4.0 kept only on the phone is
///   queued into the outbox (`SourceProgressBackfill`).
/// - **Bookmark outbox flush** on the same three triggers, and a full
///   bookmark *sync* (push then pull) on launch and resume. The pull is not
///   done on every connectivity blip: a flush is free when there is nothing
///   queued, where a listing is a round trip every time WiFi flickers — and
///   news of a bookmark deleted on another device is worth having by the next
///   time the app is opened, not within seconds.
///
/// Mounted once at the app root (`app.dart`), the same place
/// `WhatsNewAutoShow` hooks the identical `WidgetsBindingObserver` pattern.
class DownloadsLifecycleGate extends ConsumerStatefulWidget {
  const DownloadsLifecycleGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DownloadsLifecycleGate> createState() => _DownloadsLifecycleGateState();
}

class _DownloadsLifecycleGateState extends ConsumerState<DownloadsLifecycleGate>
    with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        _flushOutbox();
      }
    });
    // At launch the session is usually not known yet (auth restores after the
    // first frame), so the launch pass below finds no scope and does nothing.
    // A scope appearing — sign-in resolved, a profile picked or switched to —
    // is the first moment that profile's progress can be backfilled or sent.
    //
    // Deferred a microtask: Riverpod calls this listener BEFORE it marks the
    // scope's dependents stale, so a store read inside it is the previous
    // scope's — `null` on sign-in, which would make the pass a no-op.
    ref.listenManual<String?>(activeDownloadsScopeIdProvider, (previous, next) {
      if (next == null || next == previous) return;
      scheduleMicrotask(() {
        if (mounted) unawaited(_backfillThenFlushProgress());
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _onActive(isLaunch: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(downloadQueueControllerProvider.notifier);
    final ocr = ref.read(ocrRunControllerProvider.notifier);
    if (state == AppLifecycleState.resumed) {
      controller.setForeground(true);
      ocr.setForeground(true);
      _onActive(isLaunch: false);
    } else {
      // Foreground-only downloads (spec §3): pause before the queue's next
      // network call rather than let it race an app that's about to suspend.
      controller.setForeground(false);
      // Same for an in-flight OCR run (spec §4) — it holds between pages
      // rather than being cancelled, so nothing already recognized is lost.
      ocr.setForeground(false);
    }
  }

  void _onActive({required bool isLaunch}) {
    if (!mounted) return;
    _sweep();
    ref.read(downloadQueueControllerProvider.notifier).resumePendingOnLaunch();
    unawaited(_backfillThenFlushProgress());
    unawaited(ref.read(bookmarkOutboxControllerProvider).flush());
    unawaited(ref.read(bookmarkOutboxControllerProvider).sync());
  }

  /// Queues this profile's stranded Sources-tab progress (once per profile,
  /// see [SourceProgressBackfill]) and then flushes the progress outbox, so
  /// the backfilled rows leave in the same flush rather than waiting for the
  /// next trigger.
  Future<void> _backfillThenFlushProgress() async {
    // Both read now, while this state is certainly mounted.
    final backfill = ref.read(sourceProgressBackfillProvider);
    final outbox = ref.read(progressOutboxControllerProvider);
    await backfill.run();
    await outbox.flush();
  }

  Future<void> _sweep() async {
    final interval = ref.read(retentionIntervalProvider).duration;
    final openChapters = ref.read(currentlyOpenChaptersProvider);
    try {
      await ref.read(retentionMaintenanceProvider).sweepExpired(
            interval: interval,
            excludeOpen: openChapters,
          );
    } catch (_) {
      // Best-effort housekeeping — retried on the next launch/resume.
    }
  }

  void _flushOutbox() {
    unawaited(ref.read(progressOutboxControllerProvider).flush());
    unawaited(ref.read(bookmarkOutboxControllerProvider).flush());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_connectivitySubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
