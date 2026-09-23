import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/profiles/providers/profiles_providers.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key prefix holding the full source-progress map as a JSON
/// object mapping `"sourceId:seriesId:chapterId"` → the progress record. The
/// live storage key is namespaced per active profile (`"$prefix:$profileId"`)
/// so personas never read or overwrite each other's online-read state. Phone
/// only: the server's progress rows are the record both clients share, and the
/// Sources-tab reader pushes those too (see `SourceReaderScreen`).
const String sourceProgressPrefsKey = 'mm.source_progress';

/// The SharedPreferences key holding [profileId]'s source-progress map.
String sourceProgressStorageKey(int profileId) =>
    '$sourceProgressPrefsKey:$profileId';

/// Composite storage key for a single online chapter's progress record.
String sourceProgressKey({
  required String sourceId,
  required String seriesId,
  required String chapterId,
}) =>
    '$sourceId:$seriesId:$chapterId';

/// The three parts of a [sourceProgressKey], as far as they can be told apart.
typedef SourceProgressKeyParts = ({
  String sourceId,
  String seriesId,
  String chapterId,
});

/// Splits a [sourceProgressKey] back into its parts, or `null` when the split
/// is not certain.
///
/// The key is a plain join on ':', and the parts may hold ':' themselves:
/// Asura and DemonicScans chapter ids are `<series key>:<number>`, so an Asura
/// record is keyed `asurascans:<slug>:<slug>:94`. Splitting on every ':' files
/// that under series `<slug>:<slug>` or chapter `94`, neither of which the
/// server has ever heard of. Source ids never hold one, so the source is the
/// text before the first ':'; the series/chapter boundary is then settled, in
/// order, by
///
///  1. there being only one ':' left, when no other split exists;
///  2. [knownSeries] — `(sourceId, seriesKey)` pairs this profile is known to
///     read, such as its follows — naming exactly one candidate series;
///  3. exactly one candidate whose chapter id starts with its own series key
///     and a ':', the shape of the sources above.
///
/// Anything still ambiguous is `null`: a record left out costs one chapter's
/// position, where a wrong split pushes it under a series that does not exist.
SourceProgressKeyParts? parseSourceProgressKey(
  String key, {
  Set<(String, String)> knownSeries = const {},
}) {
  final sourceEnd = key.indexOf(':');
  if (sourceEnd <= 0) return null;
  final sourceId = key.substring(0, sourceEnd);
  final rest = key.substring(sourceEnd + 1);

  final candidates = <SourceProgressKeyParts>[];
  for (var cut = rest.indexOf(':');
      cut != -1;
      cut = rest.indexOf(':', cut + 1)) {
    if (cut == 0 || cut == rest.length - 1) continue;
    candidates.add(
      (
        sourceId: sourceId,
        seriesId: rest.substring(0, cut),
        chapterId: rest.substring(cut + 1),
      ),
    );
  }
  if (candidates.length <= 1) {
    return candidates.isEmpty ? null : candidates.single;
  }

  final known = [
    for (final candidate in candidates)
      if (knownSeries.contains((sourceId, candidate.seriesId))) candidate,
  ];
  if (known.length == 1) return known.single;

  final selfPrefixed = [
    for (final candidate in known.isEmpty ? candidates : known)
      if (candidate.chapterId.startsWith('${candidate.seriesId}:')) candidate,
  ];
  return selfPrefixed.length == 1 ? selfPrefixed.single : null;
}

/// [profileId]'s stored source-progress records, keyed by [sourceProgressKey];
/// empty when there are none or the stored payload cannot be decoded.
Map<String, SourceChapterProgress> readSourceProgressRecords(
  SharedPreferences prefs,
  int profileId,
) {
  final raw = prefs.getString(sourceProgressStorageKey(profileId));
  if (raw == null || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return {
      for (final entry in decoded.entries)
        entry.key: SourceChapterProgress.fromJson(
          entry.value as Map<String, dynamic>,
        ),
    };
  } catch (_) {
    // Corrupt payload — start clean rather than crashing the screen.
    return const {};
  }
}

