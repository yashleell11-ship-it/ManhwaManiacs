import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/library/models/collection.dart';
import 'package:manhwamaniacs/features/library/models/collection_detail.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/library_statistics.dart';
import 'package:manhwamaniacs/features/library/models/read_state.dart';
import 'package:manhwamaniacs/features/library/models/reading_history_item.dart';
import 'package:manhwamaniacs/features/library/models/recommendation.dart';
import 'package:manhwamaniacs/features/library/models/series_detail.dart';
import 'package:manhwamaniacs/features/library/models/suggestion.dart';
import 'package:manhwamaniacs/features/library/models/tag.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/library/screens/dashboard_screen.dart';
import 'package:manhwamaniacs/features/library/widgets/home/followed_series_card.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_shelf.dart';
import 'package:manhwamaniacs/features/sources/models/source.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';
import 'package:manhwamaniacs/features/sources/providers/sources_provider.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:manhwamaniacs/shared/widgets/series_cover_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

class _FakeUpdatesNotifier extends UpdatesNotifier {
  _FakeUpdatesNotifier(this.initialState);

  final UpdatesState initialState;
  bool shouldFail = false;

  @override
  Future<UpdatesState> build() async {
    if (shouldFail) throw const UnknownError(message: 'network failure');
    return initialState;
  }
}

FollowedSeries _followed({
  required int id,
  required String title,
  String sourceId = 'asurascans',
  String seriesKey = 'solo-leveling',
  int chapterCount = 120,
  String coverUrl = '',
  ReadState? readState,
}) {
  return FollowedSeries(
    id: id,
    sourceId: sourceId,
    seriesKey: seriesKey,
    title: title,
    coverUrl: coverUrl,
    isFavorite: false,
    readingStatus: 'unread',
    notify: true,
    sortOrder: 0,
    contentRating: 'safe',
    rating: 'safe',
    chapterCount: chapterCount,
    readState: readState,
  );
}

const _notStarted = ReadState(started: false, total: 120);

const _onChapter118 = ReadState(
  started: true,
  chapterKey: 'c118',
  chapterNumber: 118,
  position: 118,
  total: 120,
  latestNumber: 120,
  newCount: 2,
);

UpdateNotification _notification({
  required int id,
  required int followedSeriesId,
  String sourceId = 'asurascans',
  String seriesKey = 'solo-leveling',
  double? chapterNumber,
  String chapterTitle = 'Chapter 121',
  bool isRead = false,
}) {
  return UpdateNotification(
    id: id,
    followedSeriesId: followedSeriesId,
    sourceId: sourceId,
    seriesKey: seriesKey,
    chapterKey: 'ch-$id',
    chapterTitle: chapterTitle,
    chapterNumber: chapterNumber,
    isRead: isRead,
  );
}

/// `LibraryRepository` double for the Library tab's long-press menu. Only
/// [follow]/[unfollow] (Remove from library and its undo) and [patchSeries]
/// (the favorite row, and the metadata an undo puts back) are wired;
/// everything else throws so an unexpected call fails loudly instead of
/// silently returning empty data.
class _FakeLibraryRepository implements LibraryRepository {
  /// Followed ids passed to [unfollow], in call order.
  final List<int> unfollowed = [];

  /// Identities passed to [follow], in call order.
  final List<({String sourceId, String seriesKey})> refollowed = [];

  /// The last [patchSeries] call, so the undo can be checked for restoring
  /// the shelf metadata a re-follow does not carry over.
  ({int id, bool? isFavorite, String? readingStatus})? lastPatch;

  /// Makes [unfollow] fail, to exercise the "put the card back" path.
  bool failUnfollow = false;

  int _nextFollowedId = 100;

  @override
  Future<Result<void>> unfollow(int followedId) async {
    if (failUnfollow) {
      return const Err(UnknownError(message: 'unfollow refused'));
    }
    unfollowed.add(followedId);
    return const Ok(null);
  }

