import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/logging/app_logger.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';
import 'package:manhwamaniacs/features/downloads/utils/progress_outbox_batch.dart';
import 'package:manhwamaniacs/features/downloads/utils/progress_outbox_priority.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

/// Saves reading progress the offline-safe way: write locally first, flush
/// to the server later. Every call resolves immediately regardless of
/// network state — the reader must never block (or lose a save) on a flaky
/// connection.
///
/// [flush] drains the local outbox via `POST /reader/progress/batch`. Safe
/// to call as often as you like (connectivity regained, app resumed, right
/// after a save): overlapping calls are coalesced rather than run side by
/// side, because a push is NOT harmless to replay — the position half merges
/// furthest-wins, but `time_spent_seconds` is a delta the server ADDS, so a
/// row delivered twice counts its minutes twice.
class ProgressOutboxController {
  ProgressOutboxController(this.ref);

  final Ref ref;

  /// Stands for "the container is gone". Not `null`, which is a real scope
  /// (signed out), and not any scope id, so a teardown mid-drain always reads
  /// as a switch.
  static const String _goneScope = '\u0000gone';

  /// The batch size the server is known to accept. Starts at the documented
  /// cap and only ever shrinks, on a 413 that names a smaller one — an
  /// instance field so the next flush inherits it instead of rediscovering
  /// the same refusal.
  int _batchLimit = kProgressBatchMaxItems;

  /// The drain in progress, and the single pass queued behind it. Two drains
  /// must never run at once: the second reads the same rows (the first clears
  /// them only after its 200) and posts them again, and the server sums the
  /// reading time of both copies.
  Future<void>? _draining;
  Future<void>? _queued;

  /// Rows enqueued since the outbox was last read, and the earliest the
  /// opportunistic flush in [save] may try again after one failed. Offline,
  /// that attempt is a full read of every queued row for a POST that cannot
  /// land — once per page turn.
  int _queuedSinceRead = 0;
  DateTime? _holdFlushUntil;

  /// How long [save] leaves the network alone after a failed attempt. The
  /// lifecycle gate's own triggers (connectivity regained, app resumed) are
  /// never held back — they fire on evidence that something changed, where
  /// this is a guess that nothing has.
  static const Duration _flushHold = Duration(seconds: 30);

  /// Writes [push] to the local outbox, then makes a best-effort attempt to
  /// flush immediately (so a save while online still reaches the server
  /// promptly rather than waiting for the next resume/connectivity event).
  /// A no-op with no active scope — there is nowhere to persist it.
  ///
  /// The capture time is stamped HERE rather than at send time: this is the
  /// moment the reader was actually on that page, and a push flushed after a
  /// flight has to say so or the server dates a week-old read to now.
  Future<void> save(ProgressPush push) async {
    final store = ref.read(downloadsStoreProvider);
    if (store == null) return;
    await store.enqueueProgress(push.stampedAt(DateTime.now().toUtc()));
    _queuedSinceRead++;
    final hold = _holdFlushUntil;
    if (hold == null || DateTime.now().isAfter(hold)) return flush();
    // Still offline as far as this controller knows, so the row simply waits.
    // Folding what has piled up meanwhile is what keeps the next read cheap.
    if (_queuedSinceRead >= kProgressOutboxCompactRows) await _compact(store);
  }

  /// Drains every pending push for the active scope. Failures leave the
  /// unsent rows queued for the next flush attempt — never thrown, so a
  /// caller wiring this to a lifecycle event never needs its own try/catch.
  ///
  /// A call that arrives while a drain is running does not start its own: it
  /// joins the one follow-up pass queued behind it, which reads the outbox
  /// after the running drain has cleared what it delivered. So the caller
  /// still gets a flush that covers the row it just wrote, and no row is ever
  /// read — and therefore posted — by two drains at once.
  Future<void> flush() {
    final draining = _draining;
    if (draining != null) {
      return _queued ??= draining.then((_) {
        _queued = null;
        return flush();
      });
    }
    return _draining = _drain().whenComplete(() => _draining = null);
  }

