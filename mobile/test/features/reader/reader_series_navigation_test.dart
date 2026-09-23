import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/app.dart';
import 'package:manhwamaniacs/app/router/app_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/providers/library_read_state.dart';
import 'package:manhwamaniacs/features/library/providers/series_detail_provider.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest_window.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/providers/reader_chapter_provider.dart';
import 'package:manhwamaniacs/features/reader/repositories/reader_repository.dart';
import 'package:manhwamaniacs/features/reader/screens/reader_screen.dart';
import 'package:manhwamaniacs/features/sources/providers/source_reader_provider.dart';
import 'package:manhwamaniacs/features/sources/providers/sources_provider.dart';
import 'package:manhwamaniacs/features/sources/screens/source_reader_screen.dart';
import 'package:manhwamaniacs/features/sources/screens/source_series_detail_screen.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

// A connector series id with a `/` in it — the exact shape that forced
// RoutePaths to percent-encode. Every assertion below re-reads the id off the
// destination screen rather than off the location string, because go_router
// spells the same id encoded or decoded depending on how it was reached.
const _slashSeriesId = 'toonily/series-a';
const _slashChapterId = 'toonily/series-a/ch-1';
const _followedId = 7;

/// The manifest-driven reader (followed series) reads from the same
/// `(sourceId, seriesKey)` pair as the source-browse reader — a different
/// connector here just to keep the two apart in assertions.
const _libSourceId = 'mangadex';
const _libSeriesKey = 'solo-leveling';
const _libChapterKey = '1';

/// A madara-shaped chapter key — every toonily/madara chapter id looks like
/// `series-slug/chapter-n`. The library reader route's `:seriesKey` /
/// `:chapterKey` params each match ONE path segment, so RoutePaths.reader must
/// whole-key percent-encode (a raw `/` would grow the location an extra
/// segment and never match the route).
const _slashLibChapterKey = 'solo-leveling/chapter-2';

ChapterManifest _libManifest() => const ChapterManifest(
      sourceId: _libSourceId,
      seriesKey: _libSeriesKey,
      chapterKey: _libChapterKey,
      chapterNumber: 1,
      pageCount: 2,
      prev: null,
      next: null,
      pages: [
        ManifestPage(number: 1, url: '/sources/$_libSourceId/pages/p1/image'),
        ManifestPage(number: 2, url: '/sources/$_libSourceId/pages/p2/image'),
      ],
    );

ChapterManifest _sourceChapterManifest() => const ChapterManifest(
      sourceId: 'toonily',
      seriesKey: _slashSeriesId,
      chapterKey: _slashChapterId,
      chapterNumber: 1,
      pageCount: 2,
      prev: null,
      next: null,
      pages: [
        ManifestPage(number: 1, url: '/sources/toonily/pages/p1/image'),
        ManifestPage(number: 2, url: '/sources/toonily/pages/p2/image'),
      ],
    );