/// Holds the decoded source-progress map, hydrated from SharedPreferences.
///
/// This phone's own record of what the Sources-tab reader has read, written on
/// every page alongside the push to the server's outbox. It is the half of
/// [sourceSeriesProgressProvider] that moves the moment a page turns, before
/// the outbox has flushed; the server's rows are merged over it there. It
/// backs the "read" row styling, per-row progress text, and the "Continue" vs
/// "Read Online" primary action on the series detail screen.
class SourceProgressNotifier
    extends Notifier<Map<String, SourceChapterProgress>> {
  /// Per-profile storage key resolved in [build]; `null` when no profile is
  /// active (nothing is persisted in that state).
  String? _key;

  @override
  Map<String, SourceChapterProgress> build() {
    final prefs = ref.watch(sharedPrefsProvider);
    // Watching the active profile namespaces the store *and* self-rebuilds on
    // a profile switch: the incoming persona re-reads its own records while the
    // outgoing one's drop off screen.
    final profileId = ref.watch(activeProfileProvider)?.id;
    if (profileId == null) {
      _key = null;
      return const {};
    }
    _key = sourceProgressStorageKey(profileId);
    return readSourceProgressRecords(prefs, profileId);
  }

  /// Persist the current page for a chapter. Marks the record completed when
  /// [page] reaches [pageCount] (with ``pageCount > 0``) and stamps
  /// ``updatedAt`` so the latest-read lookup can find the most recent chapter.
  ///
  /// Furthest-wins within the chapter, exactly as the server's
  /// `merge_progress` is: the stored page never moves backwards, finishing is
  /// sticky and the page count never shrinks. Scrolling back up to re-read a
  /// panel — or a stray save for a page the continuous feed has already left
  /// behind — is not a claim to be earlier in the chapter than the reader got
  /// to, and honouring it rewound "Continue" on the series page. Only
  /// ``updatedAt`` is unconditional: a re-read is still the most recent read.
  Future<void> record({
    required String sourceId,
    required String seriesId,
    required String chapterId,
    required int page,
    required int pageCount,
  }) async {
    final key = sourceProgressKey(
      sourceId: sourceId,
      seriesId: seriesId,
      chapterId: chapterId,
    );
    final existing = state[key];
    final safePage = page < 1 ? 1 : page;
    final furthestPage =
        existing != null && existing.page > safePage ? existing.page : safePage;
    final knownCount =
        existing != null && existing.pageCount > pageCount
            ? existing.pageCount
            : pageCount;
    final entry = SourceChapterProgress(
      page: furthestPage,
      pageCount: knownCount,
      completed: (existing?.completed ?? false) ||
          (pageCount > 0 && safePage >= pageCount),
      updatedAt: DateTime.now().toUtc(),
    );
    final next = {...state, key: entry};
    state = next;
    await _persist(next);
  }

  /// Replay a migration's chapter map over this store, returning how many
  /// records carried over.
  ///
  /// Online reading progress for a non-downloaded remote series exists only
  /// here — the server has no read model for it — so a migration that did not
  /// do this would repoint the tracker and silently lose the reader's place.
  ///
  /// Three rules, matching the web's `applyProgressRemap` so both clients agree
  /// about the shared store:
  ///
  ///  * **Copies, never moves.** The records under the old (source, series) are
  ///    left alone, so migrating back loses nothing and replaying the same map
  ///    is a no-op.
  ///  * A chapter with no target (`toChapterId == null`) is skipped — there is
  ///    nowhere to put it.
  ///  * A target that already holds *newer* progress is never overwritten.
  ///    Nearest-match can collapse two old chapters onto one target, and the
  ///    most recently read of them is the one that says where the reader is.
  Future<int> remapSeriesProgress({
    required String fromSourceId,
    required String fromSeriesId,
    required String toSourceId,
    required String toSeriesId,
    required Map<String, String> carriedChapterIds,
  }) async {
    final next = {...state};
    var carried = 0;

    for (final entry in carriedChapterIds.entries) {
      final source = next[sourceProgressKey(
        sourceId: fromSourceId,
        seriesId: fromSeriesId,
        chapterId: entry.key,
      )];
      if (source == null) continue;

      final targetKey = sourceProgressKey(
        sourceId: toSourceId,
        seriesId: toSeriesId,
        chapterId: entry.value,
      );
      final existing = next[targetKey];
      if (existing != null && !existing.updatedAt.isBefore(source.updatedAt)) {
        continue;
      }

      next[targetKey] = source;
      carried += 1;
    }

    if (carried == 0) return 0;
    state = next;
    await _persist(next);
    return carried;
  }

  Future<void> _persist(Map<String, SourceChapterProgress> map) async {
    final key = _key;
    if (key == null) return;
    final prefs = ref.read(sharedPrefsProvider);
    final encoded = jsonEncode(
      map.map((key, value) => MapEntry(key, value.toJson())),
    );
    await prefs.setString(key, encoded);
  }

  /// Progress for a single chapter, or ``null`` when never opened.
  SourceChapterProgress? progressFor({
    required String sourceId,
    required String seriesId,
    required String chapterId,
  }) =>
      state[sourceProgressKey(
        sourceId: sourceId,
        seriesId: seriesId,
        chapterId: chapterId,
      )];

  /// Progress records for one series, keyed by chapter id.
  Map<String, SourceChapterProgress> forSeries({
    required String sourceId,
    required String seriesId,
  }) {
    final prefix = '$sourceId:$seriesId:';
    return {
      for (final entry in state.entries)
        if (entry.key.startsWith(prefix))
          entry.key.substring(prefix.length): entry.value,
    };
  }
}