  /// One pass over the outbox.
  ///
  /// Collapsed per chapter and then chunked, because both bound the same
  /// failure: the server refuses a batch over [kProgressBatchMaxItems] items
  /// with a 413, and one 413 used to wedge the outbox permanently — the whole
  /// queue was posted as one array and cleared only on success, so every
  /// later flush resent the same oversized batch and took the same refusal.
  /// An hour of offline reading is enough rows to get there.
  Future<void> _drain() async {
    // Every step inside the try, the provider reads included: a drain that
    // completed with an error would hand that error to the pass queued behind
    // it, which would then never clear itself and wedge every later flush.
    try {
      final store = ref.read(downloadsStoreProvider);
      if (store == null) return;
      final repository = ref.read(readerRepositoryProvider);
      // The scope these rows belong to, read from the same provider the later
      // check reads so the two can only ever differ by an actual switch. The
      // profile header is mutated in place on the shared client, so a switch
      // landing mid-drain would post this profile's positions as the incoming
      // one's — the push-direction twin of the bookmark sync's scope check.
      final startedIn = _activeScopeId();
      final pending = await store.pendingProgressOutbox();
      _queuedSinceRead = 0;
      if (pending.isEmpty) {
        _holdFlushUntil = null;
        return;
      }
      for (final chunk in chunkForBatch(
        collapseProgressOutbox(pending),
        max: _batchLimit,
      )) {
        // Re-checked per chunk, not once: the switch can land between two
        // chunks just as easily as before the first. The rows stay queued in
        // their own scope's store and go out when that profile is active
        // again, which is the only time the server can attribute them.
        if (_switchedAwayFrom(startedIn)) return;
        final result = await repository.saveProgressBatch(
          [for (final group in chunk) group.push],
        );
        if (result.isErr) {
          final error = result.error;
          if (error is ApiError && error.statusCode == 422) {
            // A verdict on the bytes, not on the link: the same rows re-posted
            // draw the same refusal, and the batch is validated as a unit, so
            // every row queued behind an unsendable one never leaves either.
            // Dropping what the server named costs one chapter its scroll
            // position; keeping it costs every save made after it.
            final refused = _refusedRows(error, chunk.length);
            appLogger.w(
              'progress outbox: dropped ${refused.length} of ${chunk.length} '
              'row(s) the server refused as invalid (${error.message})',
            );
            await store.clearProgressOutbox([
              for (final index in refused) ...chunk[index].outboxIds,
            ]);
            // Whatever survived this chunk stays queued for the next trigger,
            // which now has a payload the server can accept.
            continue;
          }
          // A server that has since lowered its cap says so in the refusal.
          // Adopt it now so the NEXT flush fits, rather than resending a batch
          // this one already knows is too big (the download queue renegotiates
          // its manifest windows the same way).
          _batchLimit = _capFromBatchTooLarge(error) ?? _batchLimit;
          _holdFlushUntil = DateTime.now().add(_flushHold);
          // Stop at the first failing chunk rather than skipping ahead: the
          // remaining chunks stay queued, and a partial flush that dropped
          // them would lose the positions they carry.
          return;
        }
        // Only now, with the server's acceptance in hand: a row cleared on the
        // strength of a POST still in flight is a lost position if it fails.
        await store.clearProgressOutbox([
          for (final group in chunk) ...group.outboxIds,
        ]);
      }
      _holdFlushUntil = null;
    } catch (_) {
      // Offline or a transient server error — the rows stay queued for the
      // next flush trigger (connectivity regained, app resumed).
      _holdFlushUntil = DateTime.now().add(_flushHold);
    }
  }

