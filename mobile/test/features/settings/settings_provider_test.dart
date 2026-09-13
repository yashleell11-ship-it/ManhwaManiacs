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
import 'package:manhwamaniacs/features/library/models/tag.dart';
import 'package:manhwamaniacs/features/library/providers/bookmarks_provider.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/reader/models/bookmark.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest_window.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/repositories/reader_repository.dart';
import 'package:manhwamaniacs/features/settings/models/reader_defaults.dart';
import 'package:manhwamaniacs/features/settings/providers/settings_provider.dart';
import 'package:manhwamaniacs/features/settings/services/image_cache_service.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/models/update_settings.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';
import 'package:manhwamaniacs/features/updates/repositories/updates_repository.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Empty-data fake — every list method returns an empty success so the
/// top-level metadata providers resolve without a network call.
class _EmptyLibraryRepository implements LibraryRepository {
  var statisticsCallCount = 0;
  var continueReadingCallCount = 0;
  var listSeriesCallCount = 0;

  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? sort,
    String? search,
    String? readingStatus,
    bool? isFavorite,
  }) async {
    listSeriesCallCount++;
    return Ok(PagedResult(items: const [], total: 0, page: 1, perPage: perPage, hasNext: false));
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
  Future<Result<List<ContinueReadingItem>>> continueReading({int limit = 10}) async {
    continueReadingCallCount++;
    return const Ok([]);
  }

  @override
  Future<Result<List<FollowedSeries>>> recentlyUpdated({int limit = 10}) async => const Ok([]);

  @override
  Future<Result<List<RecommendationGenre>>> recommendations({int limit = 10}) async =>
      const Ok([]);

  @override
  Future<Result<PagedResult<FollowedSeries>>> search(
    String query, {
    int page = 1,
    int perPage = 20,
  }) async =>
      Ok(PagedResult(items: const [], total: 0, page: page, perPage: perPage, hasNext: false));

  @override
  Future<Result<List<Collection>>> listCollections() async => const Ok([]);

  @override
  Future<Result<CollectionDetail>> getCollection(int collectionId) => throw UnimplementedError();

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
  Future<Result<LibraryStatistics>> statistics() async {
    statisticsCallCount++;
    return const Ok(
      LibraryStatistics(
        followedTotal: 0,
        favorites: 0,
        byReadingStatus: {},
        chaptersCompleted: 0,
      ),
    );
  }

  @override
  Future<Result<List<ReadingHistoryItem>>> readingHistory({
    int limit = 50,
    int offset = 0,
  }) async =>
      const Ok([]);
}

class _EmptyReaderRepository implements ReaderRepository {
  var bookmarksCallCount = 0;

  @override
  Future<Result<List<Bookmark>>> listBookmarks({
    String? sourceId,
    String? seriesKey,
    DateTime? since,
    bool includeDeleted = false,
    int? limit,
  }) async {
    bookmarksCallCount++;
    return const Ok([]);
  }

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

class _EmptyUpdatesRepository implements UpdatesRepository {
  @override
  Future<Result<List<UpdateNotification>>> listNotifications({
    bool unreadOnly = false,
    int limit = 100,
  }) async =>
      const Ok([]);

  @override
  Future<Result<int>> getUnreadCount() async => const Ok(0);

  @override
  Future<Result<void>> markRead(int notificationId) => throw UnimplementedError();

  @override
  Future<Result<void>> markAllRead() => throw UnimplementedError();

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
  Future<Result<UpdateCheckOutcome>> triggerCheck({List<int>? followedIds}) =>
      throw UnimplementedError();

  @override
  Future<Result<UpdateRun>> checkFollowed(int followedId) => throw UnimplementedError();
}

class _FakeImageCacheService implements ImageCacheService {
  int clearCallCount = 0;
  int sizeBytes = 4096;

  @override
  Future<int> getCacheSizeBytes() async => sizeBytes;

  @override
  Future<void> clear() async {
    clearCallCount++;
    sizeBytes = 0;
  }
}

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      libraryRepositoryProvider.overrideWithValue(_EmptyLibraryRepository()),
      readerRepositoryProvider.overrideWithValue(_EmptyReaderRepository()),
      updatesRepositoryProvider.overrideWithValue(_EmptyUpdatesRepository()),
    ],
  );
}

