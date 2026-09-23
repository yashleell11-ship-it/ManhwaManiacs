import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/models/global_search_result.dart';
import 'package:manhwamaniacs/features/library/screens/search_screen.dart';
import 'package:manhwamaniacs/features/reader/models/reader_chapter.dart';
import 'package:manhwamaniacs/features/sources/models/source.dart';
import 'package:manhwamaniacs/features/sources/models/source_pin.dart';
import 'package:manhwamaniacs/features/sources/models/source_search_group.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/repositories/sources_repository.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Grouped federated-search double. Returns [result] for a non-empty query, or
/// an [error] when configured to fail. [browseItems] backs the single-source
/// retry path, which goes to the source's own browse endpoint.
class _FakeSourcesRepository implements SourcesRepository {
  _FakeSourcesRepository({this.result, this.error, this.browseItems = const []});

  final GroupedSearchResult? result;
  final AppError? error;
  final List<SourceSeriesSummary> browseItems;
  int browseCalls = 0;

  /// Every query the screen actually asked for, in order. A federated search
  /// fans out across the whole registry, so *how many* of these there are for a
  /// given piece of typing is the load the debounce exists to bound.
  final queries = <String>[];

  @override
  Future<Result<GroupedSearchResult>> searchGrouped(
    String query, {
    int page = 1,
    int perPage = 40,
  }) async {
    queries.add(query);
    if (error != null) return Err(error!);
    return Ok(result ?? const GroupedSearchResult());
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
        items: browseItems,
        total: browseItems.length,
        page: page,
        perPage: 20,
        hasNext: false,
      ),
    );
  }

  @override
  Future<Result<List<SourcePin>>> listPins() async => const Ok([]);

  @override
  Future<Result<List<SourcePin>>> replacePins(List<String> sourceIds) =>
      throw UnimplementedError();

  @override
  Future<Result<List<SourceSummary>>> listSources() => throw UnimplementedError();

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

/// A search that answers only when the test says so, per query, so the screen
/// can be looked at while a query is still in flight.
class _GatedSourcesRepository extends _FakeSourcesRepository {
  final _gates = <String, Completer<Result<GroupedSearchResult>>>{};

  Completer<Result<GroupedSearchResult>> gate(String query) =>
      _gates.putIfAbsent(query, Completer.new);

  @override
  Future<Result<GroupedSearchResult>> searchGrouped(
    String query, {
    int page = 1,
    int perPage = 40,
  }) {
    queries.add(query);
    return gate(query).future;
  }
}

GroupedSearchResult _oneHit(String title) => GroupedSearchResult(
      groups: [
        _group(
          items: [GlobalSearchItem(kind: 'local', seriesId: '1', title: title)],
        ),
      ],
      sourcesQueried: 12,
    );