final sourceProgressProvider =
    NotifierProvider<SourceProgressNotifier, Map<String, SourceChapterProgress>>(
  SourceProgressNotifier.new,
  name: 'sourceProgress',
);

/// One series, as the per-series progress providers are keyed.
typedef SourceSeriesRef = ({String sourceId, String seriesId});

/// The server's stored positions for ONE series (`GET /reader/progress/series`),
/// keyed by chapter key, in this store's record shape.
///
/// The series screens used to read only the store above, which only the manga
/// reader writes and only on THIS phone: the novel reader saves to the server
/// alone, so a book read here or on the web showed nothing read and offered
/// "Start reading" however far in the reader was. The web merges the same
/// endpoint under its own store (`series-progress.ts`).
///
/// 18+-gated: a withheld series answers an empty list, so this is dropped with
/// the other gated caches when the switch flips (`matureScopedInvalidators`).
/// Watches the active profile, so a profile switch refetches it — positions
/// are per (user, profile).
final sourceSeriesServerProgressProvider = FutureProvider.autoDispose
    .family<Map<String, SourceChapterProgress>, SourceSeriesRef>(
  (ref, series) async {
    final profileId = ref.watch(activeProfileProvider)?.id;
    if (profileId == null) return const {};
    final result = await ref.watch(readerRepositoryProvider).seriesProgress(
          sourceId: series.sourceId,
          seriesKey: series.seriesId,
        );
    if (result.isErr) throw result.error;
    return serverProgressMap(result.value);
  },
  name: 'sourceSeriesServerProgress',
);

/// Server rows in this store's record shape, keyed by chapter key.
///
/// `last_page` is a page for a manga chapter and a progress BUCKET for a novel
/// one, which is the unit the local record already holds for each.
Map<String, SourceChapterProgress> serverProgressMap(
  List<ReadingProgress> rows,
) {
  return {
    for (final row in rows)
      if (row.chapterKey.isNotEmpty)
        row.chapterKey: SourceChapterProgress(
          page: row.lastPage < 1 ? 1 : row.lastPage,
          pageCount: row.pageCount < 0 ? 0 : row.pageCount,
          completed: row.isCompleted,
          updatedAt: row.lastReadAt?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ),
  };
}

/// One series' positions from both stores, furthest-wins per chapter.
///
/// The server's own merge rule (`merge_progress`), not "server wins": the
/// manga reader writes this phone's store on every page and the server only
/// when its outbox flushes, so the local record is often the newer of the two
/// and replacing it would rewind the page the reader just left.
Map<String, SourceChapterProgress> mergeSourceProgress(
  Map<String, SourceChapterProgress> local,
  Map<String, SourceChapterProgress> server,
) {
  final merged = {...local};
  for (final entry in server.entries) {
    final mine = merged[entry.key];
    final theirs = entry.value;
    merged[entry.key] = mine == null
        ? theirs
        : SourceChapterProgress(
            page: mine.page > theirs.page ? mine.page : theirs.page,
            pageCount: mine.pageCount > theirs.pageCount
                ? mine.pageCount
                : theirs.pageCount,
            completed: mine.completed || theirs.completed,
            updatedAt: mine.updatedAt.isAfter(theirs.updatedAt)
                ? mine.updatedAt
                : theirs.updatedAt,
          );
  }
  return merged;
}

/// Everything a series screen shows about reading position: this phone's
/// records and the server's, merged. Rebuilds when the reader records a page
/// here, and again when the server's answer lands.
final sourceSeriesProgressProvider = Provider.autoDispose
    .family<Map<String, SourceChapterProgress>, SourceSeriesRef>(
  (ref, series) {
    ref.watch(sourceProgressProvider);
    final local = ref.read(sourceProgressProvider.notifier).forSeries(
          sourceId: series.sourceId,
          seriesId: series.seriesId,
        );
    final server =
        ref.watch(sourceSeriesServerProgressProvider(series)).valueOrNull ??
            const <String, SourceChapterProgress>{};
    return mergeSourceProgress(local, server);
  },
  name: 'sourceSeriesProgress',
);
