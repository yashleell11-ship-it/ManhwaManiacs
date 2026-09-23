import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/library/models/collection.dart';
import 'package:manhwamaniacs/features/library/models/collection_detail.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/library_query.dart';
import 'package:manhwamaniacs/features/library/models/library_statistics.dart';
import 'package:manhwamaniacs/features/library/models/read_state.dart';
import 'package:manhwamaniacs/features/library/models/reading_history_item.dart';
import 'package:manhwamaniacs/features/library/models/recommendation.dart';
import 'package:manhwamaniacs/features/library/models/series_detail.dart';
import 'package:manhwamaniacs/features/library/models/suggestion.dart';
import 'package:manhwamaniacs/features/library/models/tag.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/library/screens/library_screen.dart';
import 'package:manhwamaniacs/features/library/utils/library_preferences.dart';
import 'package:manhwamaniacs/features/library/widgets/library/series_grid.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_shelf.dart';
import 'package:manhwamaniacs/features/sources/models/source.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';
import 'package:manhwamaniacs/features/sources/providers/sources_provider.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

/// `LibraryRepository` double for the Library (followed) browse screen. Only
/// [listSeries] (search/filter/sort all funnel through it — see
/// `fetchLibraryListPage`), [patchSeries] (favorite toggling) and
/// [follow]/[unfollow] (the long-press "Remove from library" and its undo)
/// are wired; everything else throws so an unexpected call fails loudly
/// instead of silently returning empty data.
class _FakeLibraryRepository implements LibraryRepository {
  _FakeLibraryRepository(this._items);

  final List<FollowedSeries> _items;
  String? lastSearch;
  String? lastReadingStatus;
  String? lastSort;
  bool? lastIsFavorite;

  /// Followed ids passed to [unfollow], in call order.
  final List<int> unfollowed = [];

  /// Identities passed to [follow], in call order.
  final List<({String sourceId, String seriesKey})> refollowed = [];

  /// The last [patchSeries] call, so the undo can be checked for restoring
  /// the shelf metadata a re-follow does not carry over.
  ({int id, bool? isFavorite, String? readingStatus})? lastPatch;

  /// Makes [unfollow] fail, to exercise the "put the card back" path.
  bool failUnfollow = false;

