import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';

/// One chapter's on-device download state, for driving a
/// [SeriesChapterDownloadAction] — the badge or button on a chapter row.
typedef ChapterDownloadStatus = ({DownloadChapterState state, String? error});

/// How far into a chapter the queue has got. `pageTotal` is 0 until the
/// manifest lands, which is the window where a bar must stay indeterminate
/// rather than read "page 0 of 0" — a stall is exactly what that looks like.
typedef ChapterDownloadProgress = ({int pagesDone, int pageTotal});

/// Every chapter of [series] that has a row in the active scope's store,
/// keyed by chapter key. A chapter with no entry here has never been queued
/// — the "not yet downloaded" default a chapter tile's download button
/// starts from.
///
/// Re-fetches whenever a chapter row's state changes (queued, finished,
/// failed, cancelled) so a download button's icon updates without the screen
/// needing its own polling.
/// Resolves to an empty map with no active scope — no store, no statuses,
/// matching "no scope → UI shows nothing downloaded".
final seriesChapterDownloadStatusProvider = FutureProvider.autoDispose
    .family<Map<String, ChapterDownloadStatus>, SeriesIdentity>((ref, series) async {
  final store = ref.watch(downloadsStoreProvider);
  // Dependency only, to force a re-fetch whenever a row's state changes.
  ref.watch(downloadQueueControllerProvider.select((s) => s.queueRevision));
  if (store == null) return const {};

  final chapters = await store.listChapters();
  return {
    for (final chapter in chapters)
      if (chapter.sourceId == series.sourceId && chapter.seriesKey == series.seriesKey)
        chapter.chapterKey: (state: chapter.state, error: chapter.error),
  };
});

/// [seriesChapterDownloadStatusProvider]'s counterpart for saved NARRATION:
/// the state of each chapter's audio row, keyed by the CHAPTER's key (not the
/// row's `:audio` one), so a chapter list can ask about audio in the same
/// terms it asks about text.
final seriesNarrationStatusProvider = FutureProvider.autoDispose
    .family<Map<String, ChapterDownloadStatus>, SeriesIdentity>((ref, series) async {
  final store = ref.watch(downloadsStoreProvider);
  ref.watch(downloadQueueControllerProvider.select((s) => s.queueRevision));
  if (store == null) return const {};

  final chapters = await store.listChapters(includeNarration: true);
  return {
    for (final chapter in chapters)
      if (chapter.kind.isAudio &&
          chapter.sourceId == series.sourceId &&
          chapter.seriesKey == series.seriesKey)
        textIdentity(chapter.identity).chapterKey:
            (state: chapter.state, error: chapter.error),
  };
});

/// Which chapter of [series] the queue is fetching right now and how far into
/// it, or `null` when the loop is elsewhere (another series, or idle).
///
/// A second, narrower channel than [seriesChapterDownloadStatusProvider] on
/// purpose. That one re-queries the store on `queueRevision` — which
/// deliberately does *not* move page by page, so a forty-page chapter costs
/// it one query. Page progress therefore has to come straight off the queue
/// state, and the `select` keeps a series page rebuilding once per page
/// rather than on every field of that state.
final seriesActiveChapterProgressProvider = Provider.autoDispose
    .family<({String chapterKey, ChapterDownloadProgress progress})?, SeriesIdentity>(
  (ref, series) => ref.watch(
    downloadQueueControllerProvider.select((state) {
      final current = state.currentChapter;
      if (current == null ||
          current.sourceId != series.sourceId ||
          current.seriesKey != series.seriesKey) {
        return null;
      }
      return (
        chapterKey: current.chapterKey,
        progress: (pagesDone: state.pagesDone, pageTotal: state.pageTotal),
      );
    }),
  ),
  name: 'seriesActiveChapterProgress',
);
