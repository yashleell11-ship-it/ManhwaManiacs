import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/collections/providers/collection_detail_provider.dart';
import 'package:manhwamaniacs/features/collections/screens/collection_detail_screen.dart';
import 'package:manhwamaniacs/features/library/models/collection.dart';
import 'package:manhwamaniacs/features/library/models/collection_detail.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/library_statistics.dart';
import 'package:manhwamaniacs/features/library/models/reading_history_item.dart';
import 'package:manhwamaniacs/features/library/models/recommendation.dart';
import 'package:manhwamaniacs/features/library/models/series_detail.dart';
import 'package:manhwamaniacs/features/library/models/suggestion.dart';
import 'package:manhwamaniacs/features/library/models/tag.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

import '../../support/test_overrides.dart';

/// A candidate series offered by the "Add Series" picker
/// (`librarySeriesPickerProvider` -> `listSeries`). Only what the picker UI
/// reads (title) and what a collection member row identifies by
/// (sourceId/seriesKey) matter here.
FollowedSeries _pickerSeriesItem({
  required String sourceId,
  required String seriesKey,
  required String title,
}) =>
    FollowedSeries(
      id: 0,
      sourceId: sourceId,
      seriesKey: seriesKey,
      title: title,
      coverUrl: '',
      isFavorite: false,
      readingStatus: 'reading',
      notify: false,
      sortOrder: 0,
      contentRating: 'teen',
      rating: 'safe',
      chapterCount: 10,
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024, 6),
    );

class _MutableCollectionsRepository implements LibraryRepository {
  _MutableCollectionsRepository({
    required this.collections,
    required Map<int, CollectionDetail> details,
    List<FollowedSeries>? pickerSeries,
  })  : _details = details,
        _pickerSeries = pickerSeries ??
            [
              _pickerSeriesItem(
                sourceId: 'toonkor',
                seriesKey: 'solo-leveling',
                title: 'Solo Leveling',
              ),
              _pickerSeriesItem(
                sourceId: 'toonkor',
                seriesKey: 'tower-of-god',
                title: 'Tower of God',
              ),
            ];

  final List<Collection> collections;
  final Map<int, CollectionDetail> _details;
  final List<FollowedSeries> _pickerSeries;

  int renameCalls = 0;
  int deleteCalls = 0;
  int addSeriesCalls = 0;
  int removeSeriesCalls = 0;

  @override
  Future<Result<List<Collection>>> listCollections() async => Ok(collections);

