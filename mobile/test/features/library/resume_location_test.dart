import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/library/utils/resume_location.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';

SourceChapterSummary _chapter(String id, double? number) => SourceChapterSummary(
      id: id,
      sourceId: 'asurascans',
      seriesId: 'orv',
      title: 'Chapter $id',
      number: number,
      pageCount: 0,
    );

void main() {
  group('resumePointFor', () {
    test('an unfinished chapter reopens at its stored position', () {
      expect(
        resumePointFor(chapterKey: 'c12', lastPage: 60, isCompleted: false),
        (chapterKey: 'c12', page: 60),
      );
    });

    test('an unfinished chapter never needs the chapter list', () {
      // The list is fetched only for finished rows; a mid-chapter row with no
      // list in hand must still resolve to itself.
      expect(
        resumePointFor(
          chapterKey: 'c12',
          lastPage: 7,
          isCompleted: false,
          chapters: [_chapter('c12', 12), _chapter('c13', 13)],
        ),
        (chapterKey: 'c12', page: 7),
      );
    });

    test('a stored position of 0 opens at page 1, not page 0', () {
      expect(
        resumePointFor(chapterKey: 'c1', lastPage: 0, isCompleted: false),
        (chapterKey: 'c1', page: 1),
      );
    });

    test('a finished chapter moves on to the next one, from the top', () {
      expect(
        resumePointFor(
          chapterKey: 'c12',
          lastPage: 40,
          isCompleted: true,
          chapters: [_chapter('c11', 11), _chapter('c12', 12), _chapter('c13', 13)],
        ),
        (chapterKey: 'c13', page: 1),
      );
    });

    test('"next" is the next NUMBER even when the source lists newest-first',
        () {
      // Listing order would make the chapter after c12 mean c11.
      expect(
        resumePointFor(
          chapterKey: 'c12',
          lastPage: 40,
          isCompleted: true,
          chapters: [_chapter('c13', 13), _chapter('c12', 12), _chapter('c11', 11)],
        ),
        (chapterKey: 'c13', page: 1),
      );
    });

    test('unnumbered extras sort after the numbered story', () {
      expect(
        resumePointFor(
          chapterKey: 'c2',
          lastPage: 9,
          isCompleted: true,
          chapters: [_chapter('omake', null), _chapter('c2', 2), _chapter('c3', 3)],
        ),
        (chapterKey: 'c3', page: 1),
      );
    });

    test('a finished LAST chapter has nothing to continue to', () {
      expect(
        resumePointFor(
          chapterKey: 'c13',
          lastPage: 40,
          isCompleted: true,
          chapters: [_chapter('c12', 12), _chapter('c13', 13)],
        ),
        isNull,
      );
    });

    test('a finished chapter the list no longer carries is not guessed at', () {
      expect(
        resumePointFor(
          chapterKey: 'gone',
          lastPage: 40,
          isCompleted: true,
          chapters: [_chapter('c12', 12), _chapter('c13', 13)],
        ),
        isNull,
      );
    });
  });

  group('resumeLocation', () {
    test('carries the stored page to the page reader', () {
      expect(
        resumeLocation(
          sourceId: 'asurascans',
          seriesKey: 'series/one',
          point: (chapterKey: 'series/one/12', page: 25),
          isNovel: false,
        ),
        '/library/read/asurascans/series%2Fone/series%2Fone%2F12?page=25',
      );
    });

    test("carries a novel's bucket to the novel reader as ?page=", () {
      expect(
        resumeLocation(
          sourceId: 'novelarchive',
          seriesKey: 'book',
          point: (chapterKey: 'ch-3', page: 60),
          isNovel: true,
        ),
        '/novels/read/novelarchive/book/ch-3?page=60',
      );
    });

    test('page 1 is the plain chapter path', () {
      expect(
        resumeLocation(
          sourceId: 'asurascans',
          seriesKey: 'orv',
          point: (chapterKey: 'c13', page: 1),
          isNovel: false,
        ),
        '/library/read/asurascans/orv/c13',
      );
    });
  });
}
