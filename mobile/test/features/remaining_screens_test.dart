import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:manhwamaniacs/features/library/models/suggestion.dart';
import 'package:manhwamaniacs/features/library/models/tag.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/library/screens/reading_history_screen.dart';
import 'package:manhwamaniacs/features/library/screens/recommendations_screen.dart';
import 'package:manhwamaniacs/features/library/screens/statistics_screen.dart';
import 'package:manhwamaniacs/features/more/screens/more_screen.dart';
import 'package:manhwamaniacs/features/reader/models/bookmark.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest_window.dart';
import 'package:manhwamaniacs/features/reader/models/reader_chapter.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/repositories/reader_repository.dart';
import 'package:manhwamaniacs/features/settings/models/app_version.dart';
import 'package:manhwamaniacs/features/settings/providers/app_update_provider.dart';
import 'package:manhwamaniacs/features/settings/screens/settings_screen.dart';
import 'package:manhwamaniacs/features/sources/models/source.dart';
import 'package:manhwamaniacs/features/sources/models/source_pin.dart';
import 'package:manhwamaniacs/features/sources/models/source_search_group.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/repositories/sources_repository.dart';
import 'package:manhwamaniacs/features/sources/screens/sources_list_screen.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/models/update_settings.dart';
import 'package:manhwamaniacs/features/updates/repositories/updates_repository.dart';
import 'package:manhwamaniacs/features/updates/screens/updates_screen.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_overrides.dart';

FollowedSeries _series({required int id, required String title}) {
  return FollowedSeries(
    id: id,
    sourceId: 'test',
    seriesKey: 'solo',
    title: title,
    coverUrl: '',
    isFavorite: false,
    readingStatus: 'reading',
    notify: true,
    sortOrder: 0,
    contentRating: 'safe',
    rating: 'safe',
    chapterCount: 10,
    createdAt: DateTime(2024),
    updatedAt: DateTime(2024, 6),
  );
}

/// `LibraryRepository` double. Only the methods each screen under test
/// actually calls are wired; everything else throws so an unexpected call
/// fails loudly instead of silently returning empty data.
class _FakeIntelligenceRepository implements LibraryRepository {
  @override
  Future<Result<List<RecommendationGenre>>> recommendations({int limit = 10}) async =>
      const Ok([RecommendationGenre(genre: 'Action', weight: 5)]);

  @override
  Future<Result<LibraryStatistics>> statistics() async => const Ok(
        LibraryStatistics(
          followedTotal: 10,
          favorites: 1,
          byReadingStatus: {'reading': 3, 'completed': 2},
          chaptersCompleted: 100,
        ),
      );

