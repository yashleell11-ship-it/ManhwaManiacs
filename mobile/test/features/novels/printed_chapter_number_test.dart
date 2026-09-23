import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_book.dart';

import '../../support/reading_navigation_cases.dart';

void main() {
  // The same table the web's `book.ts` answers
  // (backend/tests/fixtures/reading_navigation_cases.json).
  group('printedChapterNumber', () {
    for (final raw in (readingNavigationCases['printed_numbers'] as List<dynamic>)
        .cast<Map<String, dynamic>>()) {
      final title = raw['title'] as String;
      final number = (raw['number'] as num?)?.toDouble();
      final expected = (raw['expect'] as num?)?.toDouble();
      test('reads "$title" (row $number) as $expected', () {
        expect(printedChapterNumber(title: title, number: number), expected);
      });
    }
  });

  group('goToChapterMatches', () {
    for (final raw in (readingNavigationCases['goto'] as List<dynamic>)
        .cast<Map<String, dynamic>>()) {
      final book = raw['book'] as String;
      final query = raw['query'] as String;
      final keys = (raw['expect'] as List<dynamic>).cast<String>();
      test('finds "$query" in $book at rows $keys', () {
        expect(
          goToChapterMatches(caseBook(book), query).map((c) => c.id).toList(),
          keys,
        );
      });
    }

    test('never lands on the key that merely equals the typed number', () {
      // TBATE key 120 is printed "Chapter 118"; a number filter over keys
      // would open it for "120" — two chapters short.
      final matches = goToChapterMatches(caseBook('tbate'), '120');
      expect(matches.map((c) => c.title).toList(), ['Chapter 120']);
      expect(matches.map((c) => c.id), isNot(contains('120')));
    });

    test('answers in reading order however the source listed them', () {
      final reversed = caseBook('tbate').reversed.toList();
      expect(
        goToChapterMatches(reversed, '529').map((c) => c.id).toList(),
        ['531', '532'],
      );
    });
  });

  group('contentsScrollOffset', () {
    test('opens deep in a long book without measuring anything', () {
      // Shadow Slave row 3,000 at 52 px a row, two rows of context above.
      expect(contentsScrollOffset(2999, 52), 2997 * 52);
    });

    test('never scrolls above the first row', () {
      expect(contentsScrollOffset(1, 52), 0);
      expect(contentsScrollOffset(-1, 52), 0);
    });
  });
}
