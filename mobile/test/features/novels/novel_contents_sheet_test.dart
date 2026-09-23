/// The book's contents sheet: the reader's Contents button and the book
/// page's "Go to chapter".
///
/// Two outcomes matter. It opens AT the chapter being read — row 500 of 532
/// is on screen and row 1 is not even built, because a 3,188-chapter book
/// cannot afford to lay out every row to find one. And a typed number finds
/// chapters by the number their title prints, every one of them: TBATE's
/// rows 531 and 532 are both "Chapter 529".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/app/theme/app_theme.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_chapter_view.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_contents_sheet.dart';

import '../../support/reading_navigation_cases.dart';

const _surface = NovelSurfaceColors(
  bg: Colors.white,
  ink: Colors.black,
  muted: Colors.grey,
  isDark: false,
);

Future<List<String>> _open(WidgetTester tester, {String? current}) async {
  final opened = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.fromPalette(AppPalettes.defaultPalette),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => NovelContentsSheet.show(
                context,
                sourceId: 'novelbin',
                seriesKey: 'tbate',
                chapters: caseBook('tbate'),
                currentChapterKey: current,
                surface: _surface,
                onOpen: opened.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  testWidgets('opens at the chapter being read, without building the rest',
      (tester) async {
    await _open(tester, current: '500');

    expect(find.byKey(const Key('contents-500')), findsOneWidget);
    expect(find.byKey(const Key('contents-1')), findsNothing);
  });

  testWidgets('a typed number lists every chapter that prints it, by row',
      (tester) async {
    final opened = await _open(tester, current: '500');

    await tester.enterText(find.byKey(const Key('contents-go-to')), '529');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('contents-531')), findsOneWidget);
    expect(find.byKey(const Key('contents-532')), findsOneWidget);
    // Key 529 prints "Chapter 527": the number typed is never a key.
    expect(find.byKey(const Key('contents-529')), findsNothing);

    await tester.tap(find.byKey(const Key('contents-532')));
    await tester.pumpAndSettle();

    expect(opened, ['532']);
    expect(find.byKey(const Key('contents-go-to')), findsNothing);
  });

  testWidgets('says so when the book has no such chapter', (tester) async {
    await _open(tester);

    await tester.enterText(find.byKey(const Key('contents-go-to')), '9999');
    await tester.pumpAndSettle();

    expect(find.text('No chapter 9999 in this book.'), findsOneWidget);
  });
}
