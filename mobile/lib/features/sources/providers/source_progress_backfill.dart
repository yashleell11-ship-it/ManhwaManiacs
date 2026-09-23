import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/core/logging/app_logger.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';
import 'package:manhwamaniacs/features/downloads/utils/progress_outbox_batch.dart';
import 'package:manhwamaniacs/features/downloads/utils/progress_outbox_priority.dart';
import 'package:manhwamaniacs/features/library/utils/followed_series_cache.dart';
import 'package:manhwamaniacs/features/profiles/providers/profiles_providers.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Set once [profileId]'s stored source progress is safely in the outbox.
String sourceProgressBackfilledKey(int profileId) =>
    'mm.source_progress.backfilled:$profileId';

/// One stored record as the push the reader would have sent for it.
///
/// Dated when it was READ ([SourceChapterProgress.updatedAt]), never now: the
/// server orders Continue Reading and breaks position ties by that stamp, and
/// a backlog stamped with today would jump days-old reads to the front.
/// No reading time, because the record holds none and 3.4.x builds already
/// sent theirs with the reader's own push — a second copy would count those
/// minutes twice in the statistics.
ProgressPush sourceProgressBackfillPush(
  SourceProgressKeyParts key,
  SourceChapterProgress record,
) =>
    ProgressPush(
      sourceId: key.sourceId,
      seriesKey: key.seriesId,
      chapterKey: key.chapterId,
      chapterNumber: chapterNumberFromKey(
        sourceId: key.sourceId,
        chapterKey: key.chapterId,
      ),
      lastPage: record.page < 1 ? 1 : record.page,
      pageCount: record.pageCount < 0 ? 0 : record.pageCount,
      isCompleted: record.completed,
      lastReadAt: record.updatedAt.toUtc(),
    );

/// Whether [record] says when it was read.
///
/// [SourceChapterProgress.fromJson] reads a missing or unparseable
/// `updatedAt` as the epoch, and no real read happened at or before it. Such
/// a record is not worth sending: the server treats a 1970 stamp as no stamp
/// at all and dates the row the moment it arrives, which puts a chapter read
/// at some unknown time at the front of Continue Reading.
bool hasSourceProgressReadTime(SourceChapterProgress record) =>
    record.updatedAt.millisecondsSinceEpoch > 0;

/// What to queue for [records], oldest read first.
///
/// At most [budget] chapters, the outbox's room under
/// [kProgressOutboxMaxGroups], chosen by [rankProgressForKeeping] — except
/// that every series' furthest chapter goes in regardless, since that is the
/// one position a later re-read cannot restore without reading to it again.
/// Records whose key cannot be split with certainty
/// ([parseSourceProgressKey]) are left out, and so are records with no read
/// time ([hasSourceProgressReadTime]).
List<ProgressPush> planSourceProgressBackfill(
  Map<String, SourceChapterProgress> records, {
  Set<(String, String)> knownSeries = const {},
  int budget = kProgressOutboxMaxGroups,
}) {
  final pushes = <ProgressPush>[];
  var unparsed = 0;
  final undated = <String>[];
  for (final entry in records.entries) {
    final key = parseSourceProgressKey(entry.key, knownSeries: knownSeries);
    if (key == null) {
      unparsed++;
      continue;
    }
    if (!hasSourceProgressReadTime(entry.value)) {
      undated.add(entry.key);
      continue;
    }
    pushes.add(sourceProgressBackfillPush(key, entry.value));
  }
  if (unparsed > 0) {
    appLogger.w(
      'source progress backfill: left out $unparsed record(s) whose key '
      'could not be split into series and chapter',
    );
  }
  if (undated.isNotEmpty) {
    const shown = 10;
    final listed = undated.take(shown).join(', ');
    final more =
        undated.length > shown ? ' and ${undated.length - shown} more' : '';
    appLogger.w(
      'source progress backfill: left out ${undated.length} record(s) with no '
      'readable read time: $listed$more',
    );
  }

  final ranked = rankProgressForKeeping(pushes);
  final keep = budget > ranked.furthest ? budget : ranked.furthest;
  final chosen = ranked.order.take(keep).toList()
    ..sort((a, b) {
      final at = pushes[a].lastReadAt!;
      final bt = pushes[b].lastReadAt!;
      final byTime = at.compareTo(bt);
      return byTime != 0 ? byTime : a.compareTo(b);
    });
  return [for (final index in chosen) pushes[index]];
}

