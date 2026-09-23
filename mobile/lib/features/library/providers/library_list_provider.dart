import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/app/theme/app_metrics.dart';
import 'package:manhwamaniacs/app/theme/preset_controller.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/global_search_result.dart';
import 'package:manhwamaniacs/features/library/models/library_list_state.dart';
import 'package:manhwamaniacs/features/library/models/library_query.dart';
import 'package:manhwamaniacs/features/library/providers/library_series_actions.dart';
import 'package:manhwamaniacs/features/library/utils/followed_series_cache.dart';
import 'package:manhwamaniacs/features/library/utils/library_preferences.dart';
import 'package:manhwamaniacs/features/sources/models/source_search_group.dart';
import 'package:manhwamaniacs/features/sources/providers/source_pins_provider.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

const _listPageSize = 20;
const _searchPageSize = 40;

final libraryQueryProvider =
    NotifierProvider<LibraryQueryNotifier, LibraryQuery>(
  LibraryQueryNotifier.new,
  name: 'libraryQuery',
);

class LibraryQueryNotifier extends Notifier<LibraryQuery> {
  @override
  LibraryQuery build() {
    // The design preset only supplies the layout a reader has never chosen —
    // `read` (not `watch`) because switching preset must not yank the library
    // out from under someone mid-scroll, and because a saved choice outranks
    // it anyway.
    final presetLayout = ref.read(presetControllerProvider).layout.seriesLayout;
    return _normalizeBrowseQuery(
      readLibraryQuery(
        ref.read(sharedPrefsProvider),
        defaultViewMode: presetLayout == SeriesLayout.list
            ? LibraryViewMode.list
            : LibraryViewMode.grid,
      ),
    );
  }

  void updateQuery(LibraryQuery query) {
    final normalized = _normalizeBrowseQuery(query);
    final shouldPersist = libraryQueryPersistedFieldsChanged(state, normalized);
    state = normalized;
    if (shouldPersist) {
      writeLibraryQuery(ref.read(sharedPrefsProvider), state);
    }
  }

  void patchQuery(LibraryQuery Function(LibraryQuery current) update) {
    updateQuery(update(state));
  }
}

LibraryQuery _normalizeBrowseQuery(LibraryQuery query) {
  if (!libraryBrowseSortOptions.contains(query.sort)) {
    return query.copyWith(sort: LibrarySort.recentlyUpdated);
  }
  return query;
}

/// The raw federated-search query text. Empty means "not searching".
final searchQueryProvider = StateProvider<String>(
  (ref) => '',
  name: 'searchQuery',
);

/// Which source sections the grouped results show. Client-side only — the
/// endpoint always answers with every queried source.
enum SearchGroupFilter { all, pinned, hasResults }

final searchGroupFilterProvider = StateProvider<SearchGroupFilter>(
  (ref) => SearchGroupFilter.all,
  name: 'searchGroupFilter',
);

final libraryListProvider =
    AsyncNotifierProvider.autoDispose<LibraryListNotifier, LibraryListState>(
  LibraryListNotifier.new,
  name: 'libraryList',
);

/// Federated search results (local library + every enabled remote source),
/// grouped per source and keyed off [searchQueryProvider]. Always resolves to
/// data or error — never an indefinite loading state.
///
/// The name is deliberately unchanged: `profileScopedInvalidators` and the
/// settings metadata-cache invalidators both drop this provider by name when
/// the active profile or the server changes.
final searchListProvider = AsyncNotifierProvider.autoDispose<SearchListNotifier,
    GroupedSearchResult>(
  SearchListNotifier.new,
  name: 'searchList',
);

/// The sections actually rendered, after the client-side group filter.
///
/// Filtering lives here rather than in the screen so the chip counts and the
/// list can never disagree.
final visibleSearchGroupsProvider = Provider.autoDispose<List<SourceSearchGroup>>(
  (ref) {
    final result = ref.watch(searchListProvider).valueOrNull;
    if (result == null) return const [];
    final filter = ref.watch(searchGroupFilterProvider);
    final pinned = ref.watch(pinnedSourceIdsProvider);

    final groups = switch (filter) {
      SearchGroupFilter.all => result.groups,
      SearchGroupFilter.hasResults => result.groupsWithResults,
      // The local library is never "unpinned away" — it is the user's own shelf
      // and belongs at the top of every view.
      SearchGroupFilter.pinned => [
          for (final group in result.groups)
            if (group.isLocal || pinned.contains(group.source)) group,
        ],
    };

    // Scope the federated search to the active mode. One place, because every
    // search surface renders these groups.
    //
    // In Novels mode the local-library group is dropped rather than filtered:
    // `/sources/search` gives local items no `source`, so there is nothing to
    // tell a followed manhwa from a followed novel by. Dropping it is a real
    // loss — but showing a shelf of manhwa under a Novels search is a mode
    // leak, and the Library tab already answers "what am I reading".
    final scope = ref.watch(contentModeScopeProvider);
    if (!scope.novelsEnabled) return groups;
    return [
      for (final group in groups)
        if (group.isLocal
            ? !scope.isNovel
            : scope.modeOf(group.source) == scope.mode)
          group,
    ];
  },
  name: 'visibleSearchGroups',
);

