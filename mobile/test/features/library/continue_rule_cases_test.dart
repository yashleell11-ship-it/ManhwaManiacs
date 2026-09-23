import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/library/utils/resume_location.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';

import '../../support/reading_navigation_cases.dart';

/// The server's rows for one case, as `GET /reader/progress/series` hands
/// them over.
List<ReadingProgress> _serverRows(List<dynamic> rows) => [
      for (final (index, raw) in rows.cast<Map<String, dynamic>>().indexed)
        ReadingProgress(
          id: index + 1,
          sourceId: 'fixture',
          seriesKey: 'book',
          chapterKey: raw['chapter_key'] as String,
          chapterNumber: (raw['chapter_number'] as num?)?.toDouble(),
          lastPage: raw['last_page'] as int,
          pageCount: raw['page_count'] as int,
          scrollOffsetPx: 0,
          isCompleted: raw['is_completed'] as bool,
          lastReadAt: DateTime.parse('${raw['last_read_at']}Z'),
          timeSpentSeconds: 0,
        ),
    ];

SourceChapterProgress _local(
  int page,
  int pageCount, {
  bool completed = false,
  required DateTime at,
}) =>
    SourceChapterProgress(
      page: page,
      pageCount: pageCount,
      completed: completed,
      updatedAt: at,
    );

void main() {
  // The same table the server's strip and the web's series pages answer
  // (backend/tests/fixtures/reading_navigation_cases.json).
  group('seriesContinue answers the shared table', () {
    for (final raw in (readingNavigationCases['continue'] as List<dynamic>)
        .cast<Map<String, dynamic>>()) {
      test(raw['name'] as String, () {
        final chapters = caseBook(raw['book'] as String);
        final progress = mergeSourceProgress(
          const {},
          serverProgressMap(_serverRows(raw['progress'] as List<dynamic>)),
        );

        final answer = seriesContinue(chapters: chapters, progress: progress);

        final expected = raw['expect'];
        if (expected == 'caught_up') {
          expect(answer, (kind: SeriesContinueKind.caughtUp, point: null));
        } else if (expected == 'start') {
          expect(
            answer,
            (
              kind: SeriesContinueKind.start,
              point: (chapterKey: chapters.first.id, page: 1),
            ),
          );
        } else {
          final want = expected as Map<String, dynamic>;
          expect(
            answer,
            (
              kind: SeriesContinueKind.resume,
              point: (
                chapterKey: want['chapter_key'] as String,
                page: want['page'] as int,
              ),
            ),
          );
        }
      });
    }
  });

  group('seriesContinue', () {
    final book = caseBook('short');

    test('is null for a series with no chapters', () {
      expect(seriesContinue(chapters: const [], progress: const {}), isNull);
    });

    test('ignores a position for a chapter the list no longer carries', () {
      expect(
        seriesContinue(
          chapters: book,
          progress: {
            'gone': _local(9, 20, at: DateTime.utc(2026, 9, 20)),
            'a': _local(3, 20, at: DateTime.utc(2026, 9)),
          },
        ),
        (kind: SeriesContinueKind.resume, point: (chapterKey: 'a', page: 3)),
      );
    });
  });

  group('mergeSourceProgress', () {
    test('a newer page on this phone is not rewound by the server', () {
      // The manga reader writes here on every page; the server hears only
      // when the outbox flushes.
      final merged = mergeSourceProgress(
        {'c5': _local(14, 20, at: DateTime.utc(2026, 9, 21, 10))},
        {'c5': _local(9, 20, at: DateTime.utc(2026, 9, 21, 9))},
      );
      expect(merged['c5']!.page, 14);
      expect(merged['c5']!.updatedAt, DateTime.utc(2026, 9, 21, 10));
    });

    test('finishing on either side sticks', () {
      final merged = mergeSourceProgress(
        {'c5': _local(20, 20, completed: true, at: DateTime.utc(2026, 9))},
        {'c5': _local(3, 20, at: DateTime.utc(2026, 9, 2))},
      );
      expect(merged['c5']!.completed, isTrue);
      expect(merged['c5']!.page, 20);
    });

    test('a book read only on the web or in the novel reader still shows', () {
      // Neither writes this phone's store; the series page used to read only
      // that store and offered "Start reading" 122 chapters in.
      final merged = mergeSourceProgress(
        const {},
        {'122': _local(55, 55, completed: true, at: DateTime.utc(2026, 9, 19))},
      );
      expect(
        seriesContinue(chapters: caseBook('tbate'), progress: merged),
        (kind: SeriesContinueKind.resume, point: (chapterKey: '123', page: 1)),
      );
    });
  });
}
