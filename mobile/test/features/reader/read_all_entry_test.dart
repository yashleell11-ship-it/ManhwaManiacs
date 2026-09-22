import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/suggestion.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/reader/models/reader_chapter.dart';
import 'package:manhwamaniacs/features/reader/widgets/read_all_button.dart';
import 'package:manhwamaniacs/features/sources/models/source.dart';
import 'package:manhwamaniacs/features/sources/models/source_pin.dart';
import 'package:manhwamaniacs/features/sources/models/source_search_group.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/repositories/sources_repository.dart';
import 'package:manhwamaniacs/features/sources/screens/source_series_detail_screen.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/models/update_settings.dart';
import 'package:manhwamaniacs/features/updates/repositories/updates_repository.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

/// "Read all" as an entry point (spec R2), in the owner's words: "there should
/// be a small clickable button when i click a manhwa there is read online
/// there should be one for read all and ofc read online for as usual".
///
/// The assertion that matters is where the button GOES: the ordinary reader
/// route with a flag on it, opened at the chapter reading would have started
/// at. Read-all is a way of presenting the series, not a way of starting over.

class _FakeSourcesRepository implements SourcesRepository {
  @override
  Future<Result<SourceSeriesSummary>> getSeries(String s, String i) async =>
      const Ok(
        SourceSeriesSummary(
          id: 'manga-1',
          sourceId: 'mangadex',
          title: 'Solo Leveling',
          chapterCount: 3,
          genres: [],
          coverUrl: '',
        ),
      );

  @override
  Future<Result<List<SourceChapterSummary>>> getChapters(
    String s,
    String i,
  ) async =>
      Ok([
        for (var n = 1; n <= 3; n++)
          SourceChapterSummary(
            id: 'ch-$n',
            sourceId: 'mangadex',
            seriesId: 'manga-1',
            title: 'Chapter $n',
            number: n.toDouble(),
            pageCount: 10,
          ),
      ]);

  @override
  Future<Result<List<SourceSummary>>> listSources() => throw UnimplementedError();

  @override
  Future<Result<GroupedSearchResult>> searchGrouped(
    String query, {
    int page = 1,
    int perPage = 40,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<List<SourcePin>>> listPins() => throw UnimplementedError();

  @override
  Future<Result<List<SourcePin>>> replacePins(List<String> sourceIds) =>
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
  Future<Result<ReaderChapter>> getReaderChapter(String s, String i, String c) =>
      throw UnimplementedError();
}

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
  Future<Result<void>> markRead(int notificationId) => throw UnimplementedError();

  @override
  Future<Result<void>> markAllRead() => throw UnimplementedError();

  @override
  Future<Result<List<UpdateRun>>> listRuns({int limit = 20}) =>
      throw UnimplementedError();

  @override
  Future<Result<UpdateCheckOutcome>> triggerCheck({List<int>? followedIds}) =>
      throw UnimplementedError();

  @override
  Future<Result<UpdateRun>> checkFollowed(int followedId) =>
      throw UnimplementedError();
}

/// Only the followed-series read is exercised (the Follow button's cache);
/// everything else throws so a stray call is loud rather than silently empty.
class _FakeLibraryRepository implements LibraryRepository {
  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? readingStatus,
    String? search,
    String? sort,
    bool? isFavorite,
  }) async =>
      const Ok(
        PagedResult(
          items: [],
          total: 0,
          page: 1,
          perPage: 40,
          hasNext: false,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();

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
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<GoRouter> pumpSeriesPage(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final router = GoRouter(
      initialLocation: '/series',
      routes: [
        GoRoute(
          path: '/series',
          builder: (_, __) => const SourceSeriesDetailScreen(
            sourceId: 'mangadex',
            seriesId: 'manga-1',
          ),
        ),
        GoRoute(
          path: Routes.sourceReader,
          builder: (_, __) => const Scaffold(body: Text('reader')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.binding.setSurfaceSize(const Size(430, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          apiBaseUrlOverride('http://example.test'),
          sourcesRepositoryProvider.overrideWithValue(_FakeSourcesRepository()),
          updatesRepositoryProvider.overrideWithValue(_FakeUpdatesRepository()),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('the series page offers Read all beside Read online',
      (tester) async {
    await pumpSeriesPage(tester);

    // Both, always: "read all and ofc read online for as usual".
    expect(find.byKey(const Key('read-primary')), findsOneWidget);
    expect(find.byKey(const Key('read-all')), findsOneWidget);
    expect(find.byType(ReadAllButton), findsOneWidget);
  });

  testWidgets('Read all opens the ordinary reader route with the flag on it',
      (tester) async {
    final router = await pumpSeriesPage(tester);

    await tester.tap(find.byKey(const Key('read-all')));
    await tester.pumpAndSettle();

    final uri = router.routerDelegate.currentConfiguration.uri;
    // The first chapter, because nothing has been read — and the same reader
    // route the ordinary button uses, only flagged.
    expect(uri.path, contains('ch-1'));
    expect(isReadAllRequest(uri.queryParameters), isTrue);
  });

  testWidgets('Read online is untouched — no flag, same route as always',
      (tester) async {
    final router = await pumpSeriesPage(tester);

    await tester.tap(find.byKey(const Key('read-primary')));
    await tester.pumpAndSettle();

    final uri = router.routerDelegate.currentConfiguration.uri;
    expect(uri.path, contains('ch-1'));
    expect(isReadAllRequest(uri.queryParameters), isFalse);
  });
}
