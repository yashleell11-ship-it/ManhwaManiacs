import 'dart:async';

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
  String? seriesIdentity,
}) =>
    FollowedSeries(
      id: id,
      sourceId: sourceId,
      seriesKey: seriesKey,
      seriesIdentity: seriesIdentity,
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

  List<UpdateNotification> notifications;
  int unreadCount;

  /// What the last read-all asked to clear, and how many there were.
  String? markAllKind;
  int markAllCalls = 0;

  /// Answer "Check now" the way production does with its scheduler up: queued
  /// on the worker, nothing fetched yet.
  bool queueChecks = false;

  /// What the queued check will find, and on which unread-count read after
  /// queueing the server's worker has finished and written it.
  UpdateNotification? queuedFind;
  int findOnRead = 2;
  int readsSinceQueued = 0;
  bool _queued = false;

  @override
  Future<Result<List<UpdateNotification>>> listNotifications({
    bool unreadOnly = false,
    int limit = 100,
  }) async =>
      Ok(notifications);

  @override
  Future<Result<int>> getUnreadCount() async {
    if (_queued) {
      readsSinceQueued++;
      if (queuedFind != null && readsSinceQueued >= findOnRead) {
        notifications = [...notifications, queuedFind!];
        unreadCount++;
        queuedFind = null;
      }
    }
    return Ok(unreadCount);
  }

  @override
  Future<Result<void>> markRead(int notificationId) async => const Ok(null);

  @override
  Future<Result<void>> markAllRead({String? contentKind}) async {
    markAllCalls++;
    markAllKind = contentKind;
    return const Ok(null);
  }

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
  Future<Result<UpdateCheckOutcome>> triggerCheck({List<int>? followedIds}) async {
    if (!queueChecks) return const Ok(UpdateCheckOutcome(queued: false));
    _queued = true;
    return const Ok(UpdateCheckOutcome(queued: true));
  }

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
    // Paged the way the server pages, so a library bigger than one page is
    // only whole to a caller that asks for every page.
    final start = (page - 1) * perPage;
    final end = (start + perPage).clamp(0, followed.length);
    return Ok(
      PagedResult(
        items: start < followed.length ? followed.sublist(start, end) : const [],
        total: followed.length,
        page: page,
        perPage: perPage,
        hasNext: end < followed.length,
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

    test('knows a follow that sorts past the first 200 of a big library', () async {
      // 250 follows, the list serving 200 a page: the row at 240 was on page
      // 2, which was never asked for, so its page offered "Follow".
      final repo = _FakeLibraryRepository(
        followed: [
          for (var i = 1; i <= 250; i++) _followed(id: i, seriesKey: 'series-$i'),
        ],
      );
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
        notifier.followedFor(sourceId: 'mangadex', seriesKey: 'series-240')?.id,
        240,
      );
      expect(container.read(updatesProvider).value!.followed, hasLength(250));
    });

    group('a series followed under an older Asura key', () {
      const identity = 'the-great-mage-returns-after-4000-years';
      const oldKey = '$identity-08677664';
      const newKey = '$identity-05c7df14';

      Future<UpdatesNotifier> notifierFor(List<FollowedSeries> followed) async {
        final container = ProviderContainer(
          overrides: [
            updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
            libraryRepositoryProvider
                .overrideWithValue(_FakeLibraryRepository(followed: followed)),
          ],
        );
        addTearDown(container.dispose);
        await container.read(updatesProvider.future);
        return container.read(updatesProvider.notifier);
      }

      test("is found from the new-key page by the page's identity", () async {
        final notifier = await notifierFor([
          _followed(
            id: 7,
            sourceId: 'asurascans',
            seriesKey: oldKey,
            seriesIdentity: identity,
          ),
        ]);

        expect(
          notifier
              .followedFor(
                sourceId: 'asurascans',
                seriesKey: newKey,
                seriesIdentity: identity,
              )
              ?.id,
          7,
        );
      });

      test('is not claimed by another series, another source, or no identity',
          () async {
        final notifier = await notifierFor([
          _followed(
            id: 7,
            sourceId: 'asurascans',
            seriesKey: oldKey,
            seriesIdentity: identity,
          ),
        ]);

        expect(
          notifier.followedFor(
            sourceId: 'asurascans',
            seriesKey: 'the-great-mage-05c7df14',
            seriesIdentity: 'the-great-mage',
          ),
          isNull,
        );
        expect(
          notifier.followedFor(
            sourceId: 'mangadex',
            seriesKey: newKey,
            seriesIdentity: identity,
          ),
          isNull,
        );
        expect(
          notifier.followedFor(sourceId: 'asurascans', seriesKey: newKey),
          isNull,
        );
      });
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

  /// Production answers "Check now" with `{queued: true}` before its worker
  /// has fetched anything, and the screen used to reload once, straight away,
  /// then never again — so a check that found a chapter looked like one that
  /// found nothing.
  group('UpdatesNotifier.triggerCheck', () {
    UpdateNotification found() => const UpdateNotification(
          id: 7,
          followedSeriesId: 42,
          sourceId: 'mangadex',
          seriesKey: 'series-1',
          chapterKey: 'ch-7',
          chapterTitle: 'Chapter 7',
          isRead: false,
        );

    Future<ProviderContainer> loaded(_FakeUpdatesRepository updates) async {
      final container = ProviderContainer(
        overrides: [
          updatesRepositoryProvider.overrideWithValue(updates),
          libraryRepositoryProvider.overrideWithValue(
            _FakeLibraryRepository(followed: [_followed()]),
          ),
          updateCheckPollDelaysProvider.overrideWithValue(
            const [Duration.zero, Duration.zero, Duration.zero],
          ),
        ],
      );
      addTearDown(container.dispose);
      // The screen watching it, as in the app: an autoDispose provider with
      // no listener is disposed between the awaits a queued check makes.
      container.listen(updatesProvider, (_, __) {});
      await container.read(updatesProvider.future);
      return container;
    }

    test('a queued check shows the chapters it finds once the worker is done',
        () async {
      final updates = _FakeUpdatesRepository()
        ..queueChecks = true
        ..queuedFind = found()
        ..findOnRead = 2;
      final container = await loaded(updates);

      final error = await container.read(updatesProvider.notifier).triggerCheck();

      expect(error, isNull);
      final state = container.read(updatesProvider).value!;
      expect(state.notifications.map((n) => n.id), [7]);
      expect(state.unreadCount, 1);
      expect(state.checking, isFalse);
    });

    test('stops looking as soon as the unread count moves', () async {
      final updates = _FakeUpdatesRepository()
        ..queueChecks = true
        ..queuedFind = found()
        ..findOnRead = 1;
      final container = await loaded(updates);

      await container.read(updatesProvider.notifier).triggerCheck();

      // One look found it, then one reload — not the other two looks.
      expect(updates.readsSinceQueued, 2);
    });

    test('a queued check that finds nothing gives up after the last look',
        () async {
      final updates = _FakeUpdatesRepository()..queueChecks = true;
      final container = await loaded(updates);

      await container.read(updatesProvider.notifier).triggerCheck();

      // Three looks, then the final reload.
      expect(updates.readsSinceQueued, 4);
      final state = container.read(updatesProvider).value!;
      expect(state.notifications, isEmpty);
      expect(state.checking, isFalse);
    });

    test('says it is checking while the check is out', () async {
      final updates = _FakeUpdatesRepository()..queueChecks = true;
      final container = await loaded(updates);

      final pending = container.read(updatesProvider.notifier).triggerCheck();
      expect(container.read(updatesProvider).value!.checking, isTrue);
      await pending;
      expect(container.read(updatesProvider).value!.checking, isFalse);
    });
  });

  group('UpdatesNotifier.markAllRead', () {
    test('asks the server to clear only the given mode', () async {
      final updates = _FakeUpdatesRepository();
      final container = ProviderContainer(
        overrides: [
          updatesRepositoryProvider.overrideWithValue(updates),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(updatesProvider.future);
      final notifier = container.read(updatesProvider.notifier);

      await notifier.markAllRead(mode: ContentMode.novel);
      expect(updates.markAllKind, 'novel');

      await notifier.markAllRead();
      expect(updates.markAllKind, isNull);
      expect(updates.markAllCalls, 2);
    });
  });
}
