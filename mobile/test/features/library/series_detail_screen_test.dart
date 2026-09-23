import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/models/collection.dart';
import 'package:manhwamaniacs/features/library/models/collection_detail.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/known_chapter.dart';
import 'package:manhwamaniacs/features/library/models/library_statistics.dart';
import 'package:manhwamaniacs/features/library/models/reading_history_item.dart';
import 'package:manhwamaniacs/features/library/models/recommendation.dart';
import 'package:manhwamaniacs/features/library/models/series_detail.dart';
import 'package:manhwamaniacs/features/library/models/suggestion.dart';
import 'package:manhwamaniacs/features/library/models/tag.dart';
import 'package:manhwamaniacs/features/library/providers/series_detail_provider.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/library/screens/series_detail_screen.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/models/update_settings.dart';
import 'package:manhwamaniacs/features/updates/repositories/updates_repository.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_chapter_sort.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_chapter_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

/// `LibraryRepository` double for the series-detail screen.
///
/// [getSeries] backs the initial payload (the screen under test also gets it
/// directly via a `seriesDetailProvider` override -- see
/// `_buildSeriesDetailApp` -- so this is really only exercised if a test
/// invalidates that provider), [listSeries] backs the shared `updatesProvider`
/// followed-series cache the Follow control reads its state from,
/// [patchSeries] backs the favorite toggle, and [unfollow] backs Unfollow.
/// Everything else throws so a stray call fails loudly instead of silently
/// returning empty data.
class _FakeLibraryRepository implements LibraryRepository {
  _FakeLibraryRepository(this.detail, {List<FollowedSeries>? followed})
      : followed = followed ?? [detail];

  final SeriesDetail detail;
  List<FollowedSeries> followed;

  /// When set, [listSeries] awaits this, so a test can hold the followed
  /// cache in flight and assert what the Follow button renders from the
  /// `SeriesDetail` payload seed alone.
  Completer<void>? listSeriesGate;
  int? unfollowedId;
  bool? lastPatchIsFavorite;

  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? sort,
    String? search,
    String? readingStatus,
    bool? isFavorite,
  }) async {
    if (listSeriesGate != null) await listSeriesGate!.future;
    return Ok(
      PagedResult(
        items: followed,
        total: followed.length,
        page: 1,
        perPage: perPage,
        hasNext: false,
      ),
    );
  }

  @override
  Future<Result<SeriesDetail>> getSeries(int followedId) async => Ok(detail);

  @override
  Future<Result<FollowedSeries>> follow({
    required String sourceId,
    required String seriesKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> unfollow(int followedId) async {
    unfollowedId = followedId;
    followed = followed.where((f) => f.id != followedId).toList();
    return const Ok(null);
  }

  @override
  Future<Result<FollowedSeries>> patchSeries(
    int followedId, {
    bool? isFavorite,
    String? readingStatus,
    bool? notify,
    bool? matureOverride,
    int? sortOrder,
  }) async {
    lastPatchIsFavorite = isFavorite;
    return Ok(detail.copyWith(isFavorite: isFavorite, readingStatus: readingStatus));
  }

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
      throw UnimplementedError('search should not be called');

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

  @override
  Future<Result<SuggestionResult>> suggest(String prompt, {int limit = 6}) async =>
      const Ok(SuggestionResult());

  @override
  Future<Result<SuggestionAvailability>> suggestAvailability() async => const Ok(
        SuggestionAvailability(
          available: false,
          reason: 'not_configured',
          remainingToday: 0,
        ),
      );
}

/// Empty-by-default `UpdatesRepository` double -- the series-detail screen
/// only ever reaches it indirectly, through `updatesProvider`'s shared
/// followed-series cache, never for notifications directly.
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
  Future<Result<void>> markRead(int notificationId) async => const Ok(null);

  @override
  Future<Result<void>> markAllRead({String? contentKind}) async => const Ok(null);

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
  Future<Result<List<UpdateRun>>> listRuns({int limit = 20}) => throw UnimplementedError();

  @override
  Future<Result<UpdateCheckOutcome>> triggerCheck({List<int>? followedIds}) async =>
      const Ok(UpdateCheckOutcome(queued: false));

  @override
  Future<Result<UpdateRun>> checkFollowed(int followedId) => throw UnimplementedError();
}

