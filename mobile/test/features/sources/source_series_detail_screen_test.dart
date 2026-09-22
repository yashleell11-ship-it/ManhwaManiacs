import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/models/collection.dart';
import 'package:manhwamaniacs/features/library/models/collection_detail.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/library_statistics.dart';
import 'package:manhwamaniacs/features/library/models/reading_history_item.dart';
import 'package:manhwamaniacs/features/library/models/recommendation.dart';
import 'package:manhwamaniacs/features/library/models/series_detail.dart';
import 'package:manhwamaniacs/features/library/models/tag.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/reader/models/reader_chapter.dart';
import 'package:manhwamaniacs/features/sources/models/source.dart';
import 'package:manhwamaniacs/features/sources/models/source_pin.dart';
import 'package:manhwamaniacs/features/sources/models/source_search_group.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/repositories/sources_repository.dart';
import 'package:manhwamaniacs/features/sources/screens/source_series_detail_screen.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/models/update_settings.dart';
import 'package:manhwamaniacs/features/updates/repositories/updates_repository.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../support/test_overrides.dart';

/// Minimal fake — only the series-detail + chapters paths are exercised; the
/// remaining methods throw so a stray call surfaces loudly rather than passing
/// silently with empty data.
class _FakeSourcesRepository implements SourcesRepository {
  _FakeSourcesRepository(this.series, this.chapters);

  final SourceSeriesSummary series;
  final List<SourceChapterSummary> chapters;

  @override
  Future<Result<SourceSeriesSummary>> getSeries(
    String sourceId,
    String seriesId,
  ) async =>
      Ok(series);

  @override
  Future<Result<List<SourceChapterSummary>>> getChapters(
    String sourceId,
    String seriesId,
  ) async =>
      Ok(chapters);

  @override
  Future<Result<List<SourceSummary>>> listSources() => throw UnimplementedError();

