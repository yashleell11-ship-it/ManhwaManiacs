import 'dart:convert';
import 'dart:io';

import 'package:manhwamaniacs/features/sources/models/source_series.dart';

/// The shared Continue / "Go to chapter" table, as the phone's tests read it.
///
/// One JSON file is read by the backend, the web and the phone, so the
/// continue-reading strip, both clients' series pages and the history shelf
/// cannot quietly answer the same reading history differently again — which
/// is how four resume rules came to exist in the first place. Tests run from
/// `mobile/`, the same assumption `mature_invalidators_test.dart` makes.
final Map<String, dynamic> readingNavigationCases = jsonDecode(
  File('../backend/tests/fixtures/reading_navigation_cases.json')
      .readAsStringSync(),
) as Map<String, dynamic>;

/// A fixture book as the chapter list the source endpoint serves.
List<SourceChapterSummary> caseBook(String name) {
  final books = readingNavigationCases['books'] as Map<String, dynamic>;
  final book = books[name] as List<dynamic>;
  return [
    for (final raw in book.cast<Map<String, dynamic>>())
      SourceChapterSummary(
        id: raw['key'] as String,
        sourceId: 'fixture',
        seriesId: name,
        title: raw['title'] as String,
        number: (raw['number'] as num?)?.toDouble(),
        pageCount: 0,
      ),
  ];
}
