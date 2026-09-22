import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/models/collection.dart';
import 'package:manhwamaniacs/features/library/models/collection_detail.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/global_search_result.dart';
import 'package:manhwamaniacs/features/library/models/library_query.dart';
import 'package:manhwamaniacs/features/library/models/library_statistics.dart';
import 'package:manhwamaniacs/features/library/models/reading_history_item.dart';
import 'package:manhwamaniacs/features/library/models/recommendation.dart';
import 'package:manhwamaniacs/features/library/models/series_detail.dart';
import 'package:manhwamaniacs/features/library/models/suggestion.dart';
import 'package:manhwamaniacs/features/library/models/tag.dart';
import 'package:manhwamaniacs/features/library/providers/library_list_provider.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/library/utils/library_preferences.dart';
import 'package:manhwamaniacs/features/reader/models/reader_chapter.dart';
import 'package:manhwamaniacs/features/sources/models/source.dart';
import 'package:manhwamaniacs/features/sources/models/source_pin.dart';
import 'package:manhwamaniacs/features/sources/models/source_search_group.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/repositories/sources_repository.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `LibraryRepository` double. Only [listSeries] and [patchSeries] are wired
/// (what `LibraryListNotifier` actually calls); everything else throws so an
/// unexpected call fails loudly instead of silently returning empty data.
class _FakeLibraryRepository implements LibraryRepository {
  _FakeLibraryRepository(this.pages);