class LibraryListNotifier extends AutoDisposeAsyncNotifier<LibraryListState> {
  @override
  Future<LibraryListState> build() async {
    final query = ref.watch(libraryQueryProvider);
    return _fetchFirstPage(query);
  }

  Future<void> refresh() async {
    final query = ref.read(libraryQueryProvider);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _fetchFirstPage(query));
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasNext || current.isLoadingMore) return;

    final query = ref.read(libraryQueryProvider);
    state = AsyncData(current.copyWith(isLoadingMore: true, clearError: true));

    final nextPage = current.page + 1;
    final result = await _fetchPage(query, nextPage);
    await _cachePage(query, result.items, isFirstPage: false);

    state = AsyncData(
      current.copyWith(
        items: [...current.items, ...result.items],
        page: nextPage,
        hasNext: result.hasNext,
        total: result.total,
        isLoadingMore: false,
      ),
    );
  }

  Future<void> toggleFavorite(int followedId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final series = current.items.where((s) => s.id == followedId).firstOrNull;
    if (series == null) return;

    // Through the shared action, so the grid's star and the long-press sheet's
    // star are one implementation — and so a favorite toggled here also lands
    // in the followed cache the Library tab draws its shelf from.
    final error = await ref
        .read(librarySeriesActionsProvider)
        .setFavorite(series, favorite: !series.isFavorite);
    if (error == null) return;
    final latest = state.valueOrNull;
    if (latest == null) return;
    state = AsyncData(latest.copyWith(error: error));
  }

  /// Takes [followedId] out of the loaded page and reports the slot it held,
  /// or -1 when this list does not have it.
  ///
  /// State only — the removal itself lives in [librarySeriesActionsProvider],
  /// which is what every shelf calls and which drives this.
  int forgetSeries(int followedId) {
    final current = state.valueOrNull;
    if (current == null) return -1;
    final index = current.items.indexWhere((series) => series.id == followedId);
    if (index < 0) return -1;
    state = AsyncData(
      current.copyWith(
        items: [...current.items]..removeAt(index),
        total: current.total > 0 ? current.total - 1 : 0,
      ),
    );
    return index;
  }

  /// Puts [series] into the loaded page: in place when the row is already
  /// there (a favorite toggled), otherwise back in the slot an undo pulled it
  /// from — clamped, because a refresh may have reshaped the list while the
  /// request was in flight, and appended when there is no slot to honour.
  void rememberSeries(FollowedSeries series, {int index = -1}) {
    final current = state.valueOrNull;
    if (current == null) return;
    final at = current.items.indexWhere((item) => item.id == series.id);
    if (at >= 0) {
      state = AsyncData(
        current.copyWith(
          items: [...current.items]..[at] = series,
          clearError: true,
        ),
      );
      return;
    }
    final slot =
        index < 0 ? current.items.length : index.clamp(0, current.items.length);
    state = AsyncData(
      current.copyWith(
        items: [...current.items]..insert(slot, series),
        total: current.total + 1,
      ),
    );
  }

  /// Batch favorite/unfavorite a multi-selected set of series. Only calls
  /// the API for items whose current state actually needs to change (so
  /// "Favorite selected" on an already-mixed selection doesn't needlessly
  /// re-toggle series that are already favorited), and only flips items in
  /// local state whose API call actually succeeded.
  Future<void> batchSetFavorite(Set<int> followedIds, {required bool favorite}) async {
    final current = state.valueOrNull;
    if (current == null) return;

    final targets = current.items
        .where((series) => followedIds.contains(series.id) && series.isFavorite != favorite)
        .toList();
    if (targets.isEmpty) return;

    final repo = ref.read(libraryRepositoryProvider);
    final results = await Future.wait(
      targets.map((series) => repo.patchSeries(series.id, isFavorite: favorite)),
    );

    final updatedById = <int, FollowedSeries>{
      for (var i = 0; i < targets.length; i++)
        if (results[i].isOk) targets[i].id: results[i].value,
    };
    if (updatedById.isEmpty) return;

    final updatedItems = current.items
        .map((s) => updatedById[s.id] ?? s)
        .toList();

    state = AsyncData(current.copyWith(items: updatedItems, clearError: true));
  }

  /// The library grid, server first and last-synced-shelf second.
  ///
  /// A failed fetch used to be the end of the story, which made the library
  /// tab a dead end with the server unreachable — and with it every
  /// downloaded chapter, since the series page (and the reader behind it) is
  /// only reachable through this grid.
  Future<LibraryListState> _fetchFirstPage(LibraryQuery query) async {
    try {
      final page = await _fetchPage(query, 1);
      await _cachePage(query, page.items, isFirstPage: true);
      return LibraryListState(
        items: page.items,
        total: page.total,
        hasNext: page.hasNext,
      );
    } catch (_) {
      final cached = _offlineLibrary(query);
      if (cached.isEmpty) rethrow;
      return LibraryListState(
        items: cached,
        total: cached.length,
        isOffline: true,
      );
    }
  }

  /// The offline library key for the active `(user, profile)`, or `null`
  /// outside a session — in which case there is nothing to cache and nothing
  /// cached to read, matching the on-device store's own "no scope, no data".
  String? get _cacheKey {
    final scopeId = ref.read(activeDownloadsScopeIdProvider);
    return scopeId == null ? null : followedSeriesCacheKeyFor(scopeId);
  }

  /// An unfiltered first page *is* the library, so it replaces the cache.
  /// Anything narrower (a search, a filter chip, a later page) can only be a
  /// subset, so it merges instead — never letting "Favorites only" shrink
  /// the shelf an offline launch will be shown.
  Future<void> _cachePage(
    LibraryQuery query,
    List<FollowedSeries> items, {
    required bool isFirstPage,
  }) async {
    final key = _cacheKey;
    if (key == null) return;
    final prefs = ref.read(sharedPrefsProvider);
    final authoritative = isFirstPage &&
        !query.isSearching &&
        !query.favoritesOnly &&
        query.filter == LibraryFilter.all;

    if (authoritative) {
      await writeCachedFollowedSeries(prefs, key, items);
      return;
    }
    final merged = {
      for (final series in readCachedFollowedSeries(prefs, key)) series.id: series,
      for (final series in items) series.id: series,
    };
    await writeCachedFollowedSeries(prefs, key, merged.values.toList());
  }

  /// The cached shelf, narrowed by the parts of [query] that can be honoured
  /// without a server. Sort order is left as cached: re-deriving "recently
  /// updated" offline would order the grid by data the cache does not have.
  List<FollowedSeries> _offlineLibrary(LibraryQuery query) {
    final key = _cacheKey;
    if (key == null) return const [];
    final search = query.search.trim().toLowerCase();
    final status = query.readingStatusParam;

    return [
      for (final series in readCachedFollowedSeries(ref.read(sharedPrefsProvider), key))
        if ((search.isEmpty || series.title.toLowerCase().contains(search)) &&
            (!query.favoritesOnly || series.isFavorite) &&
            (status == null || series.readingStatus == status))
          series,
    ];
  }

  Future<({List<FollowedSeries> items, int total, bool hasNext})> _fetchPage(
    LibraryQuery query,
    int page,
  ) =>
      fetchLibraryListPage(ref, query, page);
}

