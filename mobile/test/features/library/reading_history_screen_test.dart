import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/library/models/reading_history_item.dart';
import 'package:manhwamaniacs/features/library/providers/intelligence_providers.dart';
import 'package:manhwamaniacs/features/library/screens/reading_history_screen.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/repositories/sources_repository.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

ReadingHistoryItem _row({
  String sourceId = 'asurascans',
  String seriesKey = 'orv',
  String chapterKey = 'c12',
  double chapterNumber = 12,
  int lastPage = 25,
  int pageCount = 40,
  bool isCompleted = false,
  String? coverUrl,
}) =>
    ReadingHistoryItem(
      id: 1,
      sourceId: sourceId,
      seriesKey: seriesKey,
      chapterKey: chapterKey,
      chapterNumber: chapterNumber,
      lastPage: lastPage,
      pageCount: pageCount,
      isCompleted: isCompleted,
      seriesTitle: 'Omniscient Reader',
      coverUrl: coverUrl,
    );

SourceChapterSummary _chapter(String id, double number) => SourceChapterSummary(
      id: id,
      sourceId: 'asurascans',
      seriesId: 'orv',
      title: 'Chapter $id',
      number: number,
      pageCount: 0,
    );

/// Only `getChapters` is reachable from the history screen; anything else
/// fails loudly through `noSuchMethod`.
class _FakeSources implements SourcesRepository {
  _FakeSources(this.chapters);

  final Result<List<SourceChapterSummary>> chapters;
  int chapterCalls = 0;

  @override
  Future<Result<List<SourceChapterSummary>>> getChapters(
    String sourceId,
    String seriesId,
  ) async {
    chapterCalls++;
    return chapters;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Pumps the screen behind a real GoRouter whose reader and series routes echo
/// the location they were reached at, so a test asserts the exact chapter and
/// position Continue opened rather than just which screen appeared.
Future<void> _pump(
  WidgetTester tester, {
  required List<ReadingHistoryItem> rows,
  _FakeSources? sources,
  Map<String, ContentMode> index = const {},
  ContentMode mode = ContentMode.manga,
  bool novelsEnabled = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  Widget echo(String label, GoRouterState state) =>
      Scaffold(body: Text('$label ${state.uri}'));
  final router = GoRouter(
    initialLocation: Routes.readingHistory,
    routes: [
      GoRoute(
        path: Routes.readingHistory,
        builder: (_, __) => const ReadingHistoryScreen(),
      ),
      GoRoute(path: Routes.reader, builder: (_, s) => echo('PAGE', s)),
      GoRoute(path: Routes.novelReader, builder: (_, s) => echo('NOVEL', s)),
      GoRoute(
        path: Routes.sourceSeriesDetail,
        builder: (_, s) => echo('SERIES', s),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiBaseUrlOverride('http://127.0.0.1:8000'),
        sharedPrefsProvider.overrideWithValue(prefs),
        activeProfileOverride(),
        readingHistoryProvider.overrideWith((ref) async => rows),
        sourcesRepositoryProvider
            .overrideWithValue(sources ?? _FakeSources(const Ok([]))),
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
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _tapContinue(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.play_arrow_rounded));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  group('ReadingHistoryScreen covers', () {
    testWidgets('a relative cover_url is loaded from the API host',
        (tester) async {
      // Production stores the backend's proxy PATH, not a URL. Handed to the
      // image loader unresolved it has no host and every tile is broken.
      await _pump(
        tester,
        rows: [_row(coverUrl: '/sources/asurascans/series/orv/cover')],
      );

      final image =
          tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
      expect(
        image.imageUrl,
        startsWith('http://127.0.0.1:8000/sources/asurascans/series/orv/cover'),
      );
    });
  });

  group('ReadingHistoryScreen Continue', () {
    testWidgets('an unfinished manga chapter reopens at its stored page',
        (tester) async {
      final sources = _FakeSources(const Ok([]));
      await _pump(tester, rows: [_row()], sources: sources);

      await _tapContinue(tester);

      expect(
        find.text('PAGE /library/read/asurascans/orv/c12?page=25'),
        findsOneWidget,
      );
      // A mid-chapter row is its own answer: no chapter list is fetched.
      expect(sources.chapterCalls, 0);
    });

    testWidgets('an unfinished novel chapter reopens at its stored bucket',
        (tester) async {
      await _pump(
        tester,
        rows: [
          _row(
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

      await _tapContinue(tester);

      expect(
        find.text('NOVEL /novels/read/novelarchive/book/ch-3?page=60'),
        findsOneWidget,
      );
    });

    testWidgets('a finished chapter moves on to the next one', (tester) async {
      await _pump(
        tester,
        rows: [_row(lastPage: 40, isCompleted: true)],
        sources: _FakeSources(
          Ok([_chapter('c13', 13), _chapter('c12', 12), _chapter('c11', 11)]),
        ),
      );

      await _tapContinue(tester);

      expect(find.text('PAGE /library/read/asurascans/orv/c13'), findsOneWidget);
    });

    testWidgets('a finished last chapter opens the book page instead',
        (tester) async {
      await _pump(
        tester,
        rows: [_row(lastPage: 40, isCompleted: true)],
        sources: _FakeSources(Ok([_chapter('c11', 11), _chapter('c12', 12)])),
      );

      await _tapContinue(tester);

      expect(find.text('SERIES /sources/asurascans/series/orv'), findsOneWidget);
    });

    testWidgets('a failed chapter list opens the book page, not the old chapter',
        (tester) async {
      await _pump(
        tester,
        rows: [_row(lastPage: 40, isCompleted: true)],
        sources: _FakeSources(const Err(TimeoutError())),
      );

      await _tapContinue(tester);

      expect(find.text('SERIES /sources/asurascans/series/orv'), findsOneWidget);
    });
  });
}