/// Types [term] and lets the debounce fire, without waiting for an answer
/// (the skeleton shown meanwhile never settles).
Future<void> _type(WidgetTester tester, String term) async {
  await tester.enterText(find.byType(TextField), term);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

/// Source ids here are deliberately ones with no known favicon so [SourceLogo]
/// renders its letter avatar instead of reaching for the network in a test.
SourceSearchGroup _group({
  String? source,
  String name = 'Your library',
  SourceGroupStatus status = SourceGroupStatus.ok,
  String? error,
  List<GlobalSearchItem> items = const [],
}) =>
    SourceSearchGroup(
      source: source,
      sourceName: name,
      status: status,
      error: error,
      total: items.length,
      items: items,
    );

Future<void> _pumpSearch(WidgetTester tester, SourcesRepository repo) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const SearchScreen()),
      GoRoute(
        path: '/library/:seriesId',
        builder: (_, state) =>
            Scaffold(body: Text('LOCAL ${state.pathParameters['seriesId']}')),
      ),
      GoRoute(
        path: '/sources/:sourceId/series/:seriesId',
        builder: (_, state) => Scaffold(
          body: Text(
            'SOURCE ${state.pathParameters['sourceId']} '
            '${state.pathParameters['seriesId']}',
          ),
        ),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        sourcesRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String term) async {
  await tester.enterText(find.byType(TextField), term);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SearchScreen (federated, grouped)', () {
    testWidgets('shows suggestions before searching', (tester) async {
      await _pumpSearch(tester, _FakeSourcesRepository());

      expect(find.text('Start typing to search'), findsOneWidget);
      expect(find.text('TRENDING'), findsOneWidget);
      expect(find.text('fantasy'), findsOneWidget);
    });

    testWidgets('renders a section per source with its own matches',
        (tester) async {
      await _pumpSearch(
        tester,
        _FakeSourcesRepository(
          result: GroupedSearchResult(
            groups: [
              _group(
                items: const [
                  GlobalSearchItem(
                    kind: 'local',
                    seriesId: '1',
                    title: 'One Piece (Library)',
                  ),
                ],
              ),
              _group(
                source: 'demonicscans',
                name: 'Demonic Scans',
                items: const [
                  GlobalSearchItem(
                    kind: 'source',
                    source: 'demonicscans',
                    seriesId: 'md-1',
                    title: 'One Piece (Demonic)',
                  ),
                ],
              ),
            ],
            sourcesQueried: 12,
            sourcesFailed: 1,
          ),
        ),
      );

      await _search(tester, 'one piece');

      // A header per source, and that source's hits beneath it.
      expect(find.text('Your library'), findsOneWidget);
      expect(find.text('Demonic Scans'), findsOneWidget);
      expect(find.text('One Piece (Library)'), findsOneWidget);
      expect(find.text('One Piece (Demonic)'), findsOneWidget);
      // Status line reflects sources queried, and flags failures subtly.
      expect(find.textContaining('2 results found'), findsOneWidget);
      expect(find.text('Some sources unavailable'), findsOneWidget);
    });

    testWidgets('a source that failed shows its own error row with Retry',
        (tester) async {
      final repo = _FakeSourcesRepository(
        result: GroupedSearchResult(
          groups: [
            _group(
              items: const [
                GlobalSearchItem(
                  kind: 'local',
                  seriesId: '1',
                  title: 'One Piece (Library)',
                ),
              ],
            ),
            _group(
              source: 'demonicscans',
              name: 'Demonic Scans',
              status: SourceGroupStatus.error,
              error: 'Source timed out',
            ),
          ],
          sourcesQueried: 2,
          sourcesFailed: 1,
        ),
        browseItems: const [
          SourceSeriesSummary(
            id: 'ds-9',
            sourceId: 'demonicscans',
            title: 'One Piece (Recovered)',
            chapterCount: 4,
            genres: [],
            coverUrl: '',
          ),
        ],
      );
      await _pumpSearch(tester, repo);
      await _search(tester, 'one piece');

      // The rest of the screen still rendered — one dead source is one row.
      expect(find.text('One Piece (Library)'), findsOneWidget);
      expect(find.text('Source timed out'), findsOneWidget);

      await tester.ensureVisible(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(repo.browseCalls, 1);
      expect(find.text('Source timed out'), findsNothing);
      expect(find.text('One Piece (Recovered)'), findsOneWidget);
    });

    testWidgets('empty result shows "No results found", not a spinner',
        (tester) async {
      await _pumpSearch(
        tester,
        _FakeSourcesRepository(
          result: GroupedSearchResult(
            groups: [
              _group(status: SourceGroupStatus.empty),
              _group(
                source: 'demonicscans',
                name: 'Demonic Scans',
                status: SourceGroupStatus.empty,
              ),
            ],
            sourcesQueried: 12,
          ),
        ),
      );

      await _search(tester, 'nonexistent title');

      expect(find.text('No results found'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('repository error shows error state with retry', (tester) async {
      await _pumpSearch(
        tester,
        _FakeSourcesRepository(error: const NetworkError(message: 'offline')),
      );

      await _search(tester, 'one piece');

      expect(find.text('Search failed'), findsOneWidget);
      expect(find.text('TRY AGAIN'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('tapping a source result navigates to source detail',
        (tester) async {
      await _pumpSearch(
        tester,
        _FakeSourcesRepository(
          result: GroupedSearchResult(
            groups: [
              _group(
                source: 'demonicscans',
                name: 'Demonic Scans',
                items: const [
                  GlobalSearchItem(
                    kind: 'source',
                    source: 'demonicscans',
                    seriesId: 'md-1',
                    title: 'One Piece (Demonic)',
                  ),
                ],
              ),
            ],
            sourcesQueried: 1,
          ),
        ),
      );

      await _search(tester, 'one piece');

      await tester.tap(find.text('One Piece (Demonic)'));
      await tester.pumpAndSettle();

      expect(find.text('SOURCE demonicscans md-1'), findsOneWidget);
    });
  });

  group('SearchScreen (while a query is in flight)', () {
    testWidgets('the first search says it is searching, not "No results found"',
        (tester) async {
      final repo = _GatedSourcesRepository();
      await _pumpSearch(tester, repo);

      await _type(tester, 'solo');

      expect(repo.queries, ['solo']);
      expect(find.text('Searching sources…'), findsOneWidget);
      expect(find.text('No results found'), findsNothing);
      expect(find.textContaining('results found'), findsNothing);

      repo.gate('solo').complete(Ok(_oneHit('Solo A')));
      await tester.pumpAndSettle();
      expect(find.text('Solo A'), findsOneWidget);
    });

    testWidgets("a new query does not show the last one's results as its own",
        (tester) async {
      final repo = _GatedSourcesRepository();
      await _pumpSearch(tester, repo);
      await _type(tester, 'solo');
      repo.gate('solo').complete(Ok(_oneHit('Solo A')));
      await tester.pumpAndSettle();
      expect(find.text('1 result found · 12 sources'), findsOneWidget);

      await _type(tester, 'omni');

      expect(repo.queries, ['solo', 'omni']);
      expect(find.text('Solo A'), findsNothing);
      expect(find.textContaining('result found'), findsNothing);
      expect(find.text('Searching sources…'), findsOneWidget);

      repo.gate('omni').complete(Ok(_oneHit('Omni P1')));
      await tester.pumpAndSettle();
      expect(find.text('Omni P1'), findsOneWidget);
      expect(find.text('Solo A'), findsNothing);
    });
  });

  group('SearchScreen (when the query is sent)', () {
    testWidgets('searches on the first character, not the second',
        (tester) async {
      final repo = _FakeSourcesRepository();
      await _pumpSearch(tester, repo);

      await _search(tester, 'a');

      expect(repo.queries, ['a']);
    });

    testWidgets('sends one query per pause, not one per keystroke',
        (tester) async {
      // The guarantee that makes searching from one character affordable: this
      // is a fan-out across every installed connector, so a request per
      // keystroke queues them on each other behind the per-source politeness
      // budget. Typing three characters inside the debounce must cost one.
      final repo = _FakeSourcesRepository();
      await _pumpSearch(tester, repo);

      for (final term in ['s', 'so', 'sol']) {
        await tester.enterText(find.byType(TextField), term);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(repo.queries, isEmpty, reason: 'still mid-word');

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(repo.queries, ['sol']);
    });

    testWidgets("the keyboard's Search key does not wait for the debounce",
        (tester) async {
      final repo = _FakeSourcesRepository();
      await _pumpSearch(tester, repo);

      await tester.enterText(find.byType(TextField), 'solo');
      await tester.pump(const Duration(milliseconds: 50));
      expect(repo.queries, isEmpty);

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      // Asked already, well inside the 300 ms the timer still had to run.
      expect(repo.queries, ['solo']);

      // And the cancelled timer does not fire a second, identical fan-out.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(repo.queries, ['solo']);
    });
  });
}
