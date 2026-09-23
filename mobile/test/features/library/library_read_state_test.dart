import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/read_state.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/library/providers/library_list_provider.dart';
import 'package:manhwamaniacs/features/library/providers/library_read_state.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';
import 'package:manhwamaniacs/features/updates/repositories/updates_repository.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Library tab and the resume strip stay mounted under a reader, so the
/// reader closing is the only moment they can learn that anything was read.

FollowedSeries _series({ReadState? readState, int id = 42}) => FollowedSeries(
      id: id,
      sourceId: 'asurascans',
      seriesKey: id == 42 ? 'solo-leveling' : 'series-$id',
      title: id == 42 ? 'Solo Leveling' : 'Series $id',
      coverUrl: '',
      isFavorite: false,
      readingStatus: 'reading',
      notify: true,
      sortOrder: 0,
      contentRating: 'safe',
      rating: 'safe',
      chapterCount: 10,
      readState: readState,
    );

const _notStarted = ReadState(started: false, total: 10);
const _onChapterOne = ReadState(
  started: true,
  chapterKey: '1',
  chapterNumber: 1,
  position: 1,
  total: 10,
  newCount: 9,
);

/// Only what the shelves call; anything else fails loudly.
class _FakeLibraryRepository implements LibraryRepository {
  _FakeLibraryRepository(this.followed);

