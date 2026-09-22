import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/read_state.dart';
import 'package:manhwamaniacs/features/library/utils/read_state_label.dart';
import 'package:manhwamaniacs/features/library/widgets/home/followed_series_card.dart';

const _notStarted = ReadState(started: false, total: 120);

ReadState _started({
  double? chapterNumber = 5,
  int? position = 5,
  int total = 120,
  double? latestNumber = 120,
  int? newCount = 115,
}) =>
    ReadState(
      started: true,
      chapterKey: 'c5',
      chapterNumber: chapterNumber,
      position: position,
      total: total,
      latestNumber: latestNumber,
      newCount: newCount,
    );

FollowedSeries _series({
  ReadState? readState,
  int chapterCount = 120,
  String readingStatus = 'reading',
}) =>
    FollowedSeries(
      id: 1,
      sourceId: 'asurascans',
      seriesKey: 'solo-leveling',
      title: 'Solo Leveling',
      coverUrl: '',
      isFavorite: false,
      readingStatus: readingStatus,
      notify: true,
      sortOrder: 0,
      contentRating: 'safe',
      rating: 'safe',
      chapterCount: chapterCount,
      readState: readState,
    );

void main() {
  group('readStateLabel', () {
    test('a never-opened series is not started', () {
      expect(readStateLabel(_notStarted), 'Not started');
    });

    test('uses printed numbers when both ends have one', () {
      // A prologue puts the list one ahead of the printed numbers.
      expect(
        readStateLabel(
          _started(chapterNumber: 4, total: 121),
        ),
        'Ch 4 of 120',
      );
      expect(
        readStateLabel(_started(chapterNumber: 12.5, latestNumber: 30)),
        'Ch 12.5 of 30',
      );
    });

    test('falls back to list position when either end is unnumbered', () {
      expect(readStateLabel(_started(chapterNumber: null)), 'Ch 5 of 120');
      expect(readStateLabel(_started(latestNumber: null)), 'Ch 5 of 120');
    });

    test('never prints a chapter past the last one', () {
      expect(
        readStateLabel(
          _started(chapterNumber: 12, latestNumber: 10, total: 14),
        ),
        'Ch 5 of 14',
      );
    });

    test('names the chapter alone when the list no longer carries it', () {
      expect(
        readStateLabel(_started(position: null, chapterNumber: 7, newCount: null)),
        'Ch 7',
      );
      expect(
        readStateLabel(
          _started(position: null, chapterNumber: null, newCount: null),
        ),
        'Started',
      );
    });

    test('says nothing without a read state', () {
      expect(readStateLabel(null), isNull);
    });
  });

  group('new counts', () {
    test('count chapters past the furthest one opened', () {
      expect(readStateNewCount(_started(newCount: 2)), 2);
      expect(newCountBadgeText(2), '2 NEW');
      expect(newCountLabel(2), '2 new');
    });

    test('are zero for a series never started or with no known position', () {
      expect(readStateNewCount(_notStarted), 0);
      expect(readStateNewCount(_started(position: null, newCount: null)), 0);
      expect(readStateNewCount(null), 0);
      expect(newCountLabel(0), isNull);
    });

    test('cap the pill', () {
      expect(newCountBadgeText(3183), '99+ NEW');
      expect(newCountBadgeText(99), '99 NEW');
      expect(newCountLabel(3183), '99+ new');
    });

    test('the home pill counts reading, not notifications, once it can', () {
      expect(
        libraryCardNewCount(_notStarted, unreadNotifications: 3),
        0,
      );
      expect(
        libraryCardNewCount(_started(newCount: 2), unreadNotifications: 3),
        2,
      );
      expect(libraryCardNewCount(null, unreadNotifications: 3), 3);
    });
  });

  group('card lines', () {
    test('the grid label replaces the follow default "reading"', () {
      expect(progressCardLabel(_series(readState: _notStarted)), 'Not started');
      expect(
        progressCardLabel(_series(readState: _started(newCount: 1))),
        'Ch 5 of 120 · 1 new',
      );
      expect(progressCardLabel(_series()), 'reading');
    });

    test('the list row replaces the bare chapter count', () {
      expect(seriesCardMeta(_series(readState: _notStarted)), 'Not started');
      expect(seriesCardMeta(_series(chapterCount: 40)), '40 chapters');
    });

    test('the home card subtitle prefers the read state', () {
      const meta = FollowedSeriesMeta(
        unreadCount: 2,
        latestChapterLabel: 'Chapter 121',
      );
      expect(
        followedSeriesCardSubtitle(_series(readState: _notStarted), meta),
        'Not started',
      );
      expect(
        followedSeriesCardSubtitle(_series(readState: _started()), meta),
        'Ch 5 of 120',
      );
      expect(followedSeriesCardSubtitle(_series(), meta), 'Latest: Chapter 121');
    });
  });

  test('read_state survives the offline library cache round trip', () {
    final json = _series(readState: _started(newCount: 3)).toJson();
    final back = FollowedSeries.fromJson(json).readState;

    expect(back, isNotNull);
    expect(back!.started, isTrue);
    expect(back.position, 5);
    expect(back.chapterNumber, 5);
    expect(back.latestNumber, 120);
    expect(back.newCount, 3);
  });

  test('parses the server payload, integer numbers included', () {
    final series = FollowedSeries.fromJson({
      'id': 1,
      'source_id': 'asurascans',
      'series_key': 'solo-leveling',
      'title': 'Solo Leveling',
      'chapter_count': 120,
      'read_state': {
        'started': true,
        'chapter_key': 'c4',
        'chapter_number': 4,
        'position': 5,
        'total': 121,
        'latest_number': 120,
        'new_count': 116,
      },
    });

    expect(readStateLabel(series.readState), 'Ch 4 of 120');
    expect(readStateNewCount(series.readState), 116);
    final legacy = FollowedSeries.fromJson({
      'id': 2,
      'source_id': 's',
      'series_key': 'k',
      'title': 't',
    });
    expect(legacy.readState, isNull);
  });
}
