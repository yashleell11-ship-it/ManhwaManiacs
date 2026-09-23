import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';

/// One series' worth of [SavedChapter] rows for the Downloads screen —
/// every chapter with any on-device footprint (queued, downloading, failed,
/// or complete), grouped by `(sourceId, seriesKey)` and ordered the way the
/// store already orders [DownloadsStore.listChapters] (newest download
/// first).
class DownloadedSeriesGroup {
  DownloadedSeriesGroup({
    required this.sourceId,
    required this.seriesKey,
    required this.seriesTitle,
    required this.chapters,
  });

  final String sourceId;
  final String seriesKey;
  final String? seriesTitle;
  final List<SavedChapter> chapters;

  /// Summed once per group, not per read. This is the sort key for the whole
  /// saved list *and* the number on every card's subtitle line, so a getter
  /// re-walked every chapter of every group on each comparison and each build.
  late final int totalBytes = chapters.fold(0, (sum, c) => sum + c.bytes);

  /// A series is "pinned" once any of its chapters is — pinning always
  /// applies to every chapter at once (see [DownloadsStore.setSeriesPinned]),
  /// and a chapter queued after the pin inherits it
  /// ([DownloadsStore.ensureQueued]), so any and all agree. Any is kept
  /// because rows saved before chapters inherited the pin can still be
  /// mixed; tapping the pin off and on again evens them out.
  bool get pinned => chapters.any((c) => c.pinned);
}