/// The manifest reader flushes reading progress from its `dispose()` — which
/// is exactly what the jump to the series page triggers. Through the real
/// repository that becomes an HTTP request whose timeout Timer outlives the
/// test, so serve it locally instead. Every other call is out of scope here
/// and `noSuchMethod` says so loudly rather than quietly returning nothing.
class _ProgressOnlyReaderRepository implements ReaderRepository {
  @override
  Future<Result<ReadingProgress>> saveProgress(ProgressPush push) async => Ok(
        ReadingProgress(
          id: 1,
          sourceId: push.sourceId,
          seriesKey: push.seriesKey,
          chapterKey: push.chapterKey,
          chapterNumber: push.chapterNumber,
          lastPage: push.lastPage,
          pageCount: push.pageCount,
          scrollOffsetPx: push.scrollOffsetPx,
          isCompleted: push.isCompleted,
          timeSpentSeconds: push.timeSpentSeconds,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<Result<ChapterManifestWindow>> manifestWindow({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) =>
      throw UnimplementedError();
}

/// The source-browse reader pushes through the same progress outbox, which
/// with no downloads store has nowhere to queue a row and so makes no request
/// — no repository override is needed for it.

/// Closing either reader refreshes the Library tab's shelves, which in the
/// real app mounted here are alive — through the real repository, a request
/// whose Timer outlives the test. Which route the jump lands on is all these
/// tests are about.
class _NoShelfRefresh extends LibraryReadState {
  _NoShelfRefresh(super.ref);

  @override
  void refresh() {}
}

/// Series-detail payloads are irrelevant here — only the route we land on is.
/// A completer that never completes parks each destination on its skeleton
/// without leaving a pending Timer behind to fail teardown.
List<Override> _pendingSeriesDetails() => [
      seriesDetailProvider(_followedId)
          .overrideWith((ref) => Completer<SeriesDetailView>().future),
      sourceSeriesDetailProvider(
        (sourceId: _libSourceId, seriesId: _libSeriesKey),
      ).overrideWith((ref) => Completer<SourceSeriesDetailData>().future),
      sourceSeriesDetailProvider(
        (sourceId: 'toonily', seriesId: _slashSeriesId),
      ).overrideWith((ref) => Completer<SourceSeriesDetailData>().future),
    ];

/// Mounts the real app — real router, real route table — so these tests prove
/// the routes the app actually ships, not a stand-in copy of them.
Future<ProviderContainer> _pumpApp(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  SharedPreferences.setMockInitialValues(testPrefsDefaults());
  final prefs = await SharedPreferences.getInstance();

  final container = ProviderContainer(
    overrides: [
      apiBaseUrlOverride('http://example.test'),
      sharedPrefsProvider.overrideWithValue(prefs),
      readerRepositoryProvider
          .overrideWithValue(_ProgressOnlyReaderRepository()),
      libraryReadStateProvider.overrideWith(_NoShelfRefresh.new),
      authenticatedAuthOverride(),
      activeProfileOverride(),
      ...noDownloadsStoreOverrides(),
      profileSessionReadyOverride(),
      chapterManifestProvider(
        (
          sourceId: _libSourceId,
          seriesKey: _libSeriesKey,
          chapterKey: _libChapterKey
        ),
      ).overrideWith((ref) async => _libManifest()),
      chapterManifestProvider(
        (
          sourceId: _libSourceId,
          seriesKey: _libSeriesKey,
          chapterKey: _slashLibChapterKey,
        ),
      ).overrideWith((ref) async => _libManifest()),
      sourceReaderPayloadProvider(
        (
          sourceId: 'toonily',
          seriesId: _slashSeriesId,
          chapterId: _slashChapterId,
        ),
      ).overrideWith((ref) async =>
          _sourceChapterManifest().toReaderChapter('http://example.test'),),
      ..._pendingSeriesDetails(),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const ManhwaManiacsApp(),
    ),
  );
  await tester.pump();
  return container;
}

GoRouter _router(ProviderContainer container) =>
    container.read(appRouterProvider);

/// The matched route *pattern* rather than the location string: go_router
/// spells a slash-bearing series id encoded or decoded depending on whether the
/// route was reached by push or pop, but the pattern is stable either way.
String _fullPath(GoRouter router) =>
    router.routerDelegate.currentConfiguration.fullPath;

Future<void> _settleReader(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Taps the chapter title in the reader's top bar — the affordance itself.
Future<void> _tapTitle(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Go to series'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Reader → series page', () {
    testWidgets('a followed-series chapter lands on the source series route',
        (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      router.go(RoutePaths.reader(_libSourceId, _libSeriesKey, _libChapterKey));
      await _settleReader(tester);
      expect(find.byType(ReaderScreen), findsOneWidget);

      await _tapTitle(tester);

      expect(_fullPath(router), Routes.sourceSeriesDetail);
      expect(find.byType(ReaderScreen), findsNothing);
      final series = tester.widget<SourceSeriesDetailScreen>(
        find.byType(SourceSeriesDetailScreen),
      );
      expect(series.sourceId, _libSourceId);
      expect(series.seriesId, _libSeriesKey);
    });

    testWidgets(
        'the library reader route matches a slash-bearing chapter key '
        'and hands the decoded key to the screen', (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      router.go(
        RoutePaths.reader(_libSourceId, _libSeriesKey, _slashLibChapterKey),
      );
      await _settleReader(tester);

      // A raw `/` in the location would have failed to match the route at all
      // (error screen, no ReaderScreen).
      expect(_fullPath(router), Routes.reader);
      final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
      expect(reader.sourceId, _libSourceId);
      expect(reader.seriesKey, _libSeriesKey);
      expect(reader.chapterKey, _slashLibChapterKey,
          reason: 'the opaque key must round-trip through go_router verbatim',);
    });

    testWidgets(
        'a source chapter lands on the source series route with a '
        'slash-bearing id intact', (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      router.go(
        RoutePaths.sourceReader('toonily', _slashSeriesId, _slashChapterId),
      );
      await _settleReader(tester);
      expect(find.byType(SourceReaderScreen), findsOneWidget);

      await _tapTitle(tester);

      expect(_fullPath(router), Routes.sourceSeriesDetail);
      expect(find.byType(SourceReaderScreen), findsNothing);
      final series = tester.widget<SourceSeriesDetailScreen>(
        find.byType(SourceSeriesDetailScreen),
      );
      expect(series.sourceId, 'toonily');
      // The `/` survived RoutePaths' encoding and go_router's decoding — a raw
      // id here would have split into an extra path segment and 404'd.
      expect(series.seriesId, _slashSeriesId);
    });

    testWidgets('the more-options sheet offers the same jump', (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      router.go(RoutePaths.reader(_libSourceId, _libSeriesKey, _libChapterKey));
      await _settleReader(tester);

      await tester.tap(find.byTooltip('Reader settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Go to series'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(_fullPath(router), Routes.sourceSeriesDetail);
      expect(find.byType(ReaderScreen), findsNothing);
    });
  });

  // The reader route sets `parentNavigatorKey: rootNavigatorKey`, so it renders
  // above the tab shell that owns both series screens. Pushing a shell route
  // from up there makes go_router append a second ShellRouteMatch carrying the
  // same page key, which Navigator asserts on — hence pop-when-beneath and
  // go-otherwise instead of an unconditional push.
  group('Reader → series page keeps the back stack sane', () {
    testWidgets(
        'pops onto the source series page already beneath instead of '
        'stacking a second copy', (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      // Exactly how the source series screen opens a chapter: push the
      // reader on top of the live series page.
      router.go(RoutePaths.sourceSeriesDetail(_libSourceId, _libSeriesKey));
      await _settleReader(tester);
      unawaited(
        router.push(
            RoutePaths.reader(_libSourceId, _libSeriesKey, _libChapterKey),),
      );
      await _settleReader(tester);

      await _tapTitle(tester);

      expect(_fullPath(router), Routes.sourceSeriesDetail);
      // One copy, not two: the jump returned to the existing page.
      expect(
        find.byType(SourceSeriesDetailScreen, skipOffstage: false),
        findsOneWidget,
      );

      // And the round trip is repeatable without the stack creeping upwards.
      unawaited(
        router.push(
            RoutePaths.reader(_libSourceId, _libSeriesKey, _libChapterKey),),
      );
      await _settleReader(tester);
      await _tapTitle(tester);

      expect(_fullPath(router), Routes.sourceSeriesDetail);
      expect(
        find.byType(SourceSeriesDetailScreen, skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets(
        'pops onto the followed series page beneath it, even though the '
        'reader route carries no follow-row id to match against',
        (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      // Exactly how the followed series screen opens a chapter: push the
      // reader on top of the live series page.
      router.go(RoutePaths.seriesDetail(_followedId));
      await _settleReader(tester);
      unawaited(
        router.push(
            RoutePaths.reader(_libSourceId, _libSeriesKey, _libChapterKey),),
      );
      await _settleReader(tester);

      await _tapTitle(tester);

      expect(_fullPath(router), Routes.seriesDetail);
      expect(find.byType(ReaderScreen), findsNothing);
    });

    testWidgets(
        'still reaches a series page when the reader was opened from '
        'somewhere else, and leaves it poppable', (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      // Continue-reading on the dashboard pushes the reader straight from
      // /library, so the series page is not underneath it.
      router.go(Routes.library);
      await _settleReader(tester);
      unawaited(
        router.push(
            RoutePaths.reader(_libSourceId, _libSeriesKey, _libChapterKey),),
      );
      await _settleReader(tester);
      expect(find.byType(ReaderScreen), findsOneWidget);

      await _tapTitle(tester);

      expect(_fullPath(router), Routes.sourceSeriesDetail);
      expect(find.byType(SourceSeriesDetailScreen), findsOneWidget);
      // Nested under the tab root, so back / the iOS edge-swipe still work.
      expect(router.canPop(), isTrue);
    });

    testWidgets(
        'a source chapter opened from elsewhere keeps its slash-bearing '
        'id through the rebuilt route', (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      // Not from the series page, so this takes the rebuild path — which parses
      // the encoded location afresh rather than returning to a live screen.
      router.go(Routes.sources);
      await _settleReader(tester);
      unawaited(
        router.push(
          RoutePaths.sourceReader('toonily', _slashSeriesId, _slashChapterId),
        ),
      );
      await _settleReader(tester);
      expect(find.byType(SourceReaderScreen), findsOneWidget);

      await _tapTitle(tester);

      expect(_fullPath(router), Routes.sourceSeriesDetail);
      final series = tester.widget<SourceSeriesDetailScreen>(
        find.byType(SourceSeriesDetailScreen),
      );
      expect(series.seriesId, _slashSeriesId);
      expect(router.canPop(), isTrue);
    });
  });
}