  @override
  Future<Result<FollowedSeries>> follow({
    required String sourceId,
    required String seriesKey,
  }) async {
    refollowed.add((sourceId: sourceId, seriesKey: seriesKey));
    // Mirrors the backend: a re-follow is a brand new `followed_series` row,
    // so it comes back with default shelf metadata regardless of what the
    // deleted one held.
    return Ok(
      _followed(id: _nextFollowedId++, title: seriesKey, seriesKey: seriesKey),
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
    return Ok(
      _followed(id: followedId, title: 'patched').copyWith(
        isFavorite: isFavorite,
        readingStatus: readingStatus,
      ),
    );
  }

  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? sort,
    String? search,
    String? readingStatus,
    bool? isFavorite,
  }) =>
      throw UnimplementedError('the Library tab never lists through this');

  @override
  Future<Result<SeriesDetail>> getSeries(int followedId) =>
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
  Future<Result<List<Collection>>> listCollections() =>
      throw UnimplementedError();

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
  Future<Result<void>> deleteCollection(int collectionId) =>
      throw UnimplementedError();

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
  Future<Result<List<Tag>>> listTags({String? category}) =>
      throw UnimplementedError();

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

Future<Widget> _buildTestApp({
  required UpdatesState state,
  bool shouldFail = false,
  bool novels = false,
  _FakeLibraryRepository? repo,
  Map<String, SourceChapterProgress>? phoneProgress,
  List<ContinueReadingItem>? continueItems,
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
  final notifier = _FakeUpdatesNotifier(state)..shouldFail = shouldFail;

  return ProviderScope(
    overrides: [
      apiBaseUrlOverride('http://127.0.0.1:8000'),
      sharedPrefsProvider.overrideWithValue(prefs),
      if (phoneProgress != null) activeProfileOverride(),
      if (continueItems != null)
        continueReadingProvider.overrideWith((ref) async => continueItems),
      updatesProvider.overrideWith(() => notifier),
      libraryRepositoryProvider
          .overrideWithValue(repo ?? _FakeLibraryRepository()),
      // Pinned so the screen does not probe /auth/bootstrap-status for the
      // novels gate — a real request, with a real pending timer, in a test
      // that never wanted one.
      ...contentModeOverrides(
        mode: novels ? ContentMode.novel : ContentMode.manga,
        novelsEnabled: novels,
      ),
      // A follow row carries a source id and no kind, so this listing is what
      // makes the fixtures novels. Stubbed either way: with the gate open the
      // scope builds its index from a real /sources call otherwise.
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
    ],
    child: const MaterialApp(
      home: DashboardScreen(),
    ),
  );
}

/// Routed variant: the Library tab plus a stub source-detail destination, so
/// a card tap can be asserted to land on the right route with the right
/// (decoded) parameters.
Future<Widget> _buildRoutedTestApp({required UpdatesState state}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final notifier = _FakeUpdatesNotifier(state);

  final router = GoRouter(
    initialLocation: '/library',
    routes: [
      GoRoute(
        path: '/library',
        builder: (_, __) => const DashboardScreen(),
      ),
      GoRoute(
        path: '/sources',
        builder: (_, __) => const Scaffold(body: Text('SOURCES LIST')),
        routes: [
          GoRoute(
            path: ':sourceId/series/:seriesId',
            builder: (_, state) => Scaffold(
              body: Text(
                'DETAIL ${state.pathParameters['sourceId']}'
                '|${state.pathParameters['seriesId']}',
              ),
            ),
          ),
        ],
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      apiBaseUrlOverride('http://127.0.0.1:8000'),
      sharedPrefsProvider.overrideWithValue(prefs),
      updatesProvider.overrideWith(() => notifier),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DashboardScreen', () {
    testWidgets('renders followed series grid', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildTestApp(
          state: UpdatesState(
            notifications: const [],
            unreadCount: 0,
            followed: [
              _followed(id: 1, title: 'Solo Leveling'),
              _followed(id: 2, title: 'Tower of God', seriesKey: 'tower-of-god'),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Every followed series is rendered as a card.
      expect(find.text('Solo Leveling'), findsOneWidget);
      expect(find.text('Tower of God'), findsOneWidget);
      expect(find.text('2 series followed'), findsOneWidget);

      // ...and nothing else. The hero block, the cover marquee, the ABOUT
      // marketing card and their duplicate CTAs are gone.
      expect(find.text('YOUR FOLLOWED SERIES, TOGETHER'), findsNothing);
      expect(find.text('ABOUT'), findsNothing);
      expect(find.textContaining('one warm, quiet place'), findsNothing);
      expect(find.text('YOUR MANGA COLLECTION'), findsNothing);
      expect(find.text('Browse'), findsNothing);
    });

    testWidgets('offers exactly one Browse affordance when the grid has items',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildTestApp(
          state: UpdatesState(
            notifications: const [],
            unreadCount: 0,
            followed: [_followed(id: 1, title: 'Solo Leveling')],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // One unobtrusive app-bar action, and no Browse Sources pill anywhere.
      expect(find.byTooltip('Browse Sources'), findsOneWidget);
      expect(find.text('BROWSE SOURCES'), findsNothing);
      expect(find.text('Browse Sources'), findsNothing);
    });

    testWidgets('resolves a relative cover URL against the API base',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildTestApp(
          state: UpdatesState(
            notifications: const [],
            unreadCount: 0,
            followed: [
              _followed(
                id: 1,
                title: 'Omniscient Reader',
                coverUrl: '/sources/asurascans/series/orv/cover',
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Omniscient Reader'), findsOneWidget);

      const expectedUrl =
          'http://127.0.0.1:8000/sources/asurascans/series/orv/cover';
      final covers = tester
          .widgetList<SeriesCoverImage>(find.byType(SeriesCoverImage))
          .map((w) => w.url)
          .toList();
      expect(covers, contains(expectedUrl));
    });

    testWidgets('never claims "0 chapters" for a freshly-followed series',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildTestApp(
          state: UpdatesState(
            notifications: const [],
            unreadCount: 0,
            followed: [
              // chapterCount is 0 until the backend's first update check
              // runs — the card must stay silent rather than lie.
              _followed(
                id: 1,
                title: "Sword God's Livestream",
                chapterCount: 0,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text("Sword God's Livestream"), findsOneWidget);
      expect(find.text('0 chapters'), findsNothing);
      expect(find.textContaining('chapters'), findsNothing);
    });

    testWidgets('surfaces the latest chapter and unread count when known',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildTestApp(
          state: UpdatesState(
            notifications: [
              _notification(id: 1, followedSeriesId: 1, chapterNumber: 120),
              _notification(id: 2, followedSeriesId: 1, chapterNumber: 121),
              // Read notification: counts toward "latest", not toward "new".
              _notification(
                id: 3,
                followedSeriesId: 1,
                chapterNumber: 119,
                isRead: true,
              ),
              // Another series' notification must not leak into this card.
              _notification(id: 4, followedSeriesId: 99, chapterNumber: 400),
            ],
            unreadCount: 3,
            followed: [
              _followed(id: 1, title: 'Solo Leveling', chapterCount: 0),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Latest: Chapter 121'), findsOneWidget);
      expect(find.text('2 NEW'), findsOneWidget);
    });

    testWidgets('says where the reader is instead of what was notified',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildTestApp(
          state: UpdatesState(
            notifications: [
              // Unread notifications for a series never opened: the pill
              // used to count these, and they are not "new" to this reader.
              _notification(id: 1, followedSeriesId: 1, chapterNumber: 120),
              _notification(id: 2, followedSeriesId: 1, chapterNumber: 121),
              _notification(id: 3, followedSeriesId: 1, chapterNumber: 122),
            ],
            unreadCount: 3,
            followed: [
              _followed(id: 1, title: 'Unopened', readState: _notStarted),
              _followed(
                id: 2,
                title: 'Half read',
                seriesKey: 'half-read',
                readState: _onChapter118,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Not started'), findsOneWidget);
      expect(find.text('Ch 118 of 120'), findsOneWidget);
      expect(find.text('2 NEW'), findsOneWidget);
      expect(find.text('3 NEW'), findsNothing);
      expect(find.textContaining('Latest:'), findsNothing);
    });

    testWidgets(
        "a server 'Not started' gives way to where this phone's reader got to",
        (tester) async {
      // Before 3.4.0 the Sources-tab reader kept its positions on the phone
      // alone, so the server says "not started" for a series read to ch 94
      // here. The card must not contradict the series page one tap away.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final read = SourceChapterProgress(
        page: 3,
        pageCount: 20,
        completed: false,
        updatedAt: DateTime.utc(2026, 9, 20),
      );
      await tester.pumpWidget(
        await _buildTestApp(
          state: UpdatesState(
            notifications: const [],
            unreadCount: 0,
            followed: [
              _followed(
                id: 1,
                title: 'Surviving as a Genius',
                seriesKey: 'surviving-6f7fe6eb',
                readState: _notStarted,
              ),
              _followed(
                id: 2,
                title: 'Nano Machine',
                // Followed under an older slug suffix than the one the
                // reader was opened with from Browse.
                seriesKey: 'nano-machine-08677664',
                readState: _notStarted,
              ),
              _followed(
                id: 3,
                title: 'Never Opened',
                seriesKey: 'never-opened-6f7fe6eb',
                readState: _notStarted,
              ),
            ],
          ),
          phoneProgress: {
            'asurascans:surviving-6f7fe6eb:surviving-6f7fe6eb:93': read,
            'asurascans:surviving-6f7fe6eb:surviving-6f7fe6eb:94': read,
            'asurascans:nano-machine-6f7fe6eb:nano-machine-6f7fe6eb:330': read,
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Ch 94'), findsOneWidget);
      expect(find.text('Ch 330'), findsOneWidget);
      // Only the series this phone never opened still says so.
      expect(find.text('Not started'), findsOneWidget);
    });

    testWidgets('a Continue card is named after its series', (tester) async {
      // The continue payload carried no title, so the strip said "Chapter 12,
      // page 7" with nothing to tell a dozen series apart. A server older than
      // the `title` field still sends none: the follows name the row.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildTestApp(
          state: UpdatesState(
            notifications: const [],
            unreadCount: 0,
            followed: [_followed(id: 1, title: 'Solo Leveling')],
          ),
          continueItems: const [
            ContinueReadingItem(
              sourceId: 'asurascans',
              seriesKey: 'solo-leveling',
              chapterKey: 'solo-leveling:12',
              chapterNumber: 12,
              lastPage: 7,
              pageCount: 20,
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Continue reading'), findsOneWidget);
      // Once on the card over the strip, once under its cover on the shelf.
      expect(find.text('Solo Leveling'), findsNWidgets(2));
      expect(find.text('Chapter 12 · Page 7 of 20'), findsOneWidget);
    });

    testWidgets('falls back to the known chapter count once it is populated',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildTestApp(
          state: UpdatesState(
            notifications: const [],
            unreadCount: 0,
            followed: [
              // The fixture's chapterCount default (120) stands in for a
              // series the update checker has already seeded.
              _followed(id: 1, title: 'Solo Leveling'),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('120 chapters'), findsOneWidget);
    });

    testWidgets('tapping a followed series opens its source detail route',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildRoutedTestApp(
          state: UpdatesState(
            notifications: const [],
            unreadCount: 0,
            followed: [
              _followed(
                id: 1,
                title: 'Solo Leveling',
                sourceId: 'toonily',
                // Slash-bearing keys are real (toonily-family sources); the
                // path builder must encode them so go_router still matches.
                seriesKey: 'series/solo-leveling',
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Solo Leveling'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('DETAIL toonily|series/solo-leveling'), findsOneWidget);
    });

    testWidgets('shows empty state when nothing is followed', (tester) async {
      await tester.pumpWidget(
        await _buildTestApp(
          state: const UpdatesState(
            notifications: [],
            unreadCount: 0,
            followed: [],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Your library is empty'), findsOneWidget);
      expect(
        find.text('Follow series from Sources to build your warm little shelf.'),
        findsOneWidget,
      );
      // The empty state owns the single Browse affordance; the app-bar action
      // stays hidden so there is never more than one.
      expect(find.text('BROWSE SOURCES'), findsOneWidget);
      expect(find.byTooltip('Browse Sources'), findsNothing);
    });

    testWidgets('shows error state on failure', (tester) async {
      await tester.pumpWidget(
        await _buildTestApp(
          state: const UpdatesState(
            notifications: [],
            unreadCount: 0,
            followed: [],
          ),
          shouldFail: true,
        ),
      );
      await tester.pump();

      // Error state now shows an "Oops" HeroHeading + the error's userMessage;
      // the retry control keeps its FilledButton.icon "Try Again" label.
      expect(find.text('Something went wrong — please try again.'), findsOneWidget);
      expect(find.text('Try Again'), findsOneWidget);
    });
  });

  group('DashboardScreen in Novels mode', () {
    /// Pumps the Library tab with the fixture source tagged as a novel
    /// connector. The extra pump is the `/sources` listing resolving: until it
    /// does, the source-mode index is empty and every follow reads as manga.
    Future<void> pumpShelf(WidgetTester tester, UpdatesState state) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(await _buildTestApp(state: state, novels: true));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('shelves the follows instead of gridding their covers',
        (tester) async {
      await pumpShelf(
        tester,
        UpdatesState(
          notifications: const [],
          unreadCount: 0,
          followed: [
            _followed(id: 1, title: 'The Count of Monte Cristo'),
            _followed(id: 2, title: 'Dune', seriesKey: 'dune'),
          ],
        ),
      );

      // The whole point: a novel cover is an aggregator's placeholder, so the
      // poster grid must not be what the owner sees here.
      expect(find.byType(NovelShelf), findsOneWidget);
      expect(find.byType(FollowedSeriesCard), findsNothing);
      expect(find.text('The Count of Monte Cristo'), findsOneWidget);
      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('2 novels on your shelf'), findsOneWidget);
    });

    testWidgets('a shelved book keeps its unread badge and latest chapter',
        (tester) async {
      await pumpShelf(
        tester,
        UpdatesState(
          notifications: [
            _notification(id: 1, followedSeriesId: 1, chapterNumber: 120),
            _notification(id: 2, followedSeriesId: 1, chapterNumber: 121),
            _notification(
              id: 3,
              followedSeriesId: 1,
              chapterNumber: 119,
              isRead: true,
            ),
          ],
          unreadCount: 2,
          followed: [_followed(id: 1, title: 'Dune', chapterCount: 0)],
        ),
      );

      expect(find.text('2 NEW'), findsOneWidget);
      expect(find.textContaining('Latest: Chapter 121'), findsOneWidget);
    });

    testWidgets('a shelved book says where the reader is, with its new count',
        (tester) async {
      await pumpShelf(
        tester,
        UpdatesState(
          notifications: const [],
          unreadCount: 0,
          followed: [
            _followed(id: 1, title: 'Dune', readState: _onChapter118),
            _followed(
              id: 2,
              title: 'Unopened',
              seriesKey: 'unopened',
              readState: _notStarted,
            ),
          ],
        ),
      );

      expect(find.textContaining('Ch 118 of 120'), findsOneWidget);
      expect(find.text('2 NEW'), findsOneWidget);
      expect(find.textContaining('Not started'), findsOneWidget);
    });

    testWidgets("a shelved book this phone has read is not 'Not started'",
        (tester) async {
      // The shelf row says what the grid card says: the phone's own record
      // over a server that has none. A chapter key with no number in it
      // cannot say which chapter, only that the book was opened.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildTestApp(
          state: UpdatesState(
            notifications: const [],
            unreadCount: 0,
            followed: [
              _followed(
                id: 1,
                title: 'Dune',
                seriesKey: 'dune',
                readState: _notStarted,
              ),
            ],
          ),
          novels: true,
          phoneProgress: {
            'asurascans:dune:dune/chapter-one': SourceChapterProgress(
              page: 40,
              pageCount: 100,
              completed: false,
              updatedAt: DateTime.utc(2026, 9, 20),
            ),
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(NovelShelf), findsOneWidget);
      expect(find.textContaining('Started'), findsOneWidget);
      expect(find.textContaining('Not started'), findsNothing);
    });

    testWidgets('shows length and latest chapter together, not one or other',
        (tester) async {
      // The card had one muted line and had to choose; a shelf row has a
      // metadata run and can say both.
      await pumpShelf(
        tester,
        UpdatesState(
          notifications: [
            _notification(id: 1, followedSeriesId: 1, chapterNumber: 121),
          ],
          unreadCount: 1,
          followed: [_followed(id: 1, title: 'Dune', chapterCount: 117)],
        ),
      );

      expect(find.textContaining('117 chapters'), findsOneWidget);
      expect(find.textContaining('Latest: Chapter 121'), findsOneWidget);
    });

    testWidgets('never claims "0 chapters" on a shelf row either',
        (tester) async {
      await pumpShelf(
        tester,
        UpdatesState(
          notifications: const [],
          unreadCount: 0,
          followed: [_followed(id: 1, title: 'Dune', chapterCount: 0)],
        ),
      );

      expect(find.text('Dune'), findsOneWidget);
      expect(find.textContaining('chapters'), findsNothing);
    });

    testWidgets('an empty shelf asks for a book, not a folder of manhua',
        (tester) async {
      await pumpShelf(
        tester,
        const UpdatesState(notifications: [], unreadCount: 0, followed: []),
      );

      expect(find.text('Your shelf is empty'), findsOneWidget);
      expect(
        find.text('Add a book from a novel source to start your shelf.'),
        findsOneWidget,
      );
    });

    testWidgets('manga mode is untouched — still the poster grid',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildTestApp(
          state: UpdatesState(
            notifications: const [],
            unreadCount: 0,
            followed: [_followed(id: 1, title: 'Solo Leveling')],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(NovelShelf), findsNothing);
      expect(find.byType(FollowedSeriesCard), findsOneWidget);
      expect(find.text('1 series followed'), findsOneWidget);
    });
  });

  /// The long-press menu, on the tab the owner actually lands on.
  ///
  /// It shipped on the browse screen under this tab first — `/library/browse`,
  /// which nothing on the Library tab routes to — so the feature existed and
  /// was unreachable. These pin it to the surface it is reached from.
  group('DashboardScreen long-press actions', () {
    Future<void> pumpShelf(
      WidgetTester tester,
      UpdatesState state, {
      _FakeLibraryRepository? repo,
      bool novels = false,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        await _buildTestApp(state: state, repo: repo, novels: novels),
      );
      await tester.pumpAndSettle();
    }

    UpdatesState oneFollow({
      String title = 'Solo Leveling',
      bool isFavorite = false,
    }) =>
        UpdatesState(
          notifications: const [],
          unreadCount: 0,
          followed: [
            _followed(id: 1, title: title).copyWith(isFavorite: isFavorite),
          ],
        );

    Future<void> openActions(WidgetTester tester, String title) async {
      await tester.longPress(find.text(title).first);
      await tester.pumpAndSettle();
    }

    testWidgets('long-pressing a card opens the sheet with Remove from library',
        (tester) async {
      await pumpShelf(tester, oneFollow());

      await openActions(tester, 'Solo Leveling');

      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Add to favorites'), findsOneWidget);
      expect(find.text('Remove from library'), findsOneWidget);
      // The line that stands in for a confirmation dialog.
      expect(find.text('Your reading progress is kept'), findsOneWidget);
    });

    testWidgets('long-pressing a shelf row in Novels mode opens it too',
        (tester) async {
      await pumpShelf(tester, oneFollow(title: 'Dune'), novels: true);
      expect(find.byType(NovelShelf), findsOneWidget);

      await openActions(tester, 'Dune');

      expect(find.text('Remove from library'), findsOneWidget);
    });

    testWidgets('Remove from library unfollows and drops the card',
        (tester) async {
      final repo = _FakeLibraryRepository();
      await pumpShelf(
        tester,
        UpdatesState(
          notifications: const [],
          unreadCount: 0,
          followed: [
            _followed(id: 1, title: 'Solo Leveling'),
            _followed(id: 2, title: 'Tower of God', seriesKey: 'tower-of-god'),
          ],
        ),
        repo: repo,
      );

      await openActions(tester, 'Solo Leveling');
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();

      expect(repo.unfollowed, [1]);
      // The shelf answers without a refetch, and the neighbour stays put.
      expect(find.text('Solo Leveling'), findsNothing);
      expect(find.text('Tower of God'), findsOneWidget);
      expect(find.text('1 series followed'), findsOneWidget);
      expect(find.textContaining('from your library'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
    });

    testWidgets('Remove from library works on a shelf row as well',
        (tester) async {
      final repo = _FakeLibraryRepository();
      await pumpShelf(
        tester,
        oneFollow(title: 'Dune'),
        repo: repo,
        novels: true,
      );

      await openActions(tester, 'Dune');
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();

      expect(repo.unfollowed, [1]);
      expect(find.text('Dune'), findsNothing);
      expect(find.text('Undo'), findsOneWidget);
    });

    testWidgets('Undo re-follows and puts the card back', (tester) async {
      final repo = _FakeLibraryRepository();
      await pumpShelf(tester, oneFollow(), repo: repo);

      await openActions(tester, 'Solo Leveling');
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();
      expect(find.text('Solo Leveling'), findsNothing);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(repo.refollowed.single.seriesKey, 'solo-leveling');
      expect(find.text('solo-leveling'), findsOneWidget);
      expect(find.text('1 series followed'), findsOneWidget);
    });

    testWidgets('Undo patches the shelf metadata onto the new row',
        (tester) async {
      // A re-follow is a fresh row at default metadata, so an undo that only
      // re-followed would silently return the series unstarred.
      final repo = _FakeLibraryRepository();
      await pumpShelf(tester, oneFollow(isFavorite: true), repo: repo);

      await openActions(tester, 'Solo Leveling');
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      // A fresh row id, patched back to what the deleted row carried.
      expect(repo.lastPatch?.id, isNot(1));
      expect(repo.lastPatch?.isFavorite, isTrue);
    });

    testWidgets('a refused removal puts the card back and says why',
        (tester) async {
      final repo = _FakeLibraryRepository()..failUnfollow = true;
      await pumpShelf(tester, oneFollow(), repo: repo);

      await openActions(tester, 'Solo Leveling');
      await tester.tap(find.text('Remove from library'));
      await tester.pumpAndSettle();

      expect(repo.unfollowed, isEmpty);
      expect(find.text('Solo Leveling'), findsOneWidget);
      expect(
        find.text('Something went wrong — please try again.'),
        findsOneWidget,
      );
      expect(find.text('Undo'), findsNothing);
    });

    testWidgets('the menu is the only long-press on this tab', (tester) async {
      // The browse screen guards its long-press with `selection.active`; this
      // one does not, because there is no multi-select here to fire under.
      // Pinned so the guard is added back the day a selection mode is.
      await pumpShelf(tester, oneFollow());

      expect(find.byIcon(Icons.checklist), findsNothing);
      expect(find.byTooltip('Select series'), findsNothing);

      await openActions(tester, 'Solo Leveling');
      expect(find.text('Remove from library'), findsOneWidget);
    });
  });
}
