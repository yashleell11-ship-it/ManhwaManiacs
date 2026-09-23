import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/library/widgets/library/continue_reading_strip.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/widgets/series_cover_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

ContinueReadingItem _item({
  String sourceId = 'asurascans',
  String seriesKey = 'series/one',
  String chapterKey = 'series/one/chapters/12',
  double? chapterNumber = 12,
  int lastPage = 7,
  int pageCount = 20,
  String? title,
  String? coverUrl,
}) =>
    ContinueReadingItem(
      sourceId: sourceId,
      seriesKey: seriesKey,
      chapterKey: chapterKey,
      chapterNumber: chapterNumber,
      lastPage: lastPage,
      pageCount: pageCount,
      title: title,
      coverUrl: coverUrl,
    );

FollowedSeries _follow({
  String sourceId = 'asurascans',
  required String seriesKey,
  required String title,
  String coverUrl = '',
}) =>
    FollowedSeries(
      id: 1,
      sourceId: sourceId,
      seriesKey: seriesKey,
      title: title,
      coverUrl: coverUrl,
      isFavorite: false,
      readingStatus: 'reading',
      notify: true,
      sortOrder: 0,
      contentRating: 'safe',
      rating: 'safe',
      chapterCount: 0,
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
  List<FollowedSeries> followed = const [],
}) async {
  // A card with art paints it through `SeriesCoverImage`, which reads the
  // active profile for its request headers — and that lives in preferences.
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: '/library',
    routes: [
      GoRoute(
        path: '/library',
        builder: (_, __) => Scaffold(
          body: ContinueReadingStrip(gutter: 16, followed: followed),
        ),
      ),
      // The real route patterns, taken from the app's own constants, so a
      // change to either can never leave this test asserting a path that no
      // longer exists while still passing.
      // Each echoes the location it was reached at too, so the position the
      // link carried can be asserted as well as the branch.
      GoRoute(
        path: Routes.reader,
        builder: (_, state) => Scaffold(
          body: Column(
            children: [const Text('PAGE READER'), Text('at ${state.uri}')],
          ),
        ),
      ),
      GoRoute(
        path: Routes.novelReader,
        builder: (_, state) => Scaffold(
          body: Column(
            children: [const Text('NOVEL READER'), Text('at ${state.uri}')],
          ),
        ),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiBaseUrlOverride('http://127.0.0.1:8000'),
        sharedPrefsProvider.overrideWithValue(prefs),
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

/// The URL every cover on screen was asked for.
List<String> _coverUrls(WidgetTester tester) => tester
    .widgetList<SeriesCoverImage>(find.byType(SeriesCoverImage))
    .map((cover) => cover.url)
    .toList();

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

    testWidgets('reopens a manga row at its stored page', (tester) async {
      // Neither reader restores a server-side position by itself, so a link
      // without `?page=` opened a chapter read on another device at page 1.
      await _pump(tester, items: [_item()]);

      await tester.tap(find.text('Page 7 of 20'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'at /library/read/asurascans/series%2Fone/'
          'series%2Fone%2Fchapters%2F12?page=7',
        ),
        findsOneWidget,
      );
    });

    testWidgets('reopens a novel row at its stored bucket', (tester) async {
      // The novel reader starts at the top of the chapter without `?page=`.
      await _pump(
        tester,
        items: [
          _item(
            sourceId: 'novelarchive',
            seriesKey: 'book',
            chapterKey: 'ch-3',
            lastPage: 60,
            pageCount: 100,
          ),
        ],
        mode: ContentMode.novel,
        index: const {'novelarchive': ContentMode.novel},
        novelsEnabled: true,
      );

      await tester.tap(find.text('60% through'));
      await tester.pumpAndSettle();

      expect(
        find.text('at /novels/read/novelarchive/book/ch-3?page=60'),
        findsOneWidget,
      );
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

  group('ContinueReadingStrip names the series', () {
    // "Chapter 94, page 3" alone does not say which of a dozen series a card
    // resumes: the title leads, with the chapter and page under it.
    testWidgets("leads with the payload's title", (tester) async {
      await _pump(tester, items: [_item(title: 'Solo Leveling')]);

      expect(find.text('Solo Leveling'), findsOneWidget);
      expect(find.text('Chapter 12 · Page 7 of 20'), findsOneWidget);
    });

    testWidgets('names the row from the followed list on an older server',
        (tester) async {
      // A server older than the `title` field sends none.
      await _pump(
        tester,
        items: [_item()],
        followed: [_follow(seriesKey: 'series/one', title: 'Tower of God')],
      );

      expect(find.text('Tower of God'), findsOneWidget);
      expect(find.text('Chapter 12 · Page 7 of 20'), findsOneWidget);
    });

    testWidgets('finds an Asura follow made under another slug suffix',
        (tester) async {
      // Progress is stored under the key the reader was opened with; Browse
      // opens this week's key while the follow keeps the one it was made
      // under.
      await _pump(
        tester,
        items: [
          _item(
            seriesKey: 'nano-machine-6f7fe6eb',
            chapterKey: 'nano-machine-6f7fe6eb:330',
            chapterNumber: 330,
          ),
        ],
        followed: [
          _follow(seriesKey: 'nano-machine-08677664', title: 'Nano Machine'),
        ],
      );

      expect(find.text('Nano Machine'), findsOneWidget);
      expect(find.text('Chapter 330 · Page 7 of 20'), findsOneWidget);
    });

    testWidgets('never matches another source on a look-alike key',
        (tester) async {
      // Only Asura rotates suffixes; elsewhere a different key is a different
      // series, and naming the row after it would open the wrong one's title.
      await _pump(
        tester,
        items: [_item(sourceId: 'mangadex', seriesKey: 'nano-6f7fe6eb')],
        followed: [
          _follow(
            sourceId: 'mangadex',
            seriesKey: 'nano-08677664',
            title: 'Wrong Series',
          ),
        ],
      );

      expect(find.text('Wrong Series'), findsNothing);
      expect(find.text('Chapter 12'), findsOneWidget);
      expect(find.text('Page 7 of 20'), findsOneWidget);
    });

    testWidgets("the payload's title wins over the follow's", (tester) async {
      await _pump(
        tester,
        items: [_item(title: 'Renamed Upstream')],
        followed: [_follow(seriesKey: 'series/one', title: 'Old Name')],
      );

      expect(find.text('Renamed Upstream'), findsOneWidget);
      expect(find.text('Old Name'), findsNothing);
    });

    testWidgets('an unnumbered chapter under a title shows just the position',
        (tester) async {
      // "Chapter · Page 7 of 20" says nothing the position does not.
      await _pump(
        tester,
        items: [_item(title: 'Solo Leveling', chapterNumber: null)],
      );

      expect(find.text('Solo Leveling'), findsOneWidget);
      expect(find.text('Page 7 of 20'), findsOneWidget);
    });

    testWidgets('a novel row keeps its percentage under the title',
        (tester) async {
      await _pump(
        tester,
        items: [
          _item(
            sourceId: 'novelarchive',
            title: 'Lord of the Mysteries',
            chapterNumber: 3,
            lastPage: 60,
            pageCount: 100,
          ),
        ],
        mode: ContentMode.novel,
        index: const {'novelarchive': ContentMode.novel},
        novelsEnabled: true,
      );

      expect(find.text('Lord of the Mysteries'), findsOneWidget);
      expect(find.text('Chapter 3 · 60% through'), findsOneWidget);
    });

    testWidgets("paints the payload's cover, resolved against the API",
        (tester) async {
      await _pump(
        tester,
        items: [
          _item(
            title: 'Solo Leveling',
            coverUrl: '/sources/asurascans/series/solo/cover',
          ),
        ],
        followed: [
          _follow(
            seriesKey: 'series/one',
            title: 'Solo Leveling',
            coverUrl: 'https://example.test/follow.jpg',
          ),
        ],
      );

      expect(
        _coverUrls(tester),
        ['http://127.0.0.1:8000/sources/asurascans/series/solo/cover'],
      );
    });

    testWidgets("falls back to the follow's cover, else paints none",
        (tester) async {
      await _pump(
        tester,
        items: [
          _item(),
          _item(seriesKey: 'series/two', chapterKey: 'series/two/chapters/3'),
        ],
        followed: [
          _follow(
            seriesKey: 'series/one',
            title: 'Tower of God',
            coverUrl: '/sources/asurascans/series/tog/cover',
          ),
        ],
      );

      // One card with art, one text-only: never a broken-image box.
      expect(
        _coverUrls(tester),
        ['http://127.0.0.1:8000/sources/asurascans/series/tog/cover'],
      );
    });
  });

  group('ContinueReadingItem.fromJson', () {
    Map<String, dynamic> row([Map<String, dynamic> extra = const {}]) => {
          'source_id': 'asurascans',
          'series_key': 'solo-6f7fe6eb',
          'chapter_key': 'solo-6f7fe6eb:12',
          'chapter_number': 12,
          'last_page': 7,
          'page_count': 20,
          'last_read_at': '2026-09-22T09:08:00Z',
          ...extra,
        };

    test('reads the title and cover the server joins from the follow', () {
      final item = ContinueReadingItem.fromJson(
        row({
          'title': 'Solo Leveling',
          'cover_url': '/sources/asurascans/series/solo-6f7fe6eb/cover',
        }),
      );

      expect(item.title, 'Solo Leveling');
      expect(item.coverUrl, '/sources/asurascans/series/solo-6f7fe6eb/cover');
    });

    test('tolerates a server that sends neither, or sends them empty', () {
      final older = ContinueReadingItem.fromJson(row());
      expect(older.title, isNull);
      expect(older.coverUrl, isNull);

      final blank = ContinueReadingItem.fromJson(
        row({'title': '  ', 'cover_url': null}),
      );
      expect(blank.title, isNull);
      expect(blank.coverUrl, isNull);
      expect(blank.chapterNumber, 12);
    });
  });
}
