import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/utils/local_read_marks.dart';
import 'package:manhwamaniacs/features/library/utils/series_identity.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';

SourceChapterProgress _read({int page = 3}) => SourceChapterProgress(
      page: page,
      pageCount: 20,
      completed: false,
      updatedAt: DateTime.utc(2026, 9, 20),
    );

/// A store record under the reader's own key shape.
MapEntry<String, SourceChapterProgress> _record(
  String sourceId,
  String seriesId,
  String chapterId,
) =>
    MapEntry(
      sourceProgressKey(
        sourceId: sourceId,
        seriesId: seriesId,
        chapterId: chapterId,
      ),
      _read(),
    );

LocalReadMarks _marks(List<MapEntry<String, SourceChapterProgress>> records) =>
    LocalReadMarks(Map.fromEntries(records));

FollowedSeries _follow({
  String sourceId = 'asurascans',
  required String seriesKey,
  String? seriesIdentity,
}) =>
    FollowedSeries(
      id: 1,
      sourceId: sourceId,
      seriesKey: seriesKey,
      seriesIdentity: seriesIdentity,
      title: 't',
      coverUrl: '',
      isFavorite: false,
      readingStatus: 'reading',
      notify: true,
      sortOrder: 0,
      contentRating: 'safe',
      rating: 'safe',
      chapterCount: 0,
    );

void main() {
  group('seriesIdentityOf', () {
    test("takes Asura's rotating suffix off, and nothing else's", () {
      expect(
        seriesIdentityOf('asurascans', 'nano-machine-6f7fe6eb'),
        'nano-machine',
      );
      expect(
        seriesIdentityOf('asurascans', ' /nano-machine-08677664/ '),
        'nano-machine',
      );
      expect(seriesIdentityOf('asurascans', 'solo-leveling'), 'solo-leveling');
      expect(
        seriesIdentityOf('mangadex', 'nano-machine-6f7fe6eb'),
        'nano-machine-6f7fe6eb',
      );
    });
  });

  group('LocalReadMarks', () {
    test('an Asura series: the furthest chapter number among those opened', () {
      final marks = _marks([
        _record('asurascans', 'surviving-6f7fe6eb', 'surviving-6f7fe6eb:93'),
        _record('asurascans', 'surviving-6f7fe6eb', 'surviving-6f7fe6eb:94'),
        _record('asurascans', 'surviving-6f7fe6eb', 'surviving-6f7fe6eb:9'),
      ]);

      expect(
        marks.forFollow(_follow(seriesKey: 'surviving-6f7fe6eb')),
        const LocalReadMark(chapterNumber: 94),
      );
    });

    test('finds chapters read under another Asura slug suffix', () {
      // The follow keeps the key it was made under; Browse opens this week's.
      final marks = _marks([
        _record('asurascans', 'nano-machine-6f7fe6eb', 'nano-machine-6f7fe6eb:330'),
        _record('asurascans', 'nano-machine-08677664', 'nano-machine-08677664:12'),
        // A different series that merely starts the same way.
        _record('asurascans', 'nano-machine-2-6f7fe6eb', 'nano-machine-2-6f7fe6eb:900'),
      ]);

      expect(
        marks.forFollow(
          _follow(seriesKey: 'nano-machine-05c7df14', seriesIdentity: 'nano-machine'),
        ),
        const LocalReadMark(chapterNumber: 330),
      );
      // A cache written before the server sent identities: the same rule here.
      expect(
        marks.forFollow(_follow(seriesKey: 'nano-machine-05c7df14')),
        const LocalReadMark(chapterNumber: 330),
      );
    });

    test('a source whose keys do not drift matches on the exact key only', () {
      final marks = _marks([
        _record('mangadex', 'abc', 'chapter-uuid-1'),
        _record('mangadex', 'abcdef', 'chapter-uuid-2'),
      ]);

      // Opened, but a UUID says no number: the card says "Started".
      expect(
        marks.of(sourceId: 'mangadex', seriesKey: 'abc'),
        const LocalReadMark(),
      );
      expect(marks.of(sourceId: 'mangadex', seriesKey: 'ab'), isNull);
      expect(marks.of(sourceId: 'mangadex', seriesKey: 'xyz'), isNull);
    });

    test('never reads a number off a key that is not a chapter number', () {
      // Tapas' `<slug>:<n>` is an episode id: "Ch 2291841" would be a lie.
      final marks = _marks([
        _record('tapas', 'some-comic', 'some-comic:2291841'),
      ]);

      expect(
        marks.of(sourceId: 'tapas', seriesKey: 'some-comic'),
        const LocalReadMark(),
      );
    });

    test('nothing opened on this phone is no mark at all', () {
      expect(
        LocalReadMarks.empty.forFollow(_follow(seriesKey: 'x-6f7fe6eb')),
        isNull,
      );
      final other = _marks([
        _record('asurascans', 'other-6f7fe6eb', 'other-6f7fe6eb:4'),
      ]);
      expect(other.forFollow(_follow(seriesKey: 'x-6f7fe6eb')), isNull);
      expect(
        other.of(sourceId: 'demonicscans', seriesKey: 'other-6f7fe6eb'),
        isNull,
      );
    });
  });

  group('ShelfReadMarks', () {
    // A shelf selects this so the reader's page turns rebuild it only when a
    // row's answer actually moved.
    final shelf = [
      _follow(seriesKey: 'surviving-6f7fe6eb'),
      FollowedSeries.fromJson({
        'id': 2,
        'source_id': 'asurascans',
        'series_key': 'never-opened-6f7fe6eb',
        'title': 'Never Opened',
      }),
    ];

    test('another page of the same chapter is the same shelf', () {
      final before = ShelfReadMarks(
        _marks([_record('asurascans', 'surviving-6f7fe6eb', 'surviving-6f7fe6eb:94')]),
        shelf,
      );
      final after = ShelfReadMarks(
        LocalReadMarks({
          sourceProgressKey(
            sourceId: 'asurascans',
            seriesId: 'surviving-6f7fe6eb',
            chapterId: 'surviving-6f7fe6eb:94',
          ): _read(page: 9),
        }),
        shelf,
      );

      expect(after, before);
      expect(after.hashCode, before.hashCode);
      expect(after.of(shelf.first), const LocalReadMark(chapterNumber: 94));
      expect(after.of(shelf.last), isNull);
    });

    test('a new chapter is a different shelf', () {
      final before = ShelfReadMarks(
        _marks([_record('asurascans', 'surviving-6f7fe6eb', 'surviving-6f7fe6eb:94')]),
        shelf,
      );
      final after = ShelfReadMarks(
        _marks([
          _record('asurascans', 'surviving-6f7fe6eb', 'surviving-6f7fe6eb:94'),
          _record('asurascans', 'surviving-6f7fe6eb', 'surviving-6f7fe6eb:95'),
        ]),
        shelf,
      );

      expect(after == before, isFalse);
      expect(after.of(shelf.first), const LocalReadMark(chapterNumber: 95));
    });
  });
}