void main() {
  group('languageProvider', () {
    test('defaults to English and persists a language change', () async {
      final container = await _container();
      addTearDown(container.dispose);

      expect(container.read(languageProvider), AppLanguage.english);

      await container.read(languageProvider.notifier).setLanguage(AppLanguage.korean);
      expect(container.read(languageProvider), AppLanguage.korean);
      expect(container.read(preferencesProvider).language, 'ko');
    });
  });

  group('readerDefaultsProvider', () {
    test('persists direction, fit mode, keep-awake, and auto-next independently', () async {
      final container = await _container();
      addTearDown(container.dispose);

      final notifier = container.read(readerDefaultsProvider.notifier);

      await notifier.setDirection(ReadingDirection.rightToLeft);
      await notifier.setFitMode(ReaderFitMode.screen);
      await notifier.setKeepScreenAwake(true);
      await notifier.setAutoNextChapter(false);
      await notifier.setLockControls(true);
      await notifier.setRefreshRate(ReaderRefreshRate.fps90);

      final state = container.read(readerDefaultsProvider);
      expect(state.direction, ReadingDirection.rightToLeft);
      expect(state.fitMode, ReaderFitMode.screen);
      expect(state.keepScreenAwake, isTrue);
      expect(state.autoNextChapter, isFalse);
      expect(state.lockControls, isTrue);
      expect(state.refreshRate, ReaderRefreshRate.fps90);

      final prefs = container.read(preferencesProvider);
      expect(prefs.readingDirection, 'rightToLeft');
      expect(prefs.readerFitMode, 'screen');
      expect(prefs.lockReaderControls, isTrue);
      expect(prefs.readerRefreshRate, 'fps90');
    });

    test('defaults refresh rate to auto when nothing is persisted', () async {
      final container = await _container();
      addTearDown(container.dispose);

      expect(
        container.read(readerDefaultsProvider).refreshRate,
        ReaderRefreshRate.auto,
      );
    });
  });

  group('wifiOnlyDownloadsProvider', () {
    test('defaults to false and persists toggling on', () async {
      final container = await _container();
      addTearDown(container.dispose);

      expect(container.read(wifiOnlyDownloadsProvider), isFalse);

      await container.read(wifiOnlyDownloadsProvider.notifier).setEnabled(true);
      expect(container.read(wifiOnlyDownloadsProvider), isTrue);
      expect(container.read(preferencesProvider).wifiOnlyDownloads, isTrue);
    });
  });

  group('SettingsActions cache actions', () {
    test('clearImageCache clears via the injected service and invalidates usage', () async {
      final container = await _container();
      addTearDown(container.dispose);
      final fakeCache = _FakeImageCacheService();

      final overriddenContainer = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(container.read(sharedPrefsProvider)),
          libraryRepositoryProvider.overrideWithValue(_EmptyLibraryRepository()),
          readerRepositoryProvider.overrideWithValue(_EmptyReaderRepository()),
          updatesRepositoryProvider.overrideWithValue(_EmptyUpdatesRepository()),
          imageCacheServiceProvider.overrideWithValue(fakeCache),
        ],
      );
      addTearDown(overriddenContainer.dispose);

      expect(await overriddenContainer.read(cacheUsageProvider.future), 4096);

      await overriddenContainer.read(settingsActionsProvider).clearImageCache();

      expect(fakeCache.clearCallCount, 1);
      expect(await overriddenContainer.read(cacheUsageProvider.future), 0);
    });

    test(
        'clearMetadataCache forces a real refetch on next read (proves '
        'invalidation, not just a state flag)', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final libraryRepo = _EmptyLibraryRepository();
      final readerRepo = _EmptyReaderRepository();
      final updatesRepo = _EmptyUpdatesRepository();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          libraryRepositoryProvider.overrideWithValue(libraryRepo),
          readerRepositoryProvider.overrideWithValue(readerRepo),
          updatesRepositoryProvider.overrideWithValue(updatesRepo),
        ],
      );
      addTearDown(container.dispose);

      // Hold each provider alive with a listener, matching how a mounted
      // screen ref.watch()es it -- otherwise these autoDispose providers
      // would refetch on every plain container.read() regardless of
      // invalidation, making this test meaningless.
      container.listen(continueReadingProvider, (_, __) {}, fireImmediately: true);
      container.listen(bookmarksProvider, (_, __) {}, fireImmediately: true);
      container.listen(updatesProvider, (_, __) {}, fireImmediately: true);

      await container.read(continueReadingProvider.future);
      await container.read(bookmarksProvider.future);
      await container.read(updatesProvider.future);
      // continueReadingProvider fetches exactly one endpoint now. It used to be
      // a three-call `dashboardProvider` whose refetch was proved through
      // statistics(); that call is gone, so proving it through statistics would
      // pass forever on a count stuck at zero.
      expect(libraryRepo.continueReadingCallCount, 1);
      expect(readerRepo.bookmarksCallCount, 1);
      expect(libraryRepo.listSeriesCallCount, 1);

      // Reading again while still listened must hit the cached value, not
      // refetch -- confirms the baseline before we invalidate.
      await container.read(continueReadingProvider.future);
      expect(libraryRepo.continueReadingCallCount, 1);

      final continueReadingCallsBefore = libraryRepo.continueReadingCallCount;
      final bookmarksCallsBefore = readerRepo.bookmarksCallCount;
      final followedCallsBefore = libraryRepo.listSeriesCallCount;

      container.read(settingsActionsProvider).clearMetadataCache();

      await container.read(continueReadingProvider.future);
      await container.read(bookmarksProvider.future);
      await container.read(updatesProvider.future);

      // With an active listener, invalidating can trigger Riverpod's own
      // eager rebuild in addition to the read above, so assert "refetched
      // at least once" rather than an exact count -- what matters is that
      // clearMetadataCache() demonstrably forced new server calls instead
      // of silently reusing the stale cached value.
      expect(
        libraryRepo.continueReadingCallCount,
        greaterThan(continueReadingCallsBefore),
      );
      expect(readerRepo.bookmarksCallCount, greaterThan(bookmarksCallsBefore));
      expect(libraryRepo.listSeriesCallCount, greaterThan(followedCallsBefore));
    });

    test('metadataCacheInvalidators covers every intended provider exactly once', () {
      expect(metadataCacheInvalidators, hasLength(8));
    });
  });
}
