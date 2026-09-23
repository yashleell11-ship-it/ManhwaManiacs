/// "Continue" on a stored reading position — the one rule the history shelf
/// and the continue-reading strip both open a chapter with.
///
/// The web's half is `frontend/src/features/library/history-continue.ts`, and
/// the rule is the server's own for the continue-reading strip
/// (`FollowedSeriesService.continue_reading`):
///
/// * an UNFINISHED chapter reopens at the stored position — `?page=`, which
///   the page reader reads as a page and the novel reader as its progress
///   bucket, the same unit each of them saved it in;
/// * a FINISHED chapter moves on to the chapter after it, from the top.
///   Reopening the chapter the reader just finished is what Continue must not
///   do;
/// * a finished chapter with nothing after it (caught up, or a key the list no
///   longer carries) has no chapter to name — the caller opens the book's page
///   instead of guessing one.
///
/// Neither reader restores a server-side position by itself: the novel reader
/// starts at bucket 1 without `?page=`, and the page reader only remembers a
/// scroll offset saved on THIS device for a chapter opened directly. A link
/// without the position therefore opened a half-read chapter at the top.
library;

import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_chapter_sort.dart';

/// Where Continue lands: a chapter and the position to open it at.
typedef ResumePoint = ({String chapterKey, int page});

/// Resolves [ResumePoint] for a stored position, or null when the reader is
/// caught up and there is no chapter to open.
///
/// [chapters] is only consulted for a finished chapter — a mid-chapter row is
/// its own answer, so callers need not fetch the list for it.
ResumePoint? resumePointFor({
  required String chapterKey,
  required int lastPage,
  required bool isCompleted,
  List<SourceChapterSummary> chapters = const [],
}) {
  if (!isCompleted) {
    return (chapterKey: chapterKey, page: lastPage > 1 ? lastPage : 1);
  }
  final next = nextChapterInReadingOrder(chapters, chapterKey);
  return next == null ? null : (chapterKey: next.id, page: 1);
}

/// What a series page's Continue button offers — see [seriesContinue].
enum SeriesContinueKind {
  /// Nothing read yet: the first chapter in reading order.
  start,

  /// A chapter and the position to open it at.
  resume,

  /// The furthest chapter is finished and nothing follows it. Continue's
  /// answer everywhere else is "the book's page", and on the book's own page
  /// that leaves the button nowhere to go, so it says so instead.
  caughtUp,
}

/// [SeriesContinueKind] and, unless caught up, where to open.
typedef SeriesContinue = ({SeriesContinueKind kind, ResumePoint? point});

/// Continue for a whole series: the chapter the reader got FURTHEST in.
///
/// [resumePointFor] applied to the furthest stored position rather than the
/// newest. The series screens used to take the most recently touched chapter,
/// and production shows what that costs: re-reading Shadow Slave chapter 1 sent Continue back to chapter 2,
/// finished weeks before, while chapter 5 sat half read; five seconds on
/// TBATE's prologue made it resume there instead of at the chapter after the
/// one just finished. The web's `seriesContinue` and the server's
/// continue-reading strip answer the same shared table
/// (`backend/tests/fixtures/reading_navigation_cases.json`).
///
/// "Furthest" is the highest chapter number; an unnumbered chapter ranks
/// below every numbered one, and between unnumbered chapters the newest read
/// wins — the order the server ranks its rows in. A position for a key the
/// list does not carry is ignored: there is no chapter to open for it.
///
/// Null only when the series has no chapters at all.
SeriesContinue? seriesContinue({
  required List<SourceChapterSummary> chapters,
  required Map<String, SourceChapterProgress> progress,
}) {
  final ordered = sortSeriesChapters(
    chapters,
    numberOf: (chapter) => chapter.number,
    order: SeriesChapterSortOrder.oldest,
  );
  if (ordered.isEmpty) return null;

  SourceChapterSummary? furthest;
  SourceChapterProgress? furthestRow;
  for (final chapter in ordered) {
    final row = progress[chapter.id];
    if (row == null) continue;
    if (furthest == null ||
        _isFurther(chapter, row, furthest, furthestRow!)) {
      furthest = chapter;
      furthestRow = row;
    }
  }

  if (furthest == null) {
    return (
      kind: SeriesContinueKind.start,
      point: (chapterKey: ordered.first.id, page: 1),
    );
  }
  final point = resumePointFor(
    chapterKey: furthest.id,
    lastPage: furthestRow!.page,
    isCompleted: furthestRow.completed,
    chapters: chapters,
  );
  return point == null
      ? (kind: SeriesContinueKind.caughtUp, point: null)
      : (kind: SeriesContinueKind.resume, point: point);
}

/// Whether [chapter] at [row] is further than the current pick.
bool _isFurther(
  SourceChapterSummary chapter,
  SourceChapterProgress row,
  SourceChapterSummary best,
  SourceChapterProgress bestRow,
) {
  final number = chapter.number;
  final bestNumber = best.number;
  if (number != null && bestNumber == null) return true;
  if (number == null && bestNumber != null) return false;
  if (number != null && bestNumber != null && number != bestNumber) {
    return number > bestNumber;
  }
  return row.updatedAt.isAfter(bestRow.updatedAt);
}

/// The chapter after [chapterKey] in READING order, or null.
///
/// Reading order is by number, ascending, unnumbered chapters last in their
/// listing order — `sortSeriesChapters` with `oldest`, which is the order the
/// server's `_next_known_chapter` walks. A connector that lists newest-first
/// would otherwise make "next" mean older. A key the list does not carry
/// yields null rather than a guess.
SourceChapterSummary? nextChapterInReadingOrder(
  List<SourceChapterSummary> chapters,
  String chapterKey,
) {
  final ordered = sortSeriesChapters(
    chapters,
    numberOf: (chapter) => chapter.number,
    order: SeriesChapterSortOrder.oldest,
  );
  final index = ordered.indexWhere((chapter) => chapter.id == chapterKey);
  if (index == -1 || index + 1 >= ordered.length) return null;
  return ordered[index + 1];
}

/// The reader location for [point], in whichever reader the source uses.
///
/// Page 1 carries no query: it is where both readers open anyway, so the
/// link stays the plain chapter path every other screen builds. A scroll
/// offset this device saved for the chapter still wins over `?page=` in the
/// page reader (`resolveInitialScrollTop`), so adding the position never
/// costs a same-device restore.
String resumeLocation({
  required String sourceId,
  required String seriesKey,
  required ResumePoint point,
  required bool isNovel,
}) {
  final path = isNovel
      ? RoutePaths.novelReader(sourceId, seriesKey, point.chapterKey)
      : RoutePaths.reader(sourceId, seriesKey, point.chapterKey);
  return point.page > 1 ? '$path?page=${point.page}' : path;
}
