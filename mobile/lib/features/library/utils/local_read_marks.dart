/// What THIS phone has recorded itself about how far into a followed series
/// the reader got.
///
/// Before 3.4.0 the Sources-tab reader — the one every chapter row on a
/// followed series' page opens — kept its positions on the phone alone
/// (`sourceProgressProvider`, SharedPreferences) and never sent them to the
/// server. The server's `read_state` therefore says "not started" for series
/// the owner is a hundred chapters into, and the library card repeated it
/// under a cover whose own series page, one tap away, shows him where he is.
/// Until those records reach the server, the card asks the phone as well
/// (see `readStateWithLocal`). Read-only: nothing here writes the store.
library;

import 'package:collection/collection.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/utils/series_identity.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';

/// This phone's record for one series: that it was opened, and the furthest
/// printed chapter number among the chapters opened, where the source's
/// chapter keys carry one.
class LocalReadMark {
  const LocalReadMark({this.chapterNumber});

  /// Null when no opened chapter's key says its number — the card then says
  /// "Started", which is still true where "Not started" is not.
  final double? chapterNumber;

  /// This mark with [number] folded in, furthest-wins.
  LocalReadMark _with(double? number) {
    final current = chapterNumber;
    if (number == null || (current != null && current >= number)) return this;
    return LocalReadMark(chapterNumber: number);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalReadMark && other.chapterNumber == chapterNumber;

  @override
  int get hashCode => chapterNumber.hashCode;

  @override
  String toString() => 'LocalReadMark($chapterNumber)';
}

/// Sources whose chapter key is `<series key>:<printed number>` — the only
/// place a number can be read off a key without a chapter list. Not a general
/// rule: Tapas' `<slug>:<n>` is an episode id and Comicland's trailing number
/// an index, so a guess there would print a chapter the reader never reached.
const Set<String> _numberedKeySources = {asuraSourceId, 'demonicscans'};

final RegExp _trailingNumber = RegExp(r':(\d+(?:\.\d+)?)$');

double? _chapterNumberOf(String sourceId, String chapterKey) {
  if (!_numberedKeySources.contains(sourceId)) return null;
  final match = _trailingNumber.firstMatch(chapterKey);
  return match == null ? null : double.tryParse(match.group(1)!);
}

/// The progress store, indexed for "what does this phone know about series
/// X" questions.
///
/// Rebuilt on every page the reader records, and asked once per card on the
/// screen, so the expensive part is paid once per store: Asura's records are
/// reduced to one mark per series identity up front (one regex per record,
/// not one per record per card). Every other source is answered by a prefix
/// scan over its own records, remembered per series.
class LocalReadMarks {
  LocalReadMarks(Map<String, SourceChapterProgress> records) {
    for (final key in records.keys) {
      final colon = key.indexOf(':');
      if (colon <= 0) continue;
      // A source id never holds a ':', so the first one ends it; what follows
      // is `<series key>:<chapter key>`.
      final sourceId = key.substring(0, colon);
      final rest = key.substring(colon + 1);
      if (sourceId == asuraSourceId) {
        _indexAsura(rest);
      } else {
        (_bySource[sourceId] ??= []).add(rest);
      }
    }
  }

  static final LocalReadMarks empty = LocalReadMarks(const {});

  /// Asura series identity -> its mark. An Asura series key is a slug, and a
  /// slug holds no ':', so there the first ':' does end the series — the
  /// chapter key after it is itself `<slug>:<number>`.
  final Map<String, LocalReadMark> _asura = {};

  /// Every other source: `sourceId -> ["<series key>:<chapter key>"]`. That
  /// split is not safe to make blind (a key may hold a ':'), so a series is
  /// matched as a prefix, never split off.
  final Map<String, List<String>> _bySource = {};

  final Map<String, LocalReadMark?> _memo = {};

  void _indexAsura(String rest) {
    final colon = rest.indexOf(':');
    if (colon <= 0) return;
    final identity = seriesIdentityOf(asuraSourceId, rest.substring(0, colon));
    final number = _chapterNumberOf(asuraSourceId, rest.substring(colon + 1));
    _asura[identity] = (_asura[identity] ?? const LocalReadMark())._with(number);
  }

  /// The mark for a followed series — on Asura matched on its identity, since
  /// the reader stores whatever key it was opened with and Browse opens this
  /// week's while the follow keeps the one it was made under.
  LocalReadMark? forFollow(FollowedSeries series) => of(
        sourceId: series.sourceId,
        seriesKey: series.seriesKey,
        identity: followIdentity(series),
      );

  /// The mark for `(sourceId, seriesKey)`, or null when this phone never
  /// opened a chapter of it. [identity] is the follow's, where known.
  LocalReadMark? of({
    required String sourceId,
    required String seriesKey,
    String? identity,
  }) {
    if (sourceId == asuraSourceId) {
      return _asura[identity ?? seriesIdentityOf(sourceId, seriesKey)];
    }
    final entries = _bySource[sourceId];
    if (entries == null) return null;
    final memoKey = '$sourceId:$seriesKey';
    if (_memo.containsKey(memoKey)) return _memo[memoKey];

    final prefix = '$seriesKey:';
    LocalReadMark? mark;
    for (final rest in entries) {
      if (!rest.startsWith(prefix)) continue;
      final number = _chapterNumberOf(sourceId, rest.substring(prefix.length));
      mark = (mark ?? const LocalReadMark())._with(number);
    }
    return _memo[memoKey] = mark;
  }
}

/// One mark per row of a shelf, compared by value.
///
/// A shelf resolves every row's line inside a lazy row builder, where nothing
/// can be watched, so it takes its marks in its own build — and selecting
/// this rather than watching [LocalReadMarks] whole rebuilds it only when a
/// row's answer moved, not on every page the reader records.
class ShelfReadMarks {
  ShelfReadMarks(LocalReadMarks marks, Iterable<FollowedSeries> shelf)
      : _byId = {for (final series in shelf) series.id: marks.forFollow(series)};

  final Map<int, LocalReadMark?> _byId;

  /// [series]' mark, or null for none (or a row this was not built over).
  LocalReadMark? of(FollowedSeries series) => _byId[series.id];

  @override
  bool operator ==(Object other) =>
      other is ShelfReadMarks &&
      const MapEquality<int, LocalReadMark?>().equals(other._byId, _byId);

  @override
  int get hashCode => const MapEquality<int, LocalReadMark?>().hash(_byId);
}