/// Uploads the Sources-tab progress that builds before 3.4.0 kept only on the
/// phone.
///
/// Those builds saved what the Sources reader read — every chapter the Library
/// tab opens — to `mm.source_progress:<profileId>` and nowhere else, so none
/// of it reached the server, and 3.4.0 only fixed reads made after it. This
/// queues every stored record into the progress outbox once per profile,
/// through [DownloadsStore.enqueueProgress] directly: the controller's `save`
/// stamps now, and these rows must keep the time they were read.
///
/// Replaying a record the server already holds is harmless: positions merge
/// furthest-wins, and a row with no reading time and a stamp no newer than
/// the stored one credits nothing.
class SourceProgressBackfill {
  SourceProgressBackfill(this.ref);

  final Ref ref;

  /// The run in flight per profile, so overlapping triggers share one while a
  /// switch to another profile still gets its own.
  final Map<int, Future<void>> _running = {};

  /// Runs the backfill for the active profile if it has not run for it yet.
  /// Never throws.
  ///
  /// The flag is set only once every row is in the outbox, so a run that
  /// fails part-way is repeated in full next time. The repeat can queue a
  /// chapter twice, which the drain folds back into one push.
  Future<void> run() {
    final _BackfillScope? scope;
    try {
      scope = _activeScope();
    } catch (error, stackTrace) {
      // A container torn down under a late trigger: nothing to run against.
      appLogger.w('source progress backfill skipped', error, stackTrace);
      return Future.value();
    }
    if (scope == null) return Future.value();
    final profileId = scope.profileId;
    // A block body, not `=> remove(...)`: `remove` returns this very Future,
    // and `whenComplete` waits on a Future its callback returns.
    return _running[profileId] ??= _run(scope).whenComplete(() {
      _running.remove(profileId);
    });
  }

  /// The profile, and the outbox its rows belong in, read together before
  /// anything is awaited: a switch landing mid-run then cannot put one
  /// profile's reading into the other's outbox, or set the other's flag.
  _BackfillScope? _activeScope() {
    final profileId = ref.read(activeProfileProvider)?.id;
    final store = ref.read(downloadsStoreProvider);
    if (profileId == null || store == null) return null;
    return (
      prefs: ref.read(sharedPrefsProvider),
      profileId: profileId,
      store: store,
    );
  }

  Future<void> _run(_BackfillScope scope) async {
    final (:prefs, :profileId, :store) = scope;
    try {
      final flag = sourceProgressBackfilledKey(profileId);
      if (prefs.getBool(flag) ?? false) return;

      final records = readSourceProgressRecords(prefs, profileId);
      if (records.isNotEmpty) {
        final knownSeries = {
          for (final series in readCachedFollowedSeries(
            prefs,
            followedSeriesCacheKeyFor(store.scopeId),
          ))
            (series.sourceId, series.seriesKey),
        };
        final queued =
            collapseProgressOutbox(await store.pendingProgressOutbox()).length;
        final plan = planSourceProgressBackfill(
          records,
          knownSeries: knownSeries,
          budget: kProgressOutboxMaxGroups - queued,
        );
        for (final push in plan) {
          await store.enqueueProgress(push);
        }
        appLogger.i(
          'source progress backfill: queued ${plan.length} of '
          '${records.length} stored chapter(s) for profile $profileId',
        );
      }
      await prefs.setBool(flag, true);
    } catch (error, stackTrace) {
      // The flag stays unset, so the next launch or resume tries again.
      appLogger.w('source progress backfill failed', error, stackTrace);
    }
  }
}

typedef _BackfillScope = ({
  SharedPreferences prefs,
  int profileId,
  DownloadsStore store,
});

final sourceProgressBackfillProvider = Provider<SourceProgressBackfill>(
  SourceProgressBackfill.new,
  name: 'sourceProgressBackfill',
);
