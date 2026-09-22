import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
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
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/models/update_settings.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';
import 'package:manhwamaniacs/features/updates/repositories/updates_repository.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

FollowedSeries _followed({
  int id = 42,
  String sourceId = 'mangadex',
  String seriesKey = 'series-1',
}) =>
    FollowedSeries(
      id: id,
      sourceId: sourceId,
      seriesKey: seriesKey,
      title: 'Solo Leveling',
      coverUrl: '',
      isFavorite: false,
      readingStatus: 'reading',
      notify: true,
      sortOrder: 0,
      contentRating: 'safe',
      rating: 'safe',
      chapterCount: 0,
    );

/// Notifications repository fake used by every group below; always empty
/// unless a test needs otherwise.
class _FakeUpdatesRepository implements UpdatesRepository {
  _FakeUpdatesRepository({
    this.notifications = const [],
    this.unreadCount = 0,
  });

  final List<UpdateNotification> notifications;
  final int unreadCount;

  @override
  Future<Result<List<UpdateNotification>>> listNotifications({
    bool unreadOnly = false,
    int limit = 100,
  }) async =>
      Ok(notifications);

  @override
  Future<Result<int>> getUnreadCount() async => Ok(unreadCount);

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

/// Library repository double exercising the follow/unfollow surface
/// `UpdatesNotifier` drives — the "trackers" cache is now just the followed
/// series list from `GET /library/series`.
class _FakeLibraryRepository implements LibraryRepository {
  _FakeLibraryRepository({this.followed = const []});