/// Drives federated search over the grouped `/sources/search` payload.
///
/// Loading always resolves: `build` returns an empty result for a blank query
/// and otherwise returns data or throws (→ AsyncError). Staleness is handled on
/// two fronts — Riverpod re-runs `build` whenever [searchQueryProvider] changes
/// and only the latest build's future is applied to state (so a slow response
/// for an old query is discarded), and an explicit request token guards the
/// imperative `loadMore`/`refresh`/`retrySource` paths. The UI additionally
/// debounces keystrokes before mutating [searchQueryProvider].
class SearchListNotifier
    extends AutoDisposeAsyncNotifier<GroupedSearchResult> {
  var _requestId = 0;

  /// Sources with a single-source retry in flight, so only that section
  /// shimmers instead of the whole screen.
  final _retrying = <String>{};

  @override
  Future<GroupedSearchResult> build() async {
    final query = ref.watch(searchQueryProvider).trim();
    if (query.isEmpty) {
      return const GroupedSearchResult();
    }
    final requestId = ++_requestId;
    _retrying.clear();
    final result =
        await ref.read(sourcesRepositoryProvider).searchGrouped(query);
    // Guard against a superseded query resolving late.
    if (requestId != _requestId) {
      return state.valueOrNull ?? const GroupedSearchResult();
    }
    if (result.isErr) throw result.error;
    return result.value;
  }

  bool isRetrying(String sourceId) => _retrying.contains(sourceId);

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }

  Future<void> loadMore() async {
    // While a new query's first page is on its way, the value still held is
    // the OLD query's. Paging it would ask for page 2 of the new query, win
    // the request-id race against that query's page 1, and merge the two for
    // good: the old hits plus the new query's second page, its first never
    // shown.
    if (state.isLoading) return;
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.isLoadingMore) return;

    final query = ref.read(searchQueryProvider).trim();
    if (query.isEmpty) return;

    final requestId = ++_requestId;
    state = AsyncData(current.copyWith(isLoadingMore: true));

    final nextPage = current.page + 1;
    final result = await ref
        .read(sourcesRepositoryProvider)
        .searchGrouped(query, page: nextPage);

    // Ignore if a newer query/refresh superseded this page request.
    if (requestId != _requestId) return;

    final latest = state.valueOrNull ?? current;
    if (result.isErr) {
      // Keep the results we already have; just stop the load-more spinner.
      state = AsyncData(latest.copyWith(isLoadingMore: false));
      return;
    }

    state = AsyncData(latest.mergePage(result.value));
  }

  /// Re-query a single source that failed, without re-running the federation.
  ///
  /// Goes to that source's own browse endpoint rather than `/sources/search`,
  /// which is the only way to retry one section: a second federated call would
  /// pay for all ~50 sources to fix one.
  Future<void> retrySource(String sourceId) async {
    final current = state.valueOrNull;
    final query = ref.read(searchQueryProvider).trim();
    if (current == null || query.isEmpty || _retrying.contains(sourceId)) return;

    final requestId = _requestId;
    _retrying.add(sourceId);
    // A fresh instance (GroupedSearchResult has no value equality) is what
    // makes listeners rebuild and observe the new `isRetrying` answer.
    state = AsyncData(current.copyWith());

    final result = await ref
        .read(sourcesRepositoryProvider)
        .listSeries(sourceId, query: query);

    _retrying.remove(sourceId);
    // A newer query replaced these results while the retry was in flight.
    if (requestId != _requestId) return;

    final latest = state.valueOrNull;
    if (latest == null) return;

    state = AsyncData(
      latest.copyWith(
        groups: [
          for (final group in latest.groups)
            if (group.source != sourceId)
              group
            else if (result.isErr)
              group.copyWith(
                status: SourceGroupStatus.error,
                error: result.error.userMessage,
              )
            else
              group.copyWith(
                status: result.value.items.isEmpty
                    ? SourceGroupStatus.empty
                    : SourceGroupStatus.ok,
                clearError: true,
                total: result.value.items.length,
                hasMore: result.value.hasNext,
                items: [
                  for (final series in result.value.items)
                    GlobalSearchItem(
                      kind: 'source',
                      source: sourceId,
                      seriesId: series.id,
                      title: series.title,
                      coverUrl:
                          series.coverUrl.isEmpty ? null : series.coverUrl,
                      author: series.author,
                    ),
                ],
              ),
        ],
        sourcesFailed: result.isErr
            ? latest.sourcesFailed
            : (latest.sourcesFailed - 1).clamp(0, latest.sourcesQueried),
      ),
    );
  }
}

Future<({List<FollowedSeries> items, int total, bool hasNext})> fetchLibraryListPage(
  Ref ref,
  LibraryQuery query,
  int page,
) async {
  final repo = ref.read(libraryRepositoryProvider);

  // The backend's `/library/series` sort/search/filter params cover search
  // and browse alike (`FollowedSeriesService.search` is a thin wrapper over
  // `list_series`), so both funnel through the one call — no client-side
  // re-sort or re-filter needed.
  final perPage = query.isSearching ? _searchPageSize : _listPageSize;
  final result = await repo.listSeries(
    page: page,
    perPage: perPage,
    sort: query.sortParam,
    search: query.isSearching ? query.search.trim() : null,
    readingStatus: query.readingStatusParam,
    isFavorite: query.favoritesOnly ? true : null,
  );
  if (result.isErr) throw result.error;

  final paged = result.value;
  return (
    items: paged.items,
    total: paged.total,
    hasNext: paged.hasNext,
  );
}