  List<FollowedSeries> followed;
  bool failList = false;
  int listCalls = 0;
  int continueCalls = 0;

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
    if (failList) return const Err(NetworkError(message: 'offline'));
    // Paged for real: the browse list asks twenty at a time.
    final start = (page - 1) * perPage;
    return Ok(
      PagedResult(
        items: followed.skip(start).take(perPage).toList(),
        total: followed.length,
        page: page,
        perPage: perPage,
        hasNext: start + perPage < followed.length,
      ),
    );
  }

  @override
  Future<Result<List<ContinueReadingItem>>> continueReading({
    int limit = 10,
  }) async {
    continueCalls++;
    return const Ok([]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUpdatesRepository implements UpdatesRepository {
  int notificationCalls = 0;

  @override
  Future<Result<List<UpdateNotification>>> listNotifications({
    bool unreadOnly = false,
    int limit = 100,
  }) async {
    notificationCalls++;
    return const Ok([]);
  }

  @override
  Future<Result<int>> getUnreadCount() async => const Ok(0);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

({
  ProviderContainer container,
  _FakeLibraryRepository library,
  _FakeUpdatesRepository updates,
}) _setUp() {
  final library = _FakeLibraryRepository([_series(readState: _notStarted)]);
  final updates = _FakeUpdatesRepository();
  final container = ProviderContainer(
    overrides: [
      libraryRepositoryProvider.overrideWithValue(library),
      updatesRepositoryProvider.overrideWithValue(updates),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, library: library, updates: updates);
}

/// The browse screen's list, mounted and scrolled to its second page: 25
/// followed series, twenty a page.
Future<({ProviderContainer container, _FakeLibraryRepository library})>
    _scrolledBrowseList() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final library = _FakeLibraryRepository([
    for (var id = 1; id <= 25; id++) _series(id: id, readState: _notStarted),
  ]);
  final container = ProviderContainer(
    overrides: [
      libraryRepositoryProvider.overrideWithValue(library),
      updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
      sharedPrefsProvider.overrideWithValue(prefs),
    ],
  );
  addTearDown(container.dispose);
  container.listen(libraryListProvider, (_, __) {});
  await container.read(libraryListProvider.future);
  await container.read(libraryListProvider.notifier).loadMore();
  final scrolled = container.read(libraryListProvider).requireValue;
  expect(scrolled.items, hasLength(25));
  expect(scrolled.page, 2);
  return (container: container, library: library);
}

ReadState? _shelfReadState(ProviderContainer container) =>
    container.read(updatesProvider).valueOrNull?.followed.single.readState;

void main() {
  test('the Library tab learns what was read once the last save lands',
      () async {
    final (:container, :library, :updates) = _setUp();
    // Mounted, as the tab is under the reader.
    container.listen(updatesProvider, (_, __) {});
    await container.read(updatesProvider.future);
    expect(_shelfReadState(container)?.started, isFalse);

    // Chapter 1 read; the server now says so.
    library.followed = [_series(readState: _onChapterOne)];
    final lastSave = Completer<void>();
    final done =
        container.read(libraryReadStateProvider).afterReading(lastSave.future);

    // Not before the save is in: asking first would race it.
    await Future<void>.delayed(Duration.zero);
    expect(_shelfReadState(container)?.started, isFalse);

    lastSave.complete();
    await done;
    await Future<void>.delayed(Duration.zero);

    expect(_shelfReadState(container)?.started, isTrue);
    expect(_shelfReadState(container)?.newCount, 9);
    // The followed rows only — the notifications did not move.
    expect(updates.notificationCalls, 1);
  });

  test('a refresh that cannot reach the server keeps the shelf on screen',
      () async {
    final (:container, :library, updates: _) = _setUp();
    container.listen(updatesProvider, (_, __) {});
    await container.read(updatesProvider.future);

    library.failList = true;
    await container.read(libraryReadStateProvider).afterReading(Future.value());
    await Future<void>.delayed(Duration.zero);

    final shelf = container.read(updatesProvider);
    expect(shelf.hasError, isFalse);
    expect(shelf.valueOrNull?.followed.single.readState?.started, isFalse);
  });

  test('the resume strip is asked again', () async {
    final (:container, :library, updates: _) = _setUp();
    container.listen(continueReadingProvider, (_, __) {});
    await container.read(continueReadingProvider.future);
    expect(library.continueCalls, 1);

    await container.read(libraryReadStateProvider).afterReading(Future.value());
    await container.read(continueReadingProvider.future);

    expect(library.continueCalls, 2);
  });

  test('a failed last save still refreshes', () async {
    final (:container, :library, updates: _) = _setUp();
    container.listen(updatesProvider, (_, __) {});
    await container.read(updatesProvider.future);

    library.followed = [_series(readState: _onChapterOne)];
    await container
        .read(libraryReadStateProvider)
        .afterReading(Future.error(StateError('flush failed')));
    await Future<void>.delayed(Duration.zero);

    expect(_shelfReadState(container)?.started, isTrue);
  });

  test('the browse list keeps every page it had loaded', () async {
    final (:container, :library) = await _scrolledBrowseList();

    // Series 22 lives on the second page; it is the one that was read.
    library.followed = [
      for (final series in library.followed)
        series.id == 22 ? _series(id: 22, readState: _onChapterOne) : series,
    ];
    await container.read(libraryReadStateProvider).afterReading(Future.value());
    await Future<void>.delayed(Duration.zero);

    final list = container.read(libraryListProvider).requireValue;
    expect(list.items, hasLength(25));
    expect(list.page, 2);
    expect(list.hasNext, isFalse);
    final read = list.items.singleWhere((series) => series.id == 22);
    expect(read.readState?.started, isTrue);
  });

  test('a browse list that cannot reach the server stays as it was',
      () async {
    final (:container, :library) = await _scrolledBrowseList();

    library.failList = true;
    await container.read(libraryReadStateProvider).afterReading(Future.value());
    await Future<void>.delayed(Duration.zero);

    final list = container.read(libraryListProvider);
    expect(list.hasError, isFalse);
    expect(list.requireValue.items, hasLength(25));
    expect(list.requireValue.page, 2);
  });

  test('shelves nobody is showing are not fetched', () async {
    final (:container, :library, :updates) = _setUp();

    await container.read(libraryReadStateProvider).afterReading(Future.value());
    await Future<void>.delayed(Duration.zero);

    expect(library.listCalls, 0);
    expect(library.continueCalls, 0);
    expect(updates.notificationCalls, 0);
  });
}
