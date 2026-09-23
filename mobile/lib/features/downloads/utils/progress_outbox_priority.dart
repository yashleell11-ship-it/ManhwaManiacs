import 'package:manhwamaniacs/features/downloads/utils/progress_outbox_batch.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';

/// Sources whose chapter key ends in the chapter's own number,
/// `<series key>:<number>`: `make_chapter_id` in
/// `backend/connectors/asurascans/mappers.py` and `parse_chapters` in
/// `backend/connectors/demonicscans/mappers.py`.
///
/// A list and not a pattern because the shape alone proves nothing: Tapas
/// keys are `<slug>:<episode id>`, and an episode id read as a chapter number
/// would put a series' first episode millions of chapters ahead of its last.
const Set<String> kNumberedChapterKeySources = {'asurascans', 'demonicscans'};

final RegExp _decimal = RegExp(r'^\d+(\.\d+)?$');

/// The chapter number [chapterKey] spells out, or `null` whenever that is not
/// certain: a source outside [kNumberedChapterKeySources], or a tail that is
/// not a plain number (Asura falls back to the chapter's slug when the API
/// gives no number).
double? chapterNumberFromKey({
  required String sourceId,
  required String chapterKey,
}) {
  if (!kNumberedChapterKeySources.contains(sourceId)) return null;
  final cut = chapterKey.lastIndexOf(':');
  if (cut <= 0) return null;
  final tail = chapterKey.substring(cut + 1);
  if (!_decimal.hasMatch(tail)) return null;
  return double.tryParse(tail);
}

/// Where [push] sits in its series: the number it carries, else the one its
/// key spells out, else `null` (unknown).
double? progressChapterOrdinal(ProgressPush push) =>
    push.chapterNumber ??
    chapterNumberFromKey(sourceId: push.sourceId, chapterKey: push.chapterKey);

/// [pushes] ranked by how much losing each would cost, as indexes into it.
///
/// 1. Every series' FURTHEST chapter (highest known number; with no number
///    in the series at all, its most recent read stands in). Losing it
///    rewinds the whole series on the server, which is the one loss nothing
///    else in the outbox can repair. [furthest] counts these, and nothing
///    that trims by this ranking may drop them.
/// 2. Every series' MOST RECENT chapter, when it is not already its furthest:
///    what Continue Reading shows.
/// 3. Everything else, newest read first.
///
/// "Newest" is `lastReadAt`, then position in [pushes] (later wins): rows a
/// build before capture stamps queued carry none, and those are the oldest.
({List<int> order, int furthest}) rankProgressForKeeping(
  List<ProgressPush> pushes,
) {
  bool newer(int a, int b) {
    final at = pushes[a].lastReadAt;
    final bt = pushes[b].lastReadAt;
    if (at != null && bt != null && !at.isAtSameMomentAs(bt)) {
      return at.isAfter(bt);
    }
    if (at != null && bt == null) return true;
    if (at == null && bt != null) return false;
    return a > b;
  }

  // A record key, never a joined string: series keys are opaque source
  // strings and may hold any separator (see `collapseProgressOutbox`).
  final bySeries = <(String, String), List<int>>{};
  for (final (index, push) in pushes.indexed) {
    bySeries.putIfAbsent((push.sourceId, push.seriesKey), () => []).add(index);
  }

  final furthest = <int>[];
  final recent = <int>[];
  for (final indexes in bySeries.values) {
    var latest = indexes.first;
    int? best;
    double? bestNumber;
    for (final index in indexes) {
      if (newer(index, latest)) latest = index;
      final number = progressChapterOrdinal(pushes[index]);
      if (number == null) continue;
      if (bestNumber == null ||
          number > bestNumber ||
          (number == bestNumber && newer(index, best!))) {
        best = index;
        bestNumber = number;
      }
    }
    final head = best ?? latest;
    furthest.add(head);
    if (latest != head) recent.add(latest);
  }

  final taken = {...furthest, ...recent};
  final rest = [
    for (var index = 0; index < pushes.length; index++)
      if (!taken.contains(index)) index,
  ]..sort((a, b) => newer(a, b) ? -1 : (newer(b, a) ? 1 : 0));

  return (order: [...furthest, ...recent, ...rest], furthest: furthest.length);
}

/// Which of [groups] to drop to bring the outbox down to [max] chapters, as
/// indexes into it; empty when it is already within the ceiling.
///
/// Trims from the bottom of [rankProgressForKeeping], never into its first
/// tier: a series' furthest chapter survives even when that leaves the outbox
/// over [max] (it takes more series than the ceiling has chapters for that
/// to happen at all).
Set<int> outboxGroupsToDrop(
  List<CollapsedProgress> groups, {
  int max = kProgressOutboxMaxGroups,
}) {
  if (groups.length <= max) return const {};
  final ranked = rankProgressForKeeping([for (final g in groups) g.push]);
  final keep = max > ranked.furthest ? max : ranked.furthest;
  return ranked.order.skip(keep).toSet();
}