/// A followed series' detail payload -- always source-linked (this screen is
/// only ever reached for a series the profile already follows), with one
/// chapter read (`ch-1`, unfinished) and one unread (`ch-2`).
SeriesDetail _sampleSeriesDetail({
  String sourceId = 'mangadex',
  String seriesKey = 'manga-1',
  bool isFavorite = true,
  String readingStatus = 'reading',
  List<String>? genres,
  List<KnownChapter>? chapters,
  Map<String, ChapterProgressEntry>? progress,
}) {
  final resolvedChapters = chapters ??
      const [
        KnownChapter(key: 'ch-1', number: 1, title: 'Chapter 1', pageCount: 20),
        KnownChapter(key: 'ch-2', number: 2, title: 'Chapter 2', pageCount: 20),
      ];
  return SeriesDetail(
    id: 1,
    sourceId: sourceId,
    seriesKey: seriesKey,
    title: 'Solo Leveling',
    coverUrl: '',
    isFavorite: isFavorite,
    readingStatus: readingStatus,
    notify: true,
    sortOrder: 0,
    contentRating: 'teen',
    rating: 'safe',
    chapterCount: resolvedChapters.length,
    createdAt: DateTime(2024),
    updatedAt: DateTime(2024, 6),
    description: 'The weakest hunter becomes the strongest.',
    author: 'Chugong',
    genres: genres ?? const ['Action'],
    chapters: resolvedChapters,
    progress: progress ??
        const {
          'ch-1': ChapterProgressEntry(lastPage: 5, isCompleted: false),
        },
  );
}

