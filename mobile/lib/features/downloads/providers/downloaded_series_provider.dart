import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/downloads/models/downloaded_series_group.dart';
import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';

/// Every downloaded/downloading/queued/failed chapter in the active scope,
/// grouped by series — the Downloads screen's data source. Empty with no
/// active scope (no store, no listing — the isolation contract).
///
/// Re-fetches on [DownloadQueueState.queueRevision] rather than on the whole
/// queue state: a chapter finishing, failing, being queued or being cancelled
/// changes what this returns, while the page-by-page counter that ticks
/// dozens of times inside one chapter does not.
final downloadedSeriesProvider =
    FutureProvider.autoDispose<List<DownloadedSeriesGroup>>((ref) async {
  final store = ref.watch(downloadsStoreProvider);
  ref.watch(downloadQueueControllerProvider.select((s) => s.queueRevision));
  if (store == null) return const [];

  // Narration included: this is the one screen that must account for every
  // byte on the phone, and the only place a saved narration can be removed
  // on its own once its chapter is gone from view.
  final chapters = await store.listChapters(includeNarration: true);
  final bySeries = <String, List<SavedChapter>>{};
  final order = <String>[];
  for (final chapter in chapters) {
    final key = '${chapter.sourceId} ${chapter.seriesKey}';
    final group = bySeries.putIfAbsent(key, () {
      order.add(key);
      return [];
    });
    group.add(chapter);
  }

  return [
    for (final key in order)
      DownloadedSeriesGroup(
        sourceId: bySeries[key]!.first.sourceId,
        seriesKey: bySeries[key]!.first.seriesKey,
        seriesTitle: bySeries[key]!
            .map((c) => c.seriesTitle)
            .firstWhere((t) => t != null && t.isNotEmpty, orElse: () => null),
        chapters: bySeries[key]!,
      ),
  ];
});

/// [downloadedSeriesProvider] as the Downloads screen renders it: rows of the
/// active content mode, largest series first.
///
/// Derived here rather than in the screen's `build`, because neither step is
/// free — the mode filter allocates a fresh group per series and the ordering
/// sorts the whole list — and the screen rebuilds for reasons that change
/// neither (a tab swipe, expanding the queue, a theme change). As a provider
/// the work runs once per change to the downloads themselves or to the mode.
final downloadedShelfProvider =
    Provider.autoDispose<AsyncValue<List<DownloadedSeriesGroup>>>((ref) {
  final scope = ref.watch(contentModeScopeProvider);
  return ref.watch(downloadedSeriesProvider).whenData(
        (groups) => [...groupsInMode(groups, scope)]
          // Largest series first — this list doubles as the answer to "what is
          // taking up my space", and the per-series breakdown on the Storage
          // tab uses the same ordering for the same reason.
          ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes)),
      );
});

/// [rows] of the active mode.
///
/// Filtered on each ROW's own `kind`, not through the source-mode index: the
/// Downloads screen is the one screen that must be right with no network, and
/// the index is built from a `/sources` call that a phone in airplane mode
/// never made.
List<SavedChapter> chaptersInMode(
  List<SavedChapter> rows,
  ContentModeScope scope,
) {
  if (!scope.novelsEnabled) return rows;
  // Narration belongs with the books it reads, not among the manga.
  return rows.where((c) => c.kind.isNovelSide == scope.isNovel).toList();
}

/// [groups] reduced to the chapters of the active mode, dropping any series
/// left with none.
List<DownloadedSeriesGroup> groupsInMode(
  List<DownloadedSeriesGroup> groups,
  ContentModeScope scope,
) {
  if (!scope.novelsEnabled) return groups;
  final out = <DownloadedSeriesGroup>[];
  for (final group in groups) {
    final chapters = chaptersInMode(group.chapters, scope);
    if (chapters.isEmpty) continue;
    out.add(
      DownloadedSeriesGroup(
        sourceId: group.sourceId,
        seriesKey: group.seriesKey,
        seriesTitle: group.seriesTitle,
        chapters: chapters,
      ),
    );
  }
  return out;
}
