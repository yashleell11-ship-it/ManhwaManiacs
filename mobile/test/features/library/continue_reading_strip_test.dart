import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/library/widgets/library/continue_reading_strip.dart';

ContinueReadingItem _item({
  String sourceId = 'asurascans',
  String seriesKey = 'series/one',
  String chapterKey = 'series/one/chapters/12',
  double? chapterNumber = 12,
  int lastPage = 7,
  int pageCount = 20,
}) =>
    ContinueReadingItem(
      sourceId: sourceId,
      seriesKey: seriesKey,
      chapterKey: chapterKey,
      chapterNumber: chapterNumber,
      lastPage: lastPage,
      pageCount: pageCount,
    );

/// Pumps the strip behind a real GoRouter, with a fixed set of rows and a fixed
/// source-mode index. The router is real because the card navigates with
/// `context.push`, which is go_router's — a bare MaterialApp throws on tap.
///
/// Both reader routes resolve to a stub that echoes which one was reached, so a
/// test asserts the BRANCH rather than a URL string.
Future<void> _pump(
  WidgetTester tester, {
  required List<ContinueReadingItem> items,
  ContentMode mode = ContentMode.manga,
  Map<String, ContentMode> index = const {},
  bool novelsEnabled = false,
}) async {
  final router = GoRouter(
    initialLocation: '/library',
    routes: [
      GoRoute(
        path: '/library',
        builder: (_, __) => const Scaffold(body: ContinueReadingStrip(gutter: 16)),
      ),
      // The real route patterns, taken from the app's own constants, so a
      // change to either can never leave this test asserting a path that no
      // longer exists while still passing.
      GoRoute(
        path: Routes.reader,
        builder: (_, __) => const Scaffold(body: Text('PAGE READER')),
      ),
      GoRoute(
        path: Routes.novelReader,
        builder: (_, __) => const Scaffold(body: Text('NOVEL READER')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        continueReadingProvider.overrideWith((ref) async => items),
        contentModeScopeProvider.overrideWithValue(
          ContentModeScope(
            mode: mode,
            index: index,
            novelsEnabled: novelsEnabled,
          ),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('ContinueReadingStrip', () {
    testWidgets('shows nothing at all before the request lands', (tester) async {
      // A resume shortcut that renders a spinner above the shelf is worse than
      // no shortcut: it delays the content the tab is actually for.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // A request that never answers — a Completer rather than a
            // delayed Future, which would leave a pending timer at teardown.
            continueReadingProvider.overrideWith(
              (ref) => Completer<List<ContinueReadingItem>>().future,
            ),
            contentModeScopeProvider.overrideWithValue(
              const ContentModeScope(
                mode: ContentMode.manga,
                index: {},
                novelsEnabled: false,
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ContinueReadingStrip(gutter: 16)),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Continue reading'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows nothing when the profile has read nothing', (tester) async {
      await _pump(tester, items: const []);

      expect(find.text('Continue reading'), findsNothing);
    });

    testWidgets('shows a row per part-read chapter', (tester) async {
      await _pump(
        tester,
        items: [
          _item(),
          _item(seriesKey: 'series/two', chapterNumber: 3),
        ],
      );

      expect(find.text('Continue reading'), findsOneWidget);
      expect(find.text('Page 7 of 20'), findsNWidgets(2));
    });

    testWidgets('opens the PAGE reader for a manga row', (tester) async {
      await _pump(tester, items: [_item()]);

      await tester.tap(find.text('Page 7 of 20'));
      await tester.pumpAndSettle();

      expect(find.text('PAGE READER'), findsOneWidget);
    });

    testWidgets('opens the NOVEL reader for a novel row', (tester) async {
      // The row carries a source id and no kind, so the kind comes from the
      // source-mode index. Getting this wrong opens a novel in the page reader.
      await _pump(
        tester,
        items: [_item(sourceId: 'novelarchive')],
        // Novels mode, or the scope filter drops the row before it can render.
        mode: ContentMode.novel,
        index: const {'novelarchive': ContentMode.novel},
        novelsEnabled: true,
      );

      await tester.tap(find.textContaining('%'));
      await tester.pumpAndSettle();

      expect(find.text('NOVEL READER'), findsOneWidget);
    });

    testWidgets('never puts a page count on a novel row', (tester) async {
      // A novel's stored last_page is a progress BUCKET (1-100), not a page,
      // so "Page 7 of 20" there would be a number the reader cannot act on.
      await _pump(
        tester,
        items: [_item(sourceId: 'novelarchive', lastPage: 40, pageCount: 100)],
        mode: ContentMode.novel,
        index: const {'novelarchive': ContentMode.novel},
        novelsEnabled: true,
      );

      expect(find.textContaining('Page'), findsNothing);
      expect(find.text('40% through'), findsOneWidget);
    });

    testWidgets('in Novels mode a half-read manhwa chapter is not on the shelf',
        (tester) async {
      await _pump(
        tester,
        items: [
          _item(),
          _item(sourceId: 'novelarchive', seriesKey: 'book/one'),
        ],
        mode: ContentMode.novel,
        index: const {
          'asurascans': ContentMode.manga,
          'novelarchive': ContentMode.novel,
        },
        novelsEnabled: true,
      );

      expect(find.text('Continue reading'), findsOneWidget);
      expect(find.textContaining('Page'), findsNothing);
    });

    testWidgets('a failed request is silent, not an error above the shelf',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            continueReadingProvider.overrideWith(
              (ref) => Future<List<ContinueReadingItem>>.error(
                Exception('offline'),
              ),
            ),
            contentModeScopeProvider.overrideWithValue(
              const ContentModeScope(
                mode: ContentMode.manga,
                index: {},
                novelsEnabled: false,
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ContinueReadingStrip(gutter: 16)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Continue reading'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