  /// Rows taken out by [unfollow]. A re-follow gets title and cover back from
  /// the server's source cache, so the double keeps them here — but not the
  /// shelf metadata, which the deleted row took with it.
  final Map<String, FollowedSeries> _unfollowedRows = {};
  int _nextFollowedId = 100;

  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? sort,
    String? search,
    String? readingStatus,
    bool? isFavorite,
  }) async {
    lastSort = sort;
    lastReadingStatus = readingStatus;
    lastSearch = search;
    lastIsFavorite = isFavorite;

    var items = List<FollowedSeries>.from(_items);
    if (search != null && search.isNotEmpty) {
      items = items
          .where((item) => item.title.toLowerCase().contains(search.toLowerCase()))
          .toList();
    }
    if (readingStatus != null) {
      items = items.where((item) => item.readingStatus == readingStatus).toList();
    }
    if (isFavorite != null) {
      items = items.where((item) => item.isFavorite == isFavorite).toList();
    }
    return Ok(
      PagedResult(
        items: items,
        total: items.length,
        page: 1,
        perPage: perPage,
        hasNext: false,
      ),
    );
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
    lastPatch =
        (id: followedId, isFavorite: isFavorite, readingStatus: readingStatus);
    final current = _items.firstWhere((series) => series.id == followedId);
    return Ok(current.copyWith(isFavorite: isFavorite, readingStatus: readingStatus));
  }

  @override
  Future<Result<SeriesDetail>> getSeries(int followedId) => throw UnimplementedError();

  @override
  Future<Result<FollowedSeries>> follow({
    required String sourceId,
    required String seriesKey,
  }) async {
    refollowed.add((sourceId: sourceId, seriesKey: seriesKey));
    final previous = _unfollowedRows.remove(seriesKey);
    // Mirrors the backend: a re-follow is a brand new `followed_series` row,
    // so it comes back with default shelf metadata regardless of what the
    // deleted one held.
    final row = FollowedSeries(
      id: _nextFollowedId++,
      sourceId: sourceId,
      seriesKey: seriesKey,
      title: previous?.title ?? seriesKey,
      coverUrl: previous?.coverUrl ?? '',
      isFavorite: false,
      readingStatus: 'reading',
      notify: false,
      sortOrder: 0,
      contentRating: 'safe',
      rating: 'safe',
      chapterCount: previous?.chapterCount ?? 0,
    );
    _items.add(row);
    return Ok(row);
  }

  @override
  Future<Result<void>> unfollow(int followedId) async {
    if (failUnfollow) {
      return const Err(UnknownError(message: 'unfollow refused'));
    }
    unfollowed.add(followedId);
    final row = _items.firstWhere((series) => series.id == followedId);
    _unfollowedRows[row.seriesKey] = row;
    _items.remove(row);
    return const Ok(null);
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

FollowedSeries _series({
  required int id,
  required String title,
  String seriesKey = 'series',
  // The fixture connector the novels tests tag as a novel source; anything
  // else is a row that stays manga.
  String sourceId = 'asurascans',
  bool isFavorite = false,
  String readingStatus = 'reading',
  int chapterCount = 10,
  DateTime? createdAt,
  DateTime? updatedAt,
  ReadState? readState,
}) {
  return FollowedSeries(
    id: id,
    sourceId: sourceId,
    seriesKey: seriesKey,
    title: title,
    coverUrl: '',
    isFavorite: isFavorite,
    readingStatus: readingStatus,
    notify: false,
    sortOrder: 0,
    contentRating: 'safe',
    rating: 'safe',
    chapterCount: chapterCount,
    createdAt: createdAt ?? DateTime(2024),
    updatedAt: updatedAt ?? DateTime(2024, 6),
    readState: readState,
  );
}

Future<Widget> _buildTestApp({
  LibraryRepository? repo,
  bool novels = false,
  Map<String, SourceChapterProgress>? phoneProgress,
}) async {
  SharedPreferences.setMockInitialValues({
    // This phone's own reader records, under profile 1 — the profile
    // [activeProfileOverride] makes active whenever records are given.
    if (phoneProgress != null)
      '$sourceProgressPrefsKey:1': jsonEncode(
        phoneProgress.map((key, value) => MapEntry(key, value.toJson())),
      ),
  });
  final prefs = await SharedPreferences.getInstance();

  return ProviderScope(
    overrides: [
      apiBaseUrlOverride('http://127.0.0.1:8000'),
      sharedPrefsProvider.overrideWithValue(prefs),
      if (phoneProgress != null) activeProfileOverride(),
      // Pinned so the screen does not probe /auth/bootstrap-status for the
      // novels gate on its way to answering "no".
      ...contentModeOverrides(
        mode: novels ? ContentMode.novel : ContentMode.manga,
        novelsEnabled: novels,
      ),
      // A follow row carries a source id and no kind, so this listing is what
      // makes the fixtures novels — and with the gate open the scope would
      // otherwise build its index from a real /sources call.
      sourcesListProvider.overrideWith(
        (ref) async => [
          const SourceSummary(
            id: 'asurascans',
            name: 'Fixture source',
            description: '',
            browsable: true,
            supportsImport: false,
            contentKind: kNovelContentKind,
          ),
        ],
      ),
      libraryRepositoryProvider.overrideWithValue(
        repo ??
            _FakeLibraryRepository([
              _series(
                id: 1,
                title: 'Solo Leveling',
                seriesKey: 'solo-leveling',
                isFavorite: true,
                chapterCount: 179,
                createdAt: DateTime(2024),
                updatedAt: DateTime(2024, 6),
              ),
              _series(
                id: 2,
                title: 'Tower of God',
                seriesKey: 'tower-of-god',
                readingStatus: 'completed',
                chapterCount: 120,
                createdAt: DateTime(2024, 2),
                updatedAt: DateTime(2024, 7),
              ),
            ]),
      ),
    ],
    child: const MaterialApp(home: LibraryScreen()),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LibraryScreen', () {
    testWidgets('renders library grid with series card', (tester) async {
      await tester.pumpWidget(await _buildTestApp());
      await tester.pumpAndSettle();

      expect(find.text('Library'), findsWidgets);
      expect(find.text('Solo Leveling'), findsWidgets);
    });

    testWidgets('shows empty state for search with no results', (tester) async {
      await tester.pumpWidget(await _buildTestApp());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'missing title');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.text('No results found'), findsOneWidget);
    });

    testWidgets('search filters visible series', (tester) async {
      final repo = _FakeLibraryRepository([
        _series(
          id: 1,
          title: 'Solo Leveling',
          seriesKey: 'solo-leveling',
        ),
        _series(
          id: 2,
          title: 'Tower of God',
          seriesKey: 'tower-of-god',
          readingStatus: 'completed',
        ),
      ]);

      await tester.pumpWidget(await _buildTestApp(repo: repo));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Tower');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(repo.lastSearch, 'Tower');
      expect(find.text('Tower of God'), findsWidgets);
      expect(find.text('Solo Leveling'), findsNothing);
    });

    testWidgets('completed filter requests completed reading status', (tester) async {
      final repo = _FakeLibraryRepository([
        _series(
          id: 2,
          title: 'Tower of God',
          seriesKey: 'tower-of-god',
          readingStatus: 'completed',
        ),
      ]);

      await tester.pumpWidget(await _buildTestApp(repo: repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Completed'));
      await tester.pumpAndSettle();

      expect(repo.lastReadingStatus, 'completed');
      expect(find.text('Tower of God'), findsWidgets);
    });

    testWidgets('sort change updates query and persists', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiBaseUrlOverride('http://127.0.0.1:8000'),
            sharedPrefsProvider.overrideWithValue(prefs),
            libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository([])),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<LibrarySort>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recently Added').last);
      await tester.pumpAndSettle();

      expect(readLibraryQuery(prefs).sort, LibrarySort.recentlyAdded);
    });
  });

  group('LibraryScreen multi-select', () {
    testWidgets('Select icon enters selection mode with an empty count',
        (tester) async {
      await tester.pumpWidget(await _buildTestApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();

      expect(find.text('0 selected'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('tapping a card in selection mode toggles it and updates the count',
        (tester) async {
      await tester.pumpWidget(await _buildTestApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Solo Leveling').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Solo Leveling').first);
      await tester.pump();

      expect(find.text('1 selected'), findsOneWidget);

      // Tapping the same card again deselects it.
      await tester.tap(find.text('Solo Leveling').first);
      await tester.pump();

      expect(find.text('0 selected'), findsOneWidget);
    });

    testWidgets('Select all selects every currently-loaded series', (tester) async {
      await tester.pumpWidget(await _buildTestApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.select_all));
      await tester.pump();

      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets('Cancel exits selection mode back to the normal AppBar',
        (tester) async {
      await tester.pumpWidget(await _buildTestApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      // Normal AppBar shows the HeroHeading title, which uppercases to "LIBRARY".
      expect(find.text('LIBRARY'), findsOneWidget);
      expect(find.byIcon(Icons.checklist), findsOneWidget);
    });

    testWidgets(
        'Favorite (N) batch-favorites only the unfavorited selection and exits',
        (tester) async {
      await tester.pumpWidget(await _buildTestApp());
      await tester.pumpAndSettle();

      // Solo Leveling starts favorited, Tower of God does not.
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.select_all));
      await tester.pump();

      await tester.tap(find.textContaining('Favorite (2)'));
      await tester.pumpAndSettle();

      // Selection mode exits automatically once the batch action completes.
      // Normal AppBar shows the HeroHeading title, which uppercases to "LIBRARY".
      expect(find.text('LIBRARY'), findsOneWidget);
      expect(find.byIcon(Icons.checklist), findsOneWidget);
    });
  });

  group('LibraryScreen long-press actions', () {
    /// Long-presses the named card and waits for the actions sheet to open.
    Future<void> openActions(WidgetTester tester, String title) async {
      await tester.ensureVisible(find.text(title).first);
      await tester.pumpAndSettle();
      await tester.longPress(find.text(title).first);
      await tester.pumpAndSettle();
    }

    testWidgets('long-pressing a card opens the sheet with Remove from library',
        (tester) async {
      await tester.pumpWidget(await _buildTestApp());
      await tester.pumpAndSettle();

      await openActions(tester, 'Solo Leveling');

      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Remove from library'), findsOneWidget);
      // The line that stands in for a confirmation dialog.
      expect(find.text('Your reading progress is kept'), findsOneWidget);
    });

    testWidgets('Remove from library unfollows and drops the card from the grid',
        (tester) async {
      final repo = _FakeLibraryRepository([
        _series(id: 1, title: 'Solo Leveling', seriesKey: 'solo-leveling'),
        _series(id: 2, title: 'Tower of God', seriesKey: 'tower-of-god'),
      ]);
      await tester.pumpWidget(await _buildTestApp(repo: repo));
      await tester.pumpAndSettle();

      await openActions(tester, 'Solo Leveling');
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();

      expect(repo.unfollowed, [1]);
      // The grid updates without a manual refresh, and the neighbour stays.
      expect(find.text('Solo Leveling'), findsNothing);
      expect(find.text('Tower of God'), findsWidgets);
      expect(find.textContaining('from your library'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
    });

    testWidgets('Undo re-follows and restores the shelf metadata', (tester) async {
      // Solo Leveling is favorited in the default fixture, so an undo that
      // only re-followed would silently return it unstarred.
      await tester.pumpWidget(await _buildTestApp());
      await tester.pumpAndSettle();

      await openActions(tester, 'Solo Leveling');
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.text('Solo Leveling'), findsWidgets);
      expect(find.text('Tower of God'), findsWidgets);
    });

    testWidgets('Undo patches favorite and reading status onto the new row',
        (tester) async {
      final repo = _FakeLibraryRepository([
        _series(
          id: 1,
          title: 'Solo Leveling',
          seriesKey: 'solo-leveling',
          isFavorite: true,
          readingStatus: 'completed',
        ),
      ]);
      await tester.pumpWidget(await _buildTestApp(repo: repo));
      await tester.pumpAndSettle();

      await openActions(tester, 'Solo Leveling');
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(repo.refollowed.single.seriesKey, 'solo-leveling');
      // A fresh row id, patched back to what the deleted row carried.
      expect(repo.lastPatch?.id, isNot(1));
      expect(repo.lastPatch?.isFavorite, isTrue);
      expect(repo.lastPatch?.readingStatus, 'completed');
    });

    testWidgets('a refused removal puts the card back and says why',
        (tester) async {
      final repo = _FakeLibraryRepository([
        _series(id: 1, title: 'Solo Leveling', seriesKey: 'solo-leveling'),
      ])
        ..failUnfollow = true;
      await tester.pumpWidget(await _buildTestApp(repo: repo));
      await tester.pumpAndSettle();

      await openActions(tester, 'Solo Leveling');
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();

      expect(repo.unfollowed, isEmpty);
      expect(find.text('Solo Leveling'), findsWidgets);
      expect(find.text('Something went wrong — please try again.'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('long-press is suppressed in selection mode', (tester) async {
      await tester.pumpWidget(await _buildTestApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      await openActions(tester, 'Solo Leveling');

      expect(find.text('Remove from library'), findsNothing);
    });
  });

  group("LibraryScreen and this phone's own reading records", () {
    // Before 3.4.0 the Sources-tab reader kept its positions on the phone
    // alone, so the server calls a series read to ch 94 here "not started".
    // The browse grid must say what the Library tab's cards say.
    const notStarted = ReadState(started: false, total: 120);
    final read = SourceChapterProgress(
      page: 3,
      pageCount: 20,
      completed: false,
      updatedAt: DateTime.utc(2026, 9, 20),
    );

    Future<void> pumpRead(WidgetTester tester) async {
      await tester.pumpWidget(
        await _buildTestApp(
          repo: _FakeLibraryRepository([
            _series(
              id: 1,
              title: 'Surviving as a Genius',
              seriesKey: 'surviving-6f7fe6eb',
              readState: notStarted,
            ),
            _series(
              id: 2,
              title: 'Never Opened',
              seriesKey: 'never-opened-6f7fe6eb',
              readState: notStarted,
            ),
          ]),
          phoneProgress: {
            'asurascans:surviving-6f7fe6eb:surviving-6f7fe6eb:93': read,
            'asurascans:surviving-6f7fe6eb:surviving-6f7fe6eb:94': read,
          },
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a grid card shows the chapter the phone reached',
        (tester) async {
      await pumpRead(tester);

      expect(find.byType(SeriesCard), findsNWidgets(2));
      expect(find.text('Ch 94'), findsOneWidget);
      expect(find.text('Not started'), findsOneWidget);
    });

    testWidgets('a list row does too', (tester) async {
      await pumpRead(tester);

      await tester.tap(find.byIcon(Icons.view_list));
      await tester.pumpAndSettle();

      expect(find.byType(SeriesListTile), findsNWidgets(2));
      expect(find.text('Ch 94'), findsOneWidget);
      expect(find.text('Not started'), findsOneWidget);
    });
  });

  group('LibraryScreen shelf laziness', () {
    // Forty follows is a small library and still forty covers: the screen used
    // to build, lay out and start a fetch for every one of them on open,
    // because the grid shrink-wrapped inside a SliverToBoxAdapter.
    _FakeLibraryRepository longShelf() => _FakeLibraryRepository([
          for (var i = 1; i <= 40; i++)
            _series(
              id: i,
              title: 'Series ${i.toString().padLeft(2, '0')}',
              seriesKey: 'series-$i',
            ),
        ]);

    testWidgets('the grid is a sliver, so off-screen cards are never built',
        (tester) async {
      await tester.pumpWidget(await _buildTestApp(repo: longShelf()));
      await tester.pumpAndSettle();

      expect(find.byType(SliverGrid), findsOneWidget);
      // A shrink-wrapping GridView is exactly what must not come back.
      expect(find.byType(GridView), findsNothing);
      expect(find.text('Series 01'), findsWidgets);
      expect(find.text('Series 40'), findsNothing);
    });

    testWidgets('list view mode is lazy too', (tester) async {
      await tester.pumpWidget(await _buildTestApp(repo: longShelf()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.view_list));
      await tester.pumpAndSettle();

      expect(find.byType(SliverList), findsOneWidget);
      expect(find.text('Series 40'), findsNothing);
    });
  });

  group('LibraryScreen in Novels mode', () {
    Future<void> pumpShelf(WidgetTester tester, {LibraryRepository? repo}) async {
      await tester.pumpWidget(await _buildTestApp(repo: repo, novels: true));
      await tester.pumpAndSettle();
    }

    testWidgets('shelves the library instead of gridding it', (tester) async {
      await pumpShelf(tester);

      // A followed novel's cover is an aggregator's placeholder, so the poster
      // grid would be a page of interchangeable rectangles.
      expect(find.byType(NovelShelf), findsOneWidget);
      expect(find.byType(SeriesGrid), findsNothing);
      expect(find.byType(SliverGrid), findsNothing);
      expect(find.text('Solo Leveling'), findsOneWidget);
      expect(find.text('Tower of God'), findsOneWidget);
    });

    testWidgets('counts novels, and drops the controls that size posters',
        (tester) async {
      await pumpShelf(tester);

      expect(find.text('2 novels'), findsOneWidget);
      // Grid/list and the cover-size slider both size covers; a shelf has none,
      // so offering them would be offering two controls that do nothing.
      expect(find.byIcon(Icons.grid_view), findsNothing);
      expect(find.byIcon(Icons.view_list), findsNothing);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('a row states its length and where the reader put it',
        (tester) async {
      await pumpShelf(tester);

      expect(find.text('179 chapters  ·  Reading'), findsOneWidget);
      expect(find.text('120 chapters  ·  Completed'), findsOneWidget);
      // Favourite survives losing the grid's star button: only Solo Leveling
      // is starred in the fixture.
      expect(find.byIcon(Icons.star), findsOneWidget);
    });

    testWidgets('long-pressing a row still opens Remove from library',
        (tester) async {
      final repo = _FakeLibraryRepository([
        _series(id: 1, title: 'Solo Leveling', seriesKey: 'solo-leveling'),
        _series(id: 2, title: 'Tower of God', seriesKey: 'tower-of-god'),
      ]);
      await pumpShelf(tester, repo: repo);

      await tester.ensureVisible(find.text('Solo Leveling'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Solo Leveling'));
      await tester.pumpAndSettle();
      expect(find.text('Remove from library'), findsOneWidget);

      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();

      expect(repo.unfollowed, [1]);
      expect(find.text('Solo Leveling'), findsNothing);
      expect(find.text('Tower of God'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
    });

    testWidgets('tapping a row in selection mode picks it', (tester) async {
      await pumpShelf(tester);

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Solo Leveling'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Solo Leveling'));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.text('Solo Leveling'));
      await tester.pump();
      expect(find.text('0 selected'), findsOneWidget);
    });

    testWidgets('long-press is suppressed on a shelf row too', (tester) async {
      await pumpShelf(tester);

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Solo Leveling'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Solo Leveling'));
      await tester.pumpAndSettle();

      expect(find.text('Remove from library'), findsNothing);
    });

    testWidgets('Select all picks the books on the shelf, not the manhwa too',
        (tester) async {
      // `/library` has no `kind` parameter, so the loaded page holds both
      // modes' follows and the screen filters them. Select all used to reach
      // past that filter into rows the owner could not see.
      final repo = _FakeLibraryRepository([
        _series(id: 1, title: 'Dune', seriesKey: 'dune'),
        _series(
          id: 2,
          title: 'Solo Leveling',
          seriesKey: 'solo-leveling',
          sourceId: 'mangadex',
        ),
      ]);
      await pumpShelf(tester, repo: repo);

      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('Solo Leveling'), findsNothing);
      // The count reports the rows actually shelved, not the server's total
      // for a list it did not scope.
      expect(find.text('1 novel'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.select_all));
      await tester.pump();

      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('an empty shelf does not offer to import a folder of manhua',
        (tester) async {
      await pumpShelf(tester, repo: _FakeLibraryRepository([]));

      expect(find.text('Your shelf is empty'), findsOneWidget);
      expect(
        find.text('Add a book from a novel source to start your shelf.'),
        findsOneWidget,
      );
    });
  });
}