  /// Rewrites the queued rows as one row per chapter, in place.
  ///
  /// Lossless: [collapseProgressOutbox] merges exactly the way the server's
  /// `merge_progress` does, so the folded row and the rows it replaces produce
  /// the same stored state — including the summed reading time, which is why
  /// the fold writes a new row rather than keeping the newest one.
  ///
  /// Written before the originals are cleared, so a crash between the two
  /// leaves a duplicate rather than a hole. That duplicate is the same
  /// at-least-once delivery the outbox already has (a crash after a 200 and
  /// before the clear replays the row), and it is the server's idempotency
  /// that has to settle it either way.
  ///
  /// Past [kProgressOutboxMaxGroups] chapters the least valuable are dropped
  /// ([outboxGroupsToDrop]), never simply the oldest: the oldest row is often
  /// the furthest chapter of a series, and losing it rewinds that series on
  /// every device. The one-time backfill of Sources-tab progress
  /// (`SourceProgressBackfill`) queues exactly such rows.
  Future<void> _compact(DownloadsStore store) async {
    try {
      final pending = await store.pendingProgressOutbox();
      _queuedSinceRead = 0;
      final groups = collapseProgressOutbox(pending);
      final dropped = outboxGroupsToDrop(groups);
      for (final (index, group) in groups.indexed) {
        if (dropped.contains(index)) {
          await store.clearProgressOutbox(group.outboxIds);
          continue;
        }
        if (group.outboxIds.length < 2) continue;
        await store.enqueueProgress(group.push);
        await store.clearProgressOutbox(group.outboxIds);
      }
    } catch (_) {
      // Housekeeping — a failure leaves every row exactly where it was.
    }
  }

  /// Which rows of a refused chunk to quarantine, as indexes into it.
  ///
  /// The rows the server named, when it named any — FastAPI reports the
  /// offending item by its position in the posted array (`loc: ['body', 3,
  /// 'chapter_key']`), and a server that lands the good items and reports its
  /// own per-item refusals says `index`. When it names none there is no way to
  /// tell the poison from what it was posted with, and the refused batch is
  /// the smallest unit that can be dropped: leaving it queued wedges the
  /// outbox on a payload no retry can change.
  Set<int> _refusedRows(ApiError error, int chunkLength) {
    final named = <int>{};
    _collectRefusedIndexes(error.details, named);
    named.removeWhere((index) => index < 0 || index >= chunkLength);
    if (named.isNotEmpty) return named;
    return {for (var index = 0; index < chunkLength; index++) index};
  }

  void _collectRefusedIndexes(Object? details, Set<int> into) {
    switch (details) {
      case final num index:
        into.add(index.toInt());
      case final List<Object?> entries:
        for (final entry in entries) {
          _collectRefusedIndexes(entry, into);
        }
      case final Map<Object?, Object?> entry:
        // Only the FIRST number in a `loc`: the rest name the field and its
        // path inside the item, not another item.
        final location = entry['loc'];
        if (location is List) {
          for (final part in location) {
            if (part is num) {
              into.add(part.toInt());
              break;
            }
          }
        }
        _collectRefusedIndexes(entry['index'], into);
        _collectRefusedIndexes(entry['rejected'], into);
    }
  }

  /// Whether the active download scope has moved since a drain began.
  bool _switchedAwayFrom(String? startedIn) =>
      _activeScopeId() != startedIn;

  /// The scope the app is in right now.
  ///
  /// Read late and defensively: during sign-out teardown the container this
  /// controller was built in can already be gone, and a sentinel that can
  /// never equal a real scope is what stops a drain from posting into it.
  String? _activeScopeId() {
    try {
      return ref.read(activeDownloadsScopeIdProvider);
    } catch (_) {
      return _goneScope;
    }
  }

  int? _capFromBatchTooLarge(AppError error) {
    if (error is! ApiError || error.code != 'batch_too_large') return null;
    final details = error.details;
    if (details is! Map) return null;
    final cap = details['max_items'];
    return cap is num && cap >= 1 ? cap.toInt() : null;
  }
}

final progressOutboxControllerProvider = Provider<ProgressOutboxController>(
  ProgressOutboxController.new,
  name: 'progressOutboxController',
);