  List<FollowedSeries> followed;
  Completer<void>? unfollowGate;
  Completer<void>? followGate;
  int unfollowCallCount = 0;
  int followCallCount = 0;
  bool failUnfollow = false;
  int nextId = 900;

  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? sort,
    String? search,
    String? readingStatus,
    bool? isFavorite,
  }) async {
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
  Future<Result<void>> unfollow(int followedId) async {
    unfollowCallCount++;
    if (unfollowGate != null) await unfollowGate!.future;
    if (failUnfollow) {
      return const Err(NetworkError(message: 'boom'));
    }
    followed = followed.where((f) => f.id != followedId).toList();
    return const Ok(null);
  }

  @override
  Future<Result<FollowedSeries>> follow({
    required String sourceId,
    required String seriesKey,
  }) async {
    followCallCount++;
    if (followGate != null) await followGate!.future;
    final created = _followed(id: nextId++, sourceId: sourceId, seriesKey: seriesKey);
    followed = [...followed, created];
    return Ok(created);
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

void main() {
  group('UpdatesNotifier.followedFor', () {
    test('returns the followed row for a matching source+series', () async {
      final repo = _FakeLibraryRepository(followed: [_followed()]);
      final container = ProviderContainer(
        overrides: [
          updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
          libraryRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);

      await container.read(updatesProvider.future);
      final notifier = container.read(updatesProvider.notifier);

      final found = notifier.followedFor(sourceId: 'mangadex', seriesKey: 'series-1');
      expect(found?.id, 42);
    });

    test('returns null for a series that is not followed', () async {
      final repo = _FakeLibraryRepository(followed: [_followed()]);
      final container = ProviderContainer(
        overrides: [
          updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
          libraryRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);

      await container.read(updatesProvider.future);
      final notifier = container.read(updatesProvider.notifier);

      expect(
        notifier.followedFor(sourceId: 'mangadex', seriesKey: 'series-does-not-exist'),
        isNull,
      );
      expect(
        notifier.followedFor(sourceId: 'asurascans', seriesKey: 'series-1'),
        isNull,
      );
    });
  });

  group('UpdatesNotifier.unfollow / followSeries', () {
    test('unfollow sets actionPending immediately, then clears it once it resolves',
        () async {
      final repo = _FakeLibraryRepository(followed: [_followed()])
        ..unfollowGate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
          libraryRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);

      await container.read(updatesProvider.future);
      final notifier = container.read(updatesProvider.notifier);

      expect(container.read(updatesProvider).valueOrNull?.actionPending, isFalse);

      final pending = notifier.unfollow(42);
      // Optimistic flag is set synchronously, before the repo call resolves.
      expect(container.read(updatesProvider).valueOrNull?.actionPending, isTrue);

      repo.unfollowGate!.complete();
      await pending;

      expect(container.read(updatesProvider).valueOrNull?.actionPending, isFalse);
      expect(repo.unfollowCallCount, 1);
    });

    test('clears actionPending on failure without leaving the button stuck busy',
        () async {
      final repo = _FakeLibraryRepository(followed: [_followed()])..failUnfollow = true;
      final container = ProviderContainer(
        overrides: [
          updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
          libraryRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);

      await container.read(updatesProvider.future);
      final notifier = container.read(updatesProvider.notifier);

      final error = await notifier.unfollow(42);

      expect(error, isNotNull);
      expect(container.read(updatesProvider).valueOrNull?.actionPending, isFalse);
    });

    test('followSeries adds the new row to the followed cache', () async {
      final repo = _FakeLibraryRepository();
      final container = ProviderContainer(
        overrides: [
          updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
          libraryRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);

      await container.read(updatesProvider.future);
      final notifier = container.read(updatesProvider.notifier);

      final error = await notifier.followSeries(sourceId: 'toonily', seriesKey: 'abc');

      expect(error, isNull);
      expect(repo.followCallCount, 1);
      expect(
        notifier.followedFor(sourceId: 'toonily', seriesKey: 'abc'),
        isNotNull,
      );
    });
  });

  /// The splices `librarySeriesActionsProvider` drives when a series is
  /// removed from — or restored to — a shelf drawn from this cache. Splices,
  /// not invalidations: rebuilding this cache costs three requests, and the
  /// Library tab is drawn from it.
  group('UpdatesNotifier.forgetFollowed / rememberFollowed', () {
    UpdateNotification notification({
      required int id,
      required int followedSeriesId,
      bool isRead = false,
    }) =>
        UpdateNotification(
          id: id,
          followedSeriesId: followedSeriesId,
          sourceId: 'mangadex',
          seriesKey: 'series-1',
          chapterKey: 'ch-$id',
          chapterTitle: 'Chapter $id',
          isRead: isRead,
        );

    Future<ProviderContainer> loaded({
      List<FollowedSeries> followed = const [],
      List<UpdateNotification> notifications = const [],
      int unreadCount = 0,
    }) async {
      final container = ProviderContainer(
        overrides: [
          updatesRepositoryProvider.overrideWithValue(
            _FakeUpdatesRepository(
              notifications: notifications,
              unreadCount: unreadCount,
            ),
          ),
          libraryRepositoryProvider
              .overrideWithValue(_FakeLibraryRepository(followed: followed)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(updatesProvider.future);
      return container;
    }

    test('forgetFollowed drops the row and reports the slot it held', () async {
      final container = await loaded(
        followed: [
          _followed(id: 1, seriesKey: 'a'),
          _followed(id: 2, seriesKey: 'b'),
          _followed(id: 3, seriesKey: 'c'),
        ],
      );
      final notifier = container.read(updatesProvider.notifier);

      expect(notifier.forgetFollowed(2), 1);
      expect(
        container.read(updatesProvider).value!.followed.map((s) => s.id),
        [1, 3],
      );
    });

    test('forgetFollowed reports -1 for a row this cache does not hold',
        () async {
      final container = await loaded(followed: [_followed(id: 1)]);
      expect(container.read(updatesProvider.notifier).forgetFollowed(99), -1);
    });

    test('forgetFollowed takes the notifications with it, and their unread',
        () async {
      // `update_notifications.followed_series_id` is ON DELETE CASCADE, so
      // keeping them would leave the Updates tab listing chapters of a series
      // nobody follows, counted by a badge that outlives them.
      final container = await loaded(
        followed: [_followed(id: 1), _followed(id: 2, seriesKey: 'other')],
        notifications: [
          notification(id: 10, followedSeriesId: 1),
          notification(id: 11, followedSeriesId: 1, isRead: true),
          notification(id: 12, followedSeriesId: 2),
        ],
        unreadCount: 2,
      );

      container.read(updatesProvider.notifier).forgetFollowed(1);
      final state = container.read(updatesProvider).value!;

      expect(state.notifications.map((n) => n.id), [12]);
      expect(state.unreadCount, 1);
    });

    test('rememberFollowed puts an undone removal back in its slot', () async {
      final container = await loaded(
        followed: [
          _followed(id: 1, seriesKey: 'a'),
          _followed(id: 2, seriesKey: 'b'),
        ],
      );
      final notifier = container.read(updatesProvider.notifier);

      final slot = notifier.forgetFollowed(1);
      // A re-follow is a brand new row, so the undo puts back a different id.
      notifier.rememberFollowed(_followed(id: 100, seriesKey: 'a'), index: slot);

      expect(
        container.read(updatesProvider).value!.followed.map((s) => s.id),
        [100, 2],
      );
    });

    test('rememberFollowed replaces a row that is already there', () async {
      // The favorite toggle's path: same row, new metadata, same place.
      final container = await loaded(followed: [_followed(id: 1)]);
      final notifier = container.read(updatesProvider.notifier);

      notifier.rememberFollowed(_followed(id: 1).copyWith(isFavorite: true));
      final followed = container.read(updatesProvider).value!.followed;

      expect(followed, hasLength(1));
      expect(followed.single.isFavorite, isTrue);
    });
  });
}