  final Map<int, PagedResult<FollowedSeries>> pages;
  int listCalls = 0;
  String? lastReadingStatus;
  String? lastSort;
  String? lastSearch;
  bool? lastIsFavorite;

  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? sort,
    String? search,
    String? readingStatus,
    bool? isFavorite,
  }) async {
    listCalls++;
    lastReadingStatus = readingStatus;
    lastSort = sort;
    lastSearch = search;
    lastIsFavorite = isFavorite;
    return Ok(pages[page] ?? pages[1]!);
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
    final current = pages.values
        .expand((page) => page.items)
        .firstWhere((series) => series.id == followedId);
    return Ok(current.copyWith(isFavorite: isFavorite, readingStatus: readingStatus));
  }

  @override
  Future<Result<SeriesDetail>> getSeries(int followedId) => throw UnimplementedError();

  @override
  Future<Result<FollowedSeries>> follow({
    required String sourceId,
    required String seriesKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> unfollow(int followedId) => throw UnimplementedError();

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

FollowedSeries _series(int id) {
  return FollowedSeries(
    id: id,
    sourceId: 'asurascans',
    seriesKey: 'series-$id',
    title: 'Series $id',
    coverUrl: '',
    isFavorite: false,
    readingStatus: 'unread',
    notify: false,
    sortOrder: 0,
    contentRating: 'safe',
    rating: 'safe',
    chapterCount: 10,
    createdAt: DateTime(2024),
    updatedAt: DateTime(2024, 6),
  );
}

void main() {
  group('LibraryListNotifier', () {
    Future<ProviderContainer> container0(_FakeLibraryRepository fakeRepo) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(fakeRepo),
          sharedPrefsProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('loads first page and appends on loadMore', () async {
      final fakeRepo = _FakeLibraryRepository({
        1: PagedResult(
          items: [_series(1), _series(2)],
          total: 4,
          page: 1,
          perPage: 2,
          hasNext: true,
        ),
        2: PagedResult(
          items: [_series(3), _series(4)],
          total: 4,
          page: 2,
          perPage: 2,
          hasNext: false,
        ),
      });

      final container = await container0(fakeRepo);

      final state = await container.read(libraryListProvider.future);
      expect(state.items, hasLength(2));
      expect(state.hasNext, isTrue);

      await container.read(libraryListProvider.notifier).loadMore();
      final loaded = container.read(libraryListProvider).value!;
      expect(loaded.items, hasLength(4));
      expect(loaded.hasNext, isFalse);
      expect(fakeRepo.listCalls, 2);
    });

    test('passes reading status filter and default sort to repository', () async {
      final fakeRepo = _FakeLibraryRepository({
        1: PagedResult(
          items: [_series(1)],
          total: 1,
          page: 1,
          perPage: 20,
          hasNext: false,
        ),
      });

      final container = await container0(fakeRepo);

      container.read(libraryQueryProvider.notifier).updateQuery(
            const LibraryQuery(
              filter: LibraryFilter.completed,
            ),
          );
      await container.read(libraryListProvider.future);

      expect(fakeRepo.lastReadingStatus, 'completed');
      expect(fakeRepo.lastSort, 'recently_updated');
    });

    test('favoritesOnly passes is_favorite to the repository', () async {
      final fakeRepo = _FakeLibraryRepository({
        1: PagedResult(
          items: [_series(1)],
          total: 1,
          page: 1,
          perPage: 20,
          hasNext: false,
        ),
      });

      final container = await container0(fakeRepo);

      container.read(libraryQueryProvider.notifier).updateQuery(
            const LibraryQuery(favoritesOnly: true),
          );
      await container.read(libraryListProvider.future);

      expect(fakeRepo.lastIsFavorite, isTrue);
    });

    test('toggleFavorite patches the series via the repository', () async {
      final fakeRepo = _FakeLibraryRepository({
        1: PagedResult(
          items: [_series(1)],
          total: 1,
          page: 1,
          perPage: 20,
          hasNext: false,
        ),
      });

      final container = await container0(fakeRepo);
      await container.read(libraryListProvider.future);

      await container.read(libraryListProvider.notifier).toggleFavorite(1);
      final state = container.read(libraryListProvider).value!;

      expect(state.items.single.isFavorite, isTrue);
    });

    test('search-only query update does not write preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await writeLibraryQuery(prefs, const LibraryQuery());
      final before = prefs.getString(libraryQueryPrefsKey);

      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository({
            1: PagedResult(
              items: [_series(1)],
              total: 1,
              page: 1,
              perPage: 20,
              hasNext: false,
            ),
          }),),
          sharedPrefsProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      container.read(libraryQueryProvider.notifier).patchQuery(
            (query) => query.copyWith(search: 'solo'),
          );

      expect(prefs.getString(libraryQueryPrefsKey), equals(before));
      expect(container.read(libraryQueryProvider).search, 'solo');
    });

    test('persisted query fields still write preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await writeLibraryQuery(prefs, const LibraryQuery());

      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository({
            1: PagedResult(
              items: [_series(1)],
              total: 1,
              page: 1,
              perPage: 20,
              hasNext: false,
            ),
          }),),
          sharedPrefsProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      container.read(libraryQueryProvider.notifier).patchQuery(
            (query) => query.copyWith(sort: LibrarySort.recentlyAdded),
          );

      expect(readLibraryQuery(prefs).sort, LibrarySort.recentlyAdded);
    });
  });

  group('SearchListNotifier (federated, grouped)', () {
    Future<ProviderContainer> searchContainer(
      _FakeSearchSourcesRepository fakeRepo,
    ) async {
      final container = ProviderContainer(
        overrides: [
          sourcesRepositoryProvider.overrideWithValue(fakeRepo),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    SourceSearchGroup group_({
      String? source,
      String name = 'Local library',
      SourceGroupStatus status = SourceGroupStatus.ok,
      String? error,
      bool hasMore = false,
      List<GlobalSearchItem> items = const [],
    }) =>
        SourceSearchGroup(
          source: source,
          sourceName: name,
          status: status,
          error: error,
          total: items.length,
          hasMore: hasMore,
          items: items,
        );

    test('blank query resolves to an empty result without hitting the repo',
        () async {
      final fakeRepo = _FakeSearchSourcesRepository({});
      final container = await searchContainer(fakeRepo);

      final state = await container.read(searchListProvider.future);

      expect(state.isEmpty, isTrue);
      expect(state.groups, isEmpty);
      expect(fakeRepo.calls, 0);
    });

    test('loads page 1 and merges page 2 into the existing sections', () async {
      final fakeRepo = _FakeSearchSourcesRepository({
        1: GroupedSearchResult(
          groups: [
            group_(
              items: const [
                GlobalSearchItem(
                  kind: 'local',
                  seriesId: '1',
                  title: 'Local One',
                ),
              ],
            ),
            group_(
              source: 'mangadex',
              name: 'MangaDex',
              hasMore: true,
              items: const [
                GlobalSearchItem(
                  kind: 'source',
                  source: 'mangadex',
                  seriesId: 'abc',
                  title: 'Source One',
                ),
              ],
            ),
          ],
          sourcesQueried: 12,
          sourcesFailed: 1,
          hasMore: true,
        ),
        2: GroupedSearchResult(
          groups: [
            // Same source as page 1: its items must extend that section
            // instead of adding a second MangaDex header.
            group_(
              source: 'mangadex',
              name: 'MangaDex',
              items: const [
                GlobalSearchItem(
                  kind: 'source',
                  source: 'mangadex',
                  seriesId: 'abc-2',
                  title: 'Source One (page 2)',
                ),
              ],
            ),
            group_(
              source: 'toonily',
              name: 'Toonily',
              items: const [
                GlobalSearchItem(
                  kind: 'source',
                  source: 'toonily',
                  seriesId: 'def',
                  title: 'Source Two',
                ),
              ],
            ),
          ],
          sourcesQueried: 12,
          sourcesFailed: 1,
          page: 2,
        ),
      });

      final container = await searchContainer(fakeRepo);
      container.read(searchQueryProvider.notifier).state = 'one piece';

      final state = await container.read(searchListProvider.future);
      expect(state.groups, hasLength(2));
      expect(state.resultCount, 2);
      expect(state.sourcesQueried, 12);
      expect(state.sourcesFailed, 1);
      expect(state.hasMore, isTrue);
      expect(fakeRepo.lastQuery, 'one piece');

      await container.read(searchListProvider.notifier).loadMore();
      final loaded = container.read(searchListProvider).value!;

      expect(loaded.groups, hasLength(3));
      expect([for (final g in loaded.groups) g.key], ['@local', 'mangadex', 'toonily']);
      expect(loaded.groups[1].items, hasLength(2));
      expect(loaded.resultCount, 4);
      expect(loaded.hasMore, isFalse);
      expect(loaded.isLoadingMore, isFalse);
      expect(fakeRepo.calls, 2);
    });

    test('groupsWithResults drops the sources that answered with nothing',
        () async {
      final fakeRepo = _FakeSearchSourcesRepository({
        1: GroupedSearchResult(
          groups: [
            group_(status: SourceGroupStatus.empty),
            group_(
              source: 'mangadex',
              name: 'MangaDex',
              items: const [
                GlobalSearchItem(
                  kind: 'source',
                  source: 'mangadex',
                  seriesId: 'abc',
                  title: 'Source One',
                ),
              ],
            ),
            group_(
              source: 'toonily',
              name: 'Toonily',
              status: SourceGroupStatus.error,
              error: 'Timed out',
            ),
          ],
          sourcesQueried: 2,
          sourcesFailed: 1,
        ),
      });

      final container = await searchContainer(fakeRepo);
      container.read(searchQueryProvider.notifier).state = 'one piece';

      final state = await container.read(searchListProvider.future);

      expect(state.groups, hasLength(3));
      expect([for (final g in state.groupsWithResults) g.key], ['mangadex']);
      expect(state.groups.last.hasError, isTrue);
    });

    test('retrySource re-queries only the failed source', () async {
      final fakeRepo = _FakeSearchSourcesRepository(
        {
          1: GroupedSearchResult(
            groups: [
              group_(
                source: 'toonily',
                name: 'Toonily',
                status: SourceGroupStatus.error,
                error: 'Timed out',
              ),
            ],
            sourcesQueried: 1,
            sourcesFailed: 1,
          ),
        },
        browsePages: const [
          SourceSeriesSummary(
            id: 'ghi',
            sourceId: 'toonily',
            title: 'Recovered Hit',
            chapterCount: 3,
            genres: [],
            coverUrl: '',
          ),
        ],
      );

      final container = await searchContainer(fakeRepo);
      container.read(searchQueryProvider.notifier).state = 'one piece';
      await container.read(searchListProvider.future);

      await container.read(searchListProvider.notifier).retrySource('toonily');
      final state = container.read(searchListProvider).value!;

      // One browse call, no second federated fan-out.
      expect(fakeRepo.calls, 1);
      expect(fakeRepo.browseCalls, 1);
      expect(state.groups.single.hasError, isFalse);
      expect(state.groups.single.items.single.title, 'Recovered Hit');
      expect(state.sourcesFailed, 0);
    });

    test('repository error surfaces as AsyncError, never stuck loading',
        () async {
      final fakeRepo = _FakeSearchSourcesRepository(
        {},
        error: const NetworkError(message: 'offline'),
      );
      final container = await searchContainer(fakeRepo);
      container.read(searchQueryProvider.notifier).state = 'one piece';

      await expectLater(
        container.read(searchListProvider.future),
        throwsA(isA<AppError>()),
      );
      expect(container.read(searchListProvider).hasError, isTrue);
    });
  });
}

/// Grouped-search double. Only [searchGrouped] and [listSeries] (the
/// single-source retry path) are wired; everything else throws so an unexpected
/// call fails loudly instead of silently returning empty data.
class _FakeSearchSourcesRepository implements SourcesRepository {
  _FakeSearchSourcesRepository(
    this.pages, {
    this.error,
    this.browsePages = const [],
  });

  final Map<int, GroupedSearchResult> pages;
  final AppError? error;
  final List<SourceSeriesSummary> browsePages;
  int calls = 0;
  int browseCalls = 0;
  String? lastQuery;

  @override
  Future<Result<GroupedSearchResult>> searchGrouped(
    String query, {
    int page = 1,
    int perPage = 40,
  }) async {
    calls++;
    lastQuery = query;
    if (error != null) return Err(error!);
    return Ok(pages[page] ?? const GroupedSearchResult());
  }

  @override
  Future<Result<PagedResult<SourceSeriesSummary>>> listSeries(
    String sourceId, {
    int page = 1,
    String? query,
    String? sort,
  }) async {
    browseCalls++;
    return Ok(
      PagedResult(
        items: browsePages,
        total: browsePages.length,
        page: page,
        perPage: 20,
        hasNext: false,
      ),
    );
  }

  @override
  Future<Result<List<SourceSummary>>> listSources() => throw UnimplementedError();

  @override
  Future<Result<List<SourcePin>>> listPins() => throw UnimplementedError();

  @override
  Future<Result<List<SourcePin>>> replacePins(List<String> sourceIds) =>
      throw UnimplementedError();

  @override
  Future<Result<List<SourceBrowseMode>>> listBrowseModes(String sourceId) =>
      throw UnimplementedError();

  @override
  Future<Result<SourceSeriesSummary>> getSeries(
    String sourceId,
    String seriesId,
  ) =>
      throw UnimplementedError();

  @override
  Future<Result<List<SourceChapterSummary>>> getChapters(
    String sourceId,
    String seriesId,
  ) =>
      throw UnimplementedError();

  @override
  Future<Result<ReaderChapter>> getReaderChapter(
    String sourceId,
    String seriesId,
    String chapterId,
  ) =>
      throw UnimplementedError();
}