Future<Widget> _buildSeriesDetailApp(
  SeriesDetail detail, {
  _FakeLibraryRepository? libraryRepo,
  _FakeUpdatesRepository? updatesRepo,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  return ProviderScope(
    overrides: [
      apiBaseUrlOverride('http://127.0.0.1:8000'),
      sharedPrefsProvider.overrideWithValue(prefs),
      libraryRepositoryProvider.overrideWithValue(
        libraryRepo ?? _FakeLibraryRepository(detail),
      ),
      updatesRepositoryProvider.overrideWithValue(
        updatesRepo ?? _FakeUpdatesRepository(),
      ),
      seriesDetailProvider(1)
          .overrideWith((ref) async => (series: detail, isOffline: false)),
    ],
    child: const MaterialApp(
      home: SeriesDetailScreen(seriesId: 1),
    ),
  );
}

/// Chapter row labels in the order they are rendered.
List<String> _renderedChapterLabels(WidgetTester tester) => [
      for (final tile
          in tester.widgetList<SeriesChapterTile>(find.byType(SeriesChapterTile)))
        tile.label.primary,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Widens the surface so the whole detail column lays out.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
  }

  group('SeriesDetailScreen', () {
    testWidgets('renders series metadata and chapters', (tester) async {
      useTallSurface(tester);

      await tester.pumpWidget(await _buildSeriesDetailApp(_sampleSeriesDetail()));
      await tester.pumpAndSettle();

      expect(find.text('Solo Leveling'), findsWidgets);
      expect(find.text('Chugong'), findsOneWidget);
      expect(find.text('Chapter 1'), findsOneWidget);
      // Status chip label is upper-cased by the screen.
      expect(find.text('READING'), findsOneWidget);
      expect(find.text('Action'), findsOneWidget);
    });
  });

  // The two series pages had drifted into looking like different apps, which is
  // what made tapping a chapter title in the reader feel like leaving the app.
  // These lock the library page to the source page's shape.
  group('SeriesDetailScreen matches the source page shape', () {
    testWidgets('summarises the series on one line, source-page style',
        (tester) async {
      useTallSurface(tester);

      await tester.pumpWidget(await _buildSeriesDetailApp(_sampleSeriesDetail()));
      await tester.pumpAndSettle();

      // "Latest: … · N chapters" is the whole line now -- pages and a read
      // percentage were library-only facts backed by fields the source-native
      // payload no longer carries.
      expect(find.text('Latest: Chapter 2  ·  2 chapters'), findsOneWidget);
    });

    testWidgets('offers the same primary actions in the same order',
        (tester) async {
      useTallSurface(tester);

      await tester.pumpWidget(await _buildSeriesDetailApp(_sampleSeriesDetail()));
      await tester.pumpAndSettle();

      // CONTINUE (uppercased by the shared pill), then Follow/Unfollow -- the
      // order the source page uses. Favorite is the library-only extra and
      // survives the unification; the download pair is gone entirely.
      expect(find.byKey(const Key('read-primary')), findsOneWidget);
      expect(find.text('CONTINUE'), findsOneWidget);
      expect(find.byKey(const Key('follow-toggle')), findsOneWidget);
      expect(find.byKey(const Key('favorite-toggle')), findsOneWidget);
    });

    testWidgets('the Newest/Oldest toggle reorders the chapter list',
        (tester) async {
      useTallSurface(tester);

      await tester.pumpWidget(await _buildSeriesDetailApp(_sampleSeriesDetail()));
      await tester.pumpAndSettle();

      expect(find.byType(SeriesChapterSortToggle), findsOneWidget);
      // Newest-first is the default on both pages.
      expect(_renderedChapterLabels(tester), ['Chapter 2', 'Chapter 1']);

      await tester.tap(find.text('Oldest'));
      await tester.pumpAndSettle();

      expect(_renderedChapterLabels(tester), ['Chapter 1', 'Chapter 2']);
    });

    testWidgets('marks the last-read chapter and shows its page position',
        (tester) async {
      useTallSurface(tester);

      await tester.pumpWidget(await _buildSeriesDetailApp(_sampleSeriesDetail()));
      await tester.pumpAndSettle();

      final current = tester
          .widgetList<SeriesChapterTile>(find.byType(SeriesChapterTile))
          .firstWhere((tile) => tile.isCurrent);
      expect(current.label.primary, 'Chapter 1');
      expect(current.progressText, '5/20 pages');
    });

    testWidgets('favourite still toggles', (tester) async {
      useTallSurface(tester);

      // The sample starts favourited; tapping has to flip the label rather than
      // the control quietly disappearing in the reshuffle.
      await tester.pumpWidget(await _buildSeriesDetailApp(_sampleSeriesDetail()));
      await tester.pumpAndSettle();

      expect(find.text('Favorited'), findsOneWidget);
      await tester.tap(find.byKey(const Key('favorite-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Add Favorite'), findsOneWidget);
    });

    testWidgets(
        'tapping Continue opens the reader at the resolved chapter and page',
        (tester) async {
      useTallSurface(tester);

      final detail = _sampleSeriesDetail();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      String? navigated;
      final router = GoRouter(
        initialLocation: '/library/1',
        routes: [
          GoRoute(
            path: '/library/:seriesId',
            builder: (_, __) => const SeriesDetailScreen(seriesId: 1),
          ),
          GoRoute(
            path: '/library/read/:sourceId/:seriesKey/:chapterKey',
            builder: (_, state) {
              navigated = state.uri.toString();
              return const Scaffold(body: Text('READER'));
            },
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiBaseUrlOverride('http://127.0.0.1:8000'),
            sharedPrefsProvider.overrideWithValue(prefs),
            libraryRepositoryProvider.overrideWithValue(
              _FakeLibraryRepository(detail),
            ),
            updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
            seriesDetailProvider(1)
          .overrideWith((ref) async => (series: detail, isOffline: false)),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('CONTINUE'));
      await tester.pumpAndSettle();

      expect(navigated, isNotNull);
      // Chapter 1 (`ch-1`) is the chapter with unfinished progress, resumed
      // at the page it was last left on.
      expect(navigated, contains('/library/read/mangadex/manga-1/ch-1'));
      expect(navigated, contains('page=5'));
      expect(find.text('READER'), findsOneWidget);
    });

    testWidgets(
        'Continue advances to the first unread chapter after one is finished '
        'cleanly, instead of reopening chapter 1', (tester) async {
      useTallSurface(tester);

      // Closing the reader on the last page of chapter 1 (no auto-advance)
      // used to leave Continue pointing back at chapter 1's final page.
      final detail = _sampleSeriesDetail(
        progress: const {
          'ch-1': ChapterProgressEntry(lastPage: 20, isCompleted: true),
        },
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      String? navigated;
      final router = GoRouter(
        initialLocation: '/library/1',
        routes: [
          GoRoute(
            path: '/library/:seriesId',
            builder: (_, __) => const SeriesDetailScreen(seriesId: 1),
          ),
          GoRoute(
            path: '/library/read/:sourceId/:seriesKey/:chapterKey',
            builder: (_, state) {
              navigated = state.uri.toString();
              return const Scaffold(body: Text('READER'));
            },
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiBaseUrlOverride('http://127.0.0.1:8000'),
            sharedPrefsProvider.overrideWithValue(prefs),
            libraryRepositoryProvider.overrideWithValue(
              _FakeLibraryRepository(detail),
            ),
            updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
            seriesDetailProvider(1)
                .overrideWith((ref) async => (series: detail, isOffline: false)),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Still "Continue": a chapter of history is not a fresh start, even
      // though the chapter it opens has no progress row of its own.
      await tester.tap(find.text('CONTINUE'));
      await tester.pumpAndSettle();

      expect(navigated, contains('/library/read/mangadex/manga-1/ch-2'));
      expect(navigated, isNot(contains('page=')));
    });
  });

  group('SeriesDetailScreen Follow control', () {
    testWidgets(
        'reflects the already-followed state from the payload before the '
        'followed cache loads, and stays disabled until then', (tester) async {
      useTallSurface(tester);
      final detail = _sampleSeriesDetail();
      final repo = _FakeLibraryRepository(detail)
        ..listSeriesGate = Completer<void>();

      await tester.pumpWidget(
        await _buildSeriesDetailApp(detail, libraryRepo: repo),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The followed-series cache request is still gated, so this label can
      // only have come from the SeriesDetail payload itself -- every series
      // reached through this screen is already followed, which is why the
      // screen seeds `initialIsFollowed: true` unconditionally.
      expect(find.text('Unfollow'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);

      // ...but the control stays disabled until the cache lands, so a tap can
      // never act on a followed id the payload named and the server has since
      // dropped.
      final button = tester.widget<FilledButton>(
        find.ancestor(of: find.text('Unfollow'), matching: find.byType(FilledButton)),
      );
      expect(button.onPressed, isNull);

      repo.listSeriesGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Unfollow'), findsOneWidget);
    });

    testWidgets(
        'unfollowing calls the repository with the followed id and flips the '
        'button to Follow', (tester) async {
      useTallSurface(tester);
      final detail = _sampleSeriesDetail();
      final repo = _FakeLibraryRepository(detail);

      await tester.pumpWidget(
        await _buildSeriesDetailApp(detail, libraryRepo: repo),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Unfollow'));
      await tester.tap(find.text('Unfollow'));
      await tester.pumpAndSettle();

      expect(repo.unfollowedId, 1);
      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('Unfollow'), findsNothing);
    });
  });
}