  @override
  Future<Result<List<ReadingHistoryItem>>> readingHistory({
    int limit = 50,
    int offset = 0,
    bool bySeries = true,
  }) async =>
      Ok([
        ReadingHistoryItem(
          id: 1,
          sourceId: 'test',
          seriesKey: 'solo',
          chapterKey: '10',
          chapterNumber: 10,
          lastPage: 12,
          pageCount: 12,
          isCompleted: true,
          lastReadAt: DateTime(2024, 6),
          seriesTitle: 'Solo Leveling',
        ),
      ]);

  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? sort,
    String? search,
    String? readingStatus,
    bool? isFavorite,
  }) async =>
      Ok(PagedResult(items: const [], total: 0, page: 1, perPage: perPage, hasNext: false));

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
  Future<Result<PagedResult<FollowedSeries>>> search(
    String query, {
    int page = 1,
    int perPage = 20,
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

class _EmptyReaderRepository implements ReaderRepository {
  @override
  Future<Result<List<Bookmark>>> listBookmarks({
    String? sourceId,
    String? seriesKey,
    DateTime? since,
    bool includeDeleted = false,
    int? limit,
  }) async =>
      const Ok([]);

  @override
  Future<Result<void>> deleteBookmark(int bookmarkId) => throw UnimplementedError();

  @override
  Future<Result<BookmarkSyncResult>> syncBookmarks(List<BookmarkOp> ops) =>
      throw UnimplementedError();

  @override
  Future<Result<ChapterManifest>> manifest({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<ReadingProgress>> saveProgress(ProgressPush push) => throw UnimplementedError();

  @override
  Future<Result<({int saved, int advanced})>> saveProgressBatch(List<ProgressPush> pushes) =>
      throw UnimplementedError();

  @override
  Future<Result<List<ReadingProgress>>> seriesProgress({
    required String sourceId,
    required String seriesKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<ChapterManifestWindow>> manifestWindow({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) =>
      throw UnimplementedError();
}

/// Followed-series list backing the `updatesProvider`'s shared cache — the
/// only `LibraryRepository` method the Updates/More screens' provider chain
/// actually reaches.
class _FollowedOnlyLibraryRepository extends _FakeIntelligenceRepository {
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
          items: [_series(id: 1, title: 'Solo Leveling')],
          total: 1,
          page: 1,
          perPage: perPage,
          hasNext: false,
        ),
      );
}

class _FakeUpdatesRepository implements UpdatesRepository {
  @override
  Future<Result<List<UpdateNotification>>> listNotifications({
    bool unreadOnly = false,
    int limit = 100,
  }) async =>
      Ok([
        UpdateNotification(
          id: 1,
          followedSeriesId: 1,
          sourceId: 'test',
          seriesKey: 'solo',
          chapterKey: 'ch-1',
          chapterTitle: 'New Chapter',
          isRead: false,
          createdAt: DateTime(2024, 6),
        ),
      ]);

  @override
  Future<Result<int>> getUnreadCount() async => const Ok(1);

  @override
  Future<Result<void>> markRead(int notificationId) async => const Ok(null);

  @override
  Future<Result<void>> markAllRead() async => const Ok(null);

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

class _FakeSourcesRepository implements SourcesRepository {
  @override
  Future<Result<List<SourceSummary>>> listSources() async => const Ok([
        SourceSummary(
          id: 'asura',
          name: 'Asura Scans',
          description: 'Test source connector',
          browsable: true,
          supportsImport: true,
        ),
      ]);

  /// The Sources screen renders a pinned section, so this has to answer even
  /// though this test only asserts on the row list.
  @override
  Future<Result<List<SourcePin>>> listPins() async => const Ok([]);

  @override
  Future<Result<List<SourcePin>>> replacePins(List<String> sourceIds) =>
      throw UnimplementedError();

  @override
  Future<Result<GroupedSearchResult>> searchGrouped(
    String query, {
    int page = 1,
    int perPage = 40,
  }) =>
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
  Future<Result<SourceSeriesSummary>> getSeries(String sourceId, String seriesId) =>
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

Future<Widget> _wrap(
  Widget child, {
  required List<Override> overrides,
  // The update banner branches on the platform, which the screens read from
  // the theme rather than dart:io so both branches stay reachable here.
  TargetPlatform platform = TargetPlatform.android,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      apiBaseUrlOverride('http://127.0.0.1:8000'),
      sharedPrefsProvider.overrideWithValue(prefs),
      readerRepositoryProvider.overrideWithValue(_EmptyReaderRepository()),
      ...overrides,
      // Pinned so the screen does not probe /auth/bootstrap-status for the
      // novels gate — a real request, with a real pending timer, in a test
      // that never wanted one.
      ...contentModeOverrides(),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: platform),
      home: child,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Remaining screens', () {
    testWidgets('StatisticsScreen renders stat cards', (tester) async {
      // The fake's payload has no reading sessions, so the screen leads with
      // the "no reading recorded" card and the library grid sits below the
      // default 600px fold of the lazy ListView — give it a tall surface.
      await tester.binding.setSurfaceSize(const Size(600, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        await _wrap(
          const StatisticsScreen(),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(_FakeIntelligenceRepository()),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Title is rendered by HeroHeading, which uppercases its text.
      expect(find.text('READING STATISTICS'), findsWidgets);
      // No sessions recorded → the honest empty state, not a wall of zeroes.
      expect(find.text('No reading recorded yet'), findsOneWidget);
      expect(find.text('Followed Series'), findsOneWidget);
    });

    testWidgets('RecommendationsScreen renders a genre chip', (tester) async {
      await tester.pumpWidget(
        await _wrap(
          const RecommendationsScreen(),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(_FakeIntelligenceRepository()),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Action'), findsWidgets);
    });

    testWidgets('ReadingHistoryScreen renders a book, not a position',
        (tester) async {
      await tester.pumpWidget(
        await _wrap(
          const ReadingHistoryScreen(),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(_FakeIntelligenceRepository()),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // History is a shelf of books now: the title leads and the position is
      // the caption under it. Asserting the title is what stops a regression
      // to the old rows, which named a chapter over a raw connector id and
      // never said which book it was.
      expect(find.text('Solo Leveling'), findsWidgets);
      expect(find.textContaining('Ch. 10'), findsWidgets);
    });

    testWidgets('UpdatesScreen renders notifications and followed series',
        (tester) async {
      await tester.pumpWidget(
        await _wrap(
          const UpdatesScreen(),
          overrides: [
            updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
            libraryRepositoryProvider.overrideWithValue(_FollowedOnlyLibraryRepository()),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // "Check all now" is now a PrimaryPillButton, which uppercases its label.
      expect(find.text('CHECK ALL NOW'), findsOneWidget);
      expect(find.text('New Chapter'), findsWidgets);
      expect(find.text('Solo Leveling'), findsWidgets);
    });

    testWidgets('SourcesListScreen renders source card', (tester) async {
      await tester.pumpWidget(
        await _wrap(
          const SourcesListScreen(),
          overrides: [
            sourcesRepositoryProvider.overrideWithValue(_FakeSourcesRepository()),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Asura Scans'), findsWidgets);
    });

    testWidgets('SettingsScreen renders tabs', (tester) async {
      await tester.pumpWidget(
        await _wrap(const SettingsScreen(), overrides: [
          appUpdateProvider.overrideWith((ref) async => null),
          libraryRepositoryProvider.overrideWithValue(_FakeIntelligenceRepository()),
          updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
        ],),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('General'), findsOneWidget);
      expect(find.text('Server'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
    });

    testWidgets('MoreScreen renders navigation tiles', (tester) async {
      // MoreScreen is a lazy ListView; the "Settings" tile sits below the fold
      // of the default 800x600 surface and isn't built until scrolled into
      // view. Give the test a tall surface so every tile is laid out.
      await tester.binding.setSurfaceSize(const Size(600, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        await _wrap(
          const MoreScreen(),
          overrides: [
            updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
            libraryRepositoryProvider.overrideWithValue(_FollowedOnlyLibraryRepository()),
            appUpdateProvider.overrideWith((ref) async => null),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Updates'), findsWidgets);
      expect(find.text('Collections'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('MoreScreen shows update banner when update available',
        (tester) async {
      const updateInfo = AppVersionInfo(
        localVersion: '1.0.0',
        localBuild: 1,
        remoteVersion: '1.1.0',
        remoteBuild: 2,
        downloadUrl: 'http://localhost:8000/app/download',
        channel: AppUpdateChannel.apk,
      );
      final widget = await _wrap(
        const MoreScreen(),
        overrides: [
          updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
          libraryRepositoryProvider.overrideWithValue(_FollowedOnlyLibraryRepository()),
          appUpdateProvider.overrideWith((ref) async => updateInfo),
        ],
      );
      await tester.pumpWidget(widget);
      // runAsync lets the Dart event loop drain so FutureProvider resolves.
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();
      // The list is a virtualized SliverList — the banner sits near the
      // bottom (below the new Downloads tile), past the default cache
      // extent, so it isn't built at all until scrolled into range.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -800));
      await tester.pump();

      expect(find.text('Update available', skipOffstage: false), findsOneWidget);
      expect(find.text('Installed', skipOffstage: false), findsOneWidget);
      expect(find.text('Available', skipOffstage: false), findsOneWidget);
      expect(find.text('v1.0.0', skipOffstage: false), findsOneWidget);
      expect(find.text('v1.1.0', skipOffstage: false), findsOneWidget);
      expect(find.text('(build 1)', skipOffstage: false), findsOneWidget);
      expect(find.text('(build 2)', skipOffstage: false), findsOneWidget);
    });

    testWidgets('MoreScreen never offers an APK download on iOS',
        (tester) async {
      // The banner's whole payload is "Download update" → /app/download, an
      // Android package an iPhone cannot open, plus install instructions that
      // talk about the notification shade. Even handed an APK-channel result
      // that says an update exists, none of it may reach an iPhone.
      const updateInfo = AppVersionInfo(
        localVersion: '1.0.0',
        localBuild: 1,
        remoteVersion: '1.1.0',
        remoteBuild: 2,
        downloadUrl: 'http://localhost:8000/app/download',
        channel: AppUpdateChannel.apk,
      );
      final widget = await _wrap(
        const MoreScreen(),
        platform: TargetPlatform.iOS,
        overrides: [
          updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
          libraryRepositoryProvider.overrideWithValue(_FollowedOnlyLibraryRepository()),
          appUpdateProvider.overrideWith((ref) async => updateInfo),
        ],
      );
      await tester.pumpWidget(widget);
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();

      expect(find.text('Update available', skipOffstage: false), findsNothing);
      expect(find.text('Download update', skipOffstage: false), findsNothing);
      // The rest of the tab is untouched.
      expect(find.text('Settings', skipOffstage: false), findsOneWidget);
    });
  });
}