  @override
  Future<Result<CollectionDetail>> getCollection(int collectionId) async {
    final detail = _details[collectionId];
    if (detail == null) {
      return const Err(UnknownError(message: 'missing collection'));
    }
    return Ok(detail);
  }

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
  }) async {
    renameCalls++;
    final detail = _details[collectionId]!;
    final updated = CollectionDetail(
      id: detail.id,
      name: name ?? detail.name,
      description: description ?? detail.description,
      coverUrl: detail.coverUrl,
      seriesCount: detail.seriesCount,
      sortOrder: sortOrder ?? detail.sortOrder,
      series: detail.series,
    );
    _details[collectionId] = updated;
    return Ok(updated.toCollection());
  }

  @override
  Future<Result<void>> deleteCollection(int collectionId) async {
    deleteCalls++;
    collections.removeWhere((item) => item.id == collectionId);
    _details.remove(collectionId);
    return const Ok(null);
  }

  @override
  Future<Result<CollectionDetail>> addSeriesToCollection(
    int collectionId, {
    required String sourceId,
    required String seriesKey,
  }) async {
    addSeriesCalls++;
    final detail = _details[collectionId]!;
    final updatedSeries = [
      ...detail.series,
      CollectionSeriesRef(
        sourceId: sourceId,
        seriesKey: seriesKey,
        sortOrder: detail.series.length,
      ),
    ];
    final updated = CollectionDetail(
      id: detail.id,
      name: detail.name,
      description: detail.description,
      coverUrl: detail.coverUrl,
      seriesCount: updatedSeries.length,
      sortOrder: detail.sortOrder,
      series: updatedSeries,
    );
    _details[collectionId] = updated;
    return Ok(updated);
  }

  @override
  Future<Result<void>> removeSeriesFromCollection(
    int collectionId, {
    required String sourceId,
    required String seriesKey,
  }) async {
    removeSeriesCalls++;
    final detail = _details[collectionId]!;
    final updatedSeries = detail.series
        .where(
          (member) => member.sourceId != sourceId || member.seriesKey != seriesKey,
        )
        .toList();
    final updated = CollectionDetail(
      id: detail.id,
      name: detail.name,
      description: detail.description,
      coverUrl: detail.coverUrl,
      seriesCount: updatedSeries.length,
      sortOrder: detail.sortOrder,
      series: updatedSeries,
    );
    _details[collectionId] = updated;
    return const Ok(null);
  }

  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? sort,
    String? search,
    String? readingStatus,
    bool? isFavorite,
  }) async {
    // Paged the way the server pages (200 at most), so a library bigger than
    // one page is only whole to a caller that asks for every page.
    final start = (page - 1) * perPage;
    final end = (start + perPage).clamp(0, _pickerSeries.length);
    return Ok(
      PagedResult(
        items: start < _pickerSeries.length
            ? _pickerSeries.sublist(start, end)
            : const [],
        total: _pickerSeries.length,
        page: page,
        perPage: perPage,
        hasNext: end < _pickerSeries.length,
      ),
    );
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

CollectionDetail _detail({
  required int id,
  required String name,
  List<CollectionSeriesRef> series = const [],
}) =>
    CollectionDetail(
      id: id,
      name: name,
      description: 'Curated picks',
      seriesCount: series.length,
      sortOrder: 0,
      series: series,
    );

Future<void> _pumpDetail(
  WidgetTester tester,
  _MutableCollectionsRepository repo,
  int collectionId,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiBaseUrlOverride('http://127.0.0.1:8000'),
        libraryRepositoryProvider.overrideWithValue(repo),
        // SeriesCoverImage resolves the active profile for the image proxy's
        // X-Profile-Id header; the seeded override keeps it off SharedPreferences.
        activeProfileOverride(),
        // The screen asks which mode it is listing; pinning it keeps this
        // test off SharedPreferences.
        ...contentModeOverrides(),
      ],
      child: MaterialApp(
        home: CollectionDetailScreen(collectionId: collectionId),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CollectionDetailScreen', () {
    testWidgets('shows empty collection state', (tester) async {
      final repo = _MutableCollectionsRepository(
        collections: [
          const Collection(
            id: 1,
            name: 'Action Picks',
            description: 'Curated picks',
            seriesCount: 0,
            sortOrder: 0,
          ),
        ],
        details: {1: _detail(id: 1, name: 'Action Picks')},
      );

      await _pumpDetail(tester, repo, 1);

      expect(find.text('This collection is empty'), findsOneWidget);
      expect(find.text('Add series'), findsOneWidget);
    });

    testWidgets('rename collection updates detail', (tester) async {
      final repo = _MutableCollectionsRepository(
        collections: [
          const Collection(
            id: 1,
            name: 'Action Picks',
            description: 'Curated picks',
            seriesCount: 1,
            sortOrder: 0,
          ),
        ],
        details: {
          1: _detail(
            id: 1,
            name: 'Action Picks',
            series: const [
              CollectionSeriesRef(
                sourceId: 'toonkor',
                seriesKey: 'solo-leveling',
                sortOrder: 0,
              ),
            ],
          ),
        },
      );

      await _pumpDetail(tester, repo, 1);
      expect(find.text('Action Picks'), findsWidgets);

      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Peak Fiction');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(repo.renameCalls, 1);
      expect(find.text('Peak Fiction'), findsWidgets);
    });

    testWidgets('add series from dialog updates collection', (tester) async {
      final repo = _MutableCollectionsRepository(
        collections: [
          const Collection(
            id: 1,
            name: 'Action Picks',
            seriesCount: 0,
            sortOrder: 0,
          ),
        ],
        details: {1: _detail(id: 1, name: 'Action Picks')},
      );

      await _pumpDetail(tester, repo, 1);
      await tester.tap(find.text('Add Series').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tower of God'));
      await tester.pumpAndSettle();

      expect(repo.addSeriesCalls, 1);
      // A collection member carries no title of its own — it's rendered by
      // its opaque (sourceId, seriesKey) identity, not the picker title.
      expect(find.text('tower-of-god'), findsWidgets);
    });

    testWidgets('remove series updates collection', (tester) async {
      final repo = _MutableCollectionsRepository(
        collections: [
          const Collection(
            id: 1,
            name: 'Action Picks',
            seriesCount: 1,
            sortOrder: 0,
          ),
        ],
        details: {
          1: _detail(
            id: 1,
            name: 'Action Picks',
            series: const [
              CollectionSeriesRef(
                sourceId: 'toonkor',
                seriesKey: 'solo-leveling',
                sortOrder: 0,
              ),
            ],
          ),
        },
      );

      await _pumpDetail(tester, repo, 1);
      await tester.tap(find.byIcon(Icons.remove_circle_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(repo.removeSeriesCalls, 1);
      expect(find.text('This collection is empty'), findsOneWidget);
    });
  });

  group('librarySeriesPickerProvider', () {
    test('offers every follow, not only the first page of 200', () async {
      // 250 follows: the picker read page 1 alone, so "Zombie 240" could
      // never be added, and searching for it found nothing either.
      final repo = _MutableCollectionsRepository(
        collections: const [],
        details: const {},
        pickerSeries: [
          for (var i = 1; i <= 250; i++)
            _pickerSeriesItem(
              sourceId: 'toonkor',
              seriesKey: 'series-$i',
              title: i == 240 ? 'Zombie $i' : 'Series $i',
            ),
        ],
      );
      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      final offered = await container.read(librarySeriesPickerProvider.future);

      expect(offered, hasLength(250));
      expect(offered.map((s) => s.title), contains('Zombie 240'));
    });
  });
}