  @override
  Future<Result<GroupedSearchResult>> searchGrouped(
    String query, {
    int page = 1,
    int perPage = 40,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<List<SourcePin>>> listPins() => throw UnimplementedError();

  @override
  Future<Result<List<SourcePin>>> replacePins(List<String> sourceIds) =>
      throw UnimplementedError();

  @override
  Future<Result<List<SourceBrowseMode>>> listBrowseModes(String sourceId) =>
      throw UnimplementedError();

  @override
  Future<Result<PagedResult<SourceSeriesSummary>>> listSeries(
    String sourceId, {
    int page = 1,
    String? query,
    String? sort,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<ReaderChapter>> getReaderChapter(
    String sourceId,
    String seriesId,
    String chapterId,
  ) =>
      throw UnimplementedError();
}

/// Fake library repository for the Follow button. Tracks whether
/// [follow] / [unfollow] were called so the test can assert the correct
/// endpoint is hit for each button state. [listSeries] backs
/// `UpdatesNotifier`'s followed-series cache, which
/// [SeriesFollowButton] reads via `followedFor` to decide Follow vs Unfollow.
class _FakeLibraryRepository implements LibraryRepository {
  _FakeLibraryRepository({List<FollowedSeries> followed = const []})
      : _followed = followed;

  List<FollowedSeries> _followed;
  bool followCalled = false;
  int? unfollowedId;
  int unfollowCallCount = 0;

  /// When set, [unfollow] awaits this before resolving, so tests can
  /// observe the button's busy/disabled state mid-flight and verify a
  /// second tap while pending does not fire a second unfollow.
  Completer<void>? unfollowGate;

  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? sort,
    String? search,
    String? readingStatus,
    bool? isFavorite,
  }) async =>
      Ok(
        PagedResult(
          items: _followed,
          total: _followed.length,
          page: 1,
          perPage: perPage,
          hasNext: false,
        ),
      );

  @override
  Future<Result<FollowedSeries>> follow({
    required String sourceId,
    required String seriesKey,
  }) async {
    followCalled = true;
    final series = FollowedSeries(
      id: 999,
      sourceId: sourceId,
      seriesKey: seriesKey,
      title: 'Solo Leveling',
      coverUrl: '',
      isFavorite: false,
      readingStatus: 'unread',
      notify: true,
      sortOrder: 0,
      contentRating: 'safe',
      rating: 'safe',
      chapterCount: 0,
    );
    _followed = [..._followed, series];
    return Ok(series);
  }

  @override
  Future<Result<void>> unfollow(int followedId) async {
    unfollowCallCount++;
    unfollowedId = followedId;
    if (unfollowGate != null) await unfollowGate!.future;
    _followed = _followed.where((f) => f.id != followedId).toList();
    return const Ok(null);
  }

  @override
  Future<Result<SeriesDetail>> getSeries(int followedId) => throw UnimplementedError();

  @override
  Future<Result<FollowedSeries>> patchSeries(
    int followedId, {
    bool? isFavorite,
    String? readingStatus,
    bool? notify,
    bool? matureOverride,
    int? sortOrder,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<List<ContinueReadingItem>>> continueReading({int limit = 10}) =>
      throw UnimplementedError();

  @override
  Future<Result<List<FollowedSeries>>> recentlyUpdated({int limit = 10}) =>
      throw UnimplementedError();

  @override
  Future<Result<List<RecommendationGenre>>> recommendations({int limit = 10}) =>
      throw UnimplementedError();

  @override
  Future<Result<PagedResult<FollowedSeries>>> search(
    String query, {
    int page = 1,
    int perPage = 20,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<LibraryStatistics>> statistics() => throw UnimplementedError();

  @override
  Future<Result<List<ReadingHistoryItem>>> readingHistory({
    int limit = 50,
    int offset = 0,
    bool bySeries = true,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<List<Collection>>> listCollections() => throw UnimplementedError();

  @override
  Future<Result<CollectionDetail>> getCollection(int collectionId) =>
      throw UnimplementedError();

  @override
  Future<Result<Collection>> createCollection({
    required String name,
    String? description,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<Collection>> updateCollection(
    int collectionId, {
    String? name,
    String? description,
    int? sortOrder,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> deleteCollection(int collectionId) => throw UnimplementedError();

  @override
  Future<Result<CollectionDetail>> addSeriesToCollection(
    int collectionId, {
    required String sourceId,
    required String seriesKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> removeSeriesFromCollection(
    int collectionId, {
    required String sourceId,
    required String seriesKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<List<Tag>>> listTags({String? category}) => throw UnimplementedError();

  @override
  Future<Result<Tag>> createTag({
    required String name,
    String category = 'custom',
    String? color,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> deleteTag(int tagId) => throw UnimplementedError();

  @override
  Future<Result<void>> addTagToSeries({
    required String sourceId,
    required String seriesKey,
    required int tagId,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> removeTagFromSeries({
    required String sourceId,
    required String seriesKey,
    required int tagId,
  }) =>
      throw UnimplementedError();
}

/// Minimal fake — only notifications/unread-count are exercised (the
/// followed-series refresh loop reads both); follow/unfollow live on
/// [LibraryRepository] now, see [_FakeLibraryRepository].
class _FakeUpdatesRepository implements UpdatesRepository {
  @override
  Future<Result<List<UpdateNotification>>> listNotifications({
    bool unreadOnly = false,
    int limit = 100,
  }) async =>
      const Ok([]);

  @override
  Future<Result<int>> getUnreadCount() async => const Ok(0);

  @override
  Future<Result<UpdateSettings>> getSettings() => throw UnimplementedError();

  @override
  Future<Result<UpdateSettings>> updateSettings({
    bool? enabled,
    int? checkIntervalMinutes,
    bool? notifyEnabled,
    bool? checkOnStartup,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> markRead(int notificationId) => throw UnimplementedError();

  @override
  Future<Result<void>> markAllRead() => throw UnimplementedError();

  @override
  Future<Result<List<UpdateRun>>> listRuns({int limit = 20}) => throw UnimplementedError();

  @override
  Future<Result<UpdateCheckOutcome>> triggerCheck({List<int>? followedIds}) =>
      throw UnimplementedError();

  @override
  Future<Result<UpdateRun>> checkFollowed(int followedId) => throw UnimplementedError();
}

SourceSeriesSummary _series({String? latestChapter}) => SourceSeriesSummary(
      id: 'manga-1',
      sourceId: 'mangadex',
      title: 'Solo Leveling',
      chapterCount: 1,
      genres: const [],
      coverUrl: 'http://example.test/cover.jpg',
      latestChapter: latestChapter,
    );

SourceChapterSummary _chapter({
  required String id,
  double? number,
  String title = 'Chapter 1',
}) =>
    SourceChapterSummary(
      id: id,
      sourceId: 'mangadex',
      seriesId: 'manga-1',
      title: title,
      number: number,
      pageCount: 10,
    );

Future<ProviderContainer> _pumpScreen(
  WidgetTester tester, {
  _FakeUpdatesRepository? updatesRepo,
  _FakeLibraryRepository? libraryRepo,
  List<SourceChapterSummary>? chapters,
  SourceSeriesSummary? series,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  final fakeSourcesRepo = _FakeSourcesRepository(
    series ?? _series(),
    chapters ?? [_chapter(id: 'manga-1:1', number: 1)],
  );

  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      apiBaseUrlOverride('http://example.test'),
      sourcesRepositoryProvider.overrideWithValue(fakeSourcesRepo),
      updatesRepositoryProvider.overrideWithValue(updatesRepo ?? _FakeUpdatesRepository()),
      libraryRepositoryProvider.overrideWithValue(libraryRepo ?? _FakeLibraryRepository()),
    ],
  );
  addTearDown(container.dispose);

  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: SourceSeriesDetailScreen(
          sourceId: 'mangadex',
          seriesId: 'manga-1',
        ),
      ),
    ),
  );
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SourceSeriesDetailScreen header meta line', () {
    testWidgets('latest comes from the chapter list, not a stale summary field',
        (tester) async {
      // Connectors scrape `latest_chapter` off a listing page that can lag the
      // real chapter list, so the summary field must never win: it would print
      // "Latest: Chapter 118" directly above a newest-first list topped by 120.
      await _pumpScreen(
        tester,
        series: _series(latestChapter: 'Chapter 118'),
        chapters: [
          _chapter(id: 'manga-1:118', number: 118, title: 'Chapter 118'),
          _chapter(id: 'manga-1:120', number: 120, title: 'Chapter 120'),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Latest: Chapter 120'), findsOneWidget);
      expect(find.textContaining('Latest: Chapter 118'), findsNothing);
    });

    testWidgets('falls back to the summary field when no chapters loaded',
        (tester) async {
      await _pumpScreen(
        tester,
        series: _series(latestChapter: 'Chapter 77'),
        chapters: const [],
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Latest: Chapter 77'), findsOneWidget);
    });

    testWidgets('states no count when the series has no chapters',
        (tester) async {
      await _pumpScreen(
        tester,
        series: _series(),
        chapters: const [],
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('0 chapters'), findsNothing);
    });
  });

  group('SourceSeriesDetailScreen chapter rows', () {
    testWidgets('tapping a chapter navigates to the source reader',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final fakeRepo = _FakeSourcesRepository(
        _series(),
        [
          _chapter(id: 'manga-1:1', number: 1),
        ],
      );

      String? navigatedLocation;
      final router = GoRouter(
        initialLocation: '/sources/mangadex/series/manga-1',
        routes: [
          GoRoute(
            path: '/sources/:sourceId/series/:seriesId',
            builder: (_, state) => SourceSeriesDetailScreen(
              sourceId: state.pathParameters['sourceId']!,
              seriesId: state.pathParameters['seriesId']!,
            ),
          ),
          GoRoute(
            path: '/sources/:sourceId/series/:seriesId/chapters/:chapterId/read',
            builder: (_, state) {
              navigatedLocation = state.uri.toString();
              return const Scaffold(body: Center(child: Text('READER')));
            },
          ),
        ],
      );

      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            apiBaseUrlOverride('http://example.test'),
            sourcesRepositoryProvider.overrideWithValue(fakeRepo),
            updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
            libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      // Wait for series detail + chapters to resolve and render.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final chaptersFinder = find.text('Chapters', skipOffstage: false);
      await tester.ensureVisible(chaptersFinder);
      await tester.pumpAndSettle();

      // The chapter row label is "Chapter 1" (from chapterLabel).
      await tester.tap(find.text('Chapter 1'));
      await tester.pumpAndSettle();

      expect(navigatedLocation, isNotNull);
      expect(
        navigatedLocation,
        RoutePaths.sourceReader('mangadex', 'manga-1', 'manga-1:1'),
      );
      expect(find.text('READER'), findsOneWidget);
    });
  });

  group('SourceSeriesDetailScreen Follow button', () {
    testWidgets('shows Follow when the series is not followed', (tester) async {
      final fakeLibrary = _FakeLibraryRepository();
      await _pumpScreen(tester, libraryRepo: fakeLibrary);

      // Let the providers resolve.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('Unfollow'), findsNothing);
      expect(fakeLibrary.followCalled, isFalse);
    });

    testWidgets('shows Unfollow when the series is already followed',
        (tester) async {
      final fakeLibrary = _FakeLibraryRepository(
        followed: [
          const FollowedSeries(
            id: 42,
            sourceId: 'mangadex',
            seriesKey: 'manga-1',
            title: 'Solo Leveling',
            coverUrl: '',
            isFavorite: false,
            readingStatus: 'unread',
            notify: true,
            sortOrder: 0,
            contentRating: 'safe',
            rating: 'safe',
            chapterCount: 0,
          ),
        ],
      );
      await _pumpScreen(tester, libraryRepo: fakeLibrary);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Unfollow'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
    });

    testWidgets('tapping Follow calls follow and flips to Unfollow',
        (tester) async {
      final fakeLibrary = _FakeLibraryRepository();
      await _pumpScreen(tester, libraryRepo: fakeLibrary);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Follow'), findsOneWidget);

      await tester.tap(find.text('Follow'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(fakeLibrary.followCalled, isTrue);
      // After the optimistic + refresh cycle, the button should reflect the
      // new followed state.
      expect(find.text('Unfollow'), findsOneWidget);
    });

    testWidgets('tapping Unfollow calls unfollow', (tester) async {
      final fakeLibrary = _FakeLibraryRepository(
        followed: [
          const FollowedSeries(
            id: 42,
            sourceId: 'mangadex',
            seriesKey: 'manga-1',
            title: 'Solo Leveling',
            coverUrl: '',
            isFavorite: false,
            readingStatus: 'unread',
            notify: true,
            sortOrder: 0,
            contentRating: 'safe',
            rating: 'safe',
            chapterCount: 0,
          ),
        ],
      );
      await _pumpScreen(tester, libraryRepo: fakeLibrary);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Unfollow'), findsOneWidget);

      await tester.tap(find.text('Unfollow'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(fakeLibrary.unfollowedId, 42);
    });

    testWidgets('unfollow disables the button while the delete is pending',
        (tester) async {
      final fakeLibrary = _FakeLibraryRepository(
        followed: [
          const FollowedSeries(
            id: 42,
            sourceId: 'mangadex',
            seriesKey: 'manga-1',
            title: 'Solo Leveling',
            coverUrl: '',
            isFavorite: false,
            readingStatus: 'unread',
            notify: true,
            sortOrder: 0,
            contentRating: 'safe',
            rating: 'safe',
            chapterCount: 0,
          ),
        ],
      )..unfollowGate = Completer<void>();
      await _pumpScreen(tester, libraryRepo: fakeLibrary);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Unfollow'), findsOneWidget);

      await tester.tap(find.text('Unfollow'));
      await tester.pump();

      // Mirrors follow: actionPending flips immediately, before the repo
      // call resolves, so the button shows a busy label and disables.
      expect(find.text('Unfollowing…'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Unfollowing…'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull);

      fakeLibrary.unfollowGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Follow'), findsOneWidget);
    });

    testWidgets('double-tapping Unfollow while pending only calls unfollow once',
        (tester) async {
      final fakeLibrary = _FakeLibraryRepository(
        followed: [
          const FollowedSeries(
            id: 42,
            sourceId: 'mangadex',
            seriesKey: 'manga-1',
            title: 'Solo Leveling',
            coverUrl: '',
            isFavorite: false,
            readingStatus: 'unread',
            notify: true,
            sortOrder: 0,
            contentRating: 'safe',
            rating: 'safe',
            chapterCount: 0,
          ),
        ],
      )..unfollowGate = Completer<void>();
      await _pumpScreen(tester, libraryRepo: fakeLibrary);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Unfollow'));
      await tester.pump();
      expect(fakeLibrary.unfollowCallCount, 1);

      // The button is disabled while pending, so this second tap must be a
      // no-op -- it must not fire a second unfollow call.
      await tester.tap(find.text('Unfollowing…'), warnIfMissed: false);
      await tester.pump();
      expect(fakeLibrary.unfollowCallCount, 1);

      fakeLibrary.unfollowGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(fakeLibrary.unfollowCallCount, 1);
    });
  });
}
