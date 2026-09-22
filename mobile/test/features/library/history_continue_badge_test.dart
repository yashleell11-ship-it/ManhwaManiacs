/// The history shelf's play badge, while Continue is still working out where
/// to go.
///
/// Continue on a FINISHED chapter has to fetch the chapter list before it
/// knows what the next chapter is, and that request scrapes upstream. It used
/// to show nothing while it ran, so the badge looked dead — and a second tap
/// started a second fetch and pushed a second reader on top of the first.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/library/models/reading_history_item.dart';
import 'package:manhwamaniacs/features/library/widgets/history/history_series_card.dart';

import '../../support/test_overrides.dart';

final _finished = ReadingHistoryItem(
  id: 1,
  sourceId: 'asurascans',
  seriesKey: 'nano-machine',
  chapterKey: '210',
  chapterNumber: 210,
  lastPage: 24,
  pageCount: 24,
  isCompleted: true,
  lastReadAt: DateTime(2026, 9, 22),
  seriesTitle: 'Nano Machine',
);

Widget _card({required Future<void> Function() onContinue}) => ProviderScope(
      overrides: [apiBaseUrlOverride('https://app.example.test')],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            child: HistorySeriesCard(
              item: _finished,
              coverWidth: 160,
              onTap: () {},
              onContinue: onContinue,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('a second tap while Continue is working does nothing',
      (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      _card(
        onContinue: () {
          calls++;
          return pending.future;
        },
      ),
    );

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    // The badge now shows it is working, and the play icon it was tapped on
    // is gone, so there is nothing left to tap twice.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

    await tester.tap(find.byType(CircularProgressIndicator));
    await tester.pump();
    expect(calls, 1, reason: 'one tap, one chapter-list fetch, one reader');

    pending.complete();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });

  testWidgets('a failed Continue does not leave the badge stuck busy',
      (tester) async {
    // The screen's handler swallows its own request errors, but the badge
    // must recover even from one that escapes, or it is dead until restart.
    await tester.pumpWidget(
      _card(
        onContinue: () async {
          throw StateError('network');
        },
      ),
    );

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isA<StateError>());
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });
}
