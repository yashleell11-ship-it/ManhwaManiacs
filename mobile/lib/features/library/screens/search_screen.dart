import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/features/content_mode/widgets/content_mode_chip.dart';
import 'package:manhwamaniacs/features/library/models/global_search_result.dart';
import 'package:manhwamaniacs/features/library/models/library_query.dart';
import 'package:manhwamaniacs/features/library/providers/library_list_provider.dart';
import 'package:manhwamaniacs/features/library/utils/recent_searches.dart';
import 'package:manhwamaniacs/features/library/widgets/library/library_skeleton.dart';
import 'package:manhwamaniacs/features/library/widgets/search/global_search_result_card.dart';
import 'package:manhwamaniacs/features/library/widgets/search/search_suggestions.dart';
import 'package:manhwamaniacs/features/profiles/providers/profiles_providers.dart';
import 'package:manhwamaniacs/features/sources/models/source_search_group.dart';
import 'package:manhwamaniacs/features/sources/providers/source_pins_provider.dart';
import 'package:manhwamaniacs/features/sources/utils/source_branding.dart';
import 'package:manhwamaniacs/features/sources/widgets/filter_pill.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/widgets/premium/fade_in.dart';
import 'package:manhwamaniacs/shared/widgets/premium/hero_heading.dart';
import 'package:manhwamaniacs/shared/widgets/premium/primary_pill_button.dart';
import 'package:manhwamaniacs/shared/widgets/scroll_reveal.dart';
import 'package:manhwamaniacs/shared/widgets/skeleton_box.dart';

/// Federated search, grouped per source.
///
/// The screen renders `/sources/search`'s `groups` payload — the local library
/// first, then one section per queried source — rather than the flat merged
/// feed it used to show. With ~50 connectors answering a single query, a flat
/// list buried the library's own hits under whichever source happened to be
/// fast; a section per source keeps "where did this come from" answerable at a
/// glance, and lets one slow/failed source fail on its own instead of taking
/// the whole screen down with it.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  var _recentSearches = <String>[];
  String? _lastPersistedQuery;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadRecentSearches();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _loadRecentSearches() {
    final prefs = ref.read(sharedPrefsProvider);
    final profileId = ref.read(activeProfileProvider)?.id;
    setState(
      () => _recentSearches = readRecentSearches(prefs, profileId: profileId),
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 320) {
      ref.read(searchListProvider.notifier).loadMore();
    }
  }

  /// Debounce keystrokes so we only issue a federated search once typing
  /// settles — this is the first line of stale-response defence.
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(searchQueryProvider.notifier).state = value.trim();
    });
  }

  void _applySuggestion(String value) {
    _searchDebounce?.cancel();
    _searchController.text = value;
    ref.read(searchQueryProvider.notifier).state = value.trim();
  }

  /// Skips the debounce. The field asks for a Search key
  /// (`TextInputAction.search`) and then ignored it, so the one gesture that
  /// says "I have finished typing" was the one that did nothing.
  void _submitSearch(String value) {
    _searchDebounce?.cancel();
    ref.read(searchQueryProvider.notifier).state = value.trim();
  }

  Future<void> _persistRecentSearch(String trimmedQuery) async {
    if (trimmedQuery.length < 2 || _lastPersistedQuery == trimmedQuery) return;
    _lastPersistedQuery = trimmedQuery;
    final prefs = ref.read(sharedPrefsProvider);
    final profileId = ref.read(activeProfileProvider)?.id;
    await writeRecentSearch(prefs, trimmedQuery, profileId: profileId);
    if (mounted) {
      setState(
        () => _recentSearches = readRecentSearches(prefs, profileId: profileId),
      );
    }
  }

  void _openItem(GlobalSearchItem item) {
    if (item.isLocal) {
      final id = int.tryParse(item.seriesId);
      if (id != null) context.push(RoutePaths.seriesDetail(id));
      return;
    }
    final source = item.source;
    if (source != null && source.isNotEmpty) {
      context.push(RoutePaths.sourceSeriesDetail(source, item.seriesId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider).trim();
    final listAsync = ref.watch(searchListProvider);
    final visibleGroups = ref.watch(visibleSearchGroupsProvider);
    final groupFilter = ref.watch(searchGroupFilterProvider);
    final pinnedIds = ref.watch(pinnedSourceIdsProvider);
    final hasQuery = query.isNotEmpty;

    ref.listen<AsyncValue<GroupedSearchResult>>(searchListProvider,
        (previous, next) {
      next.whenData((state) {
        if (hasQuery && !next.isLoading && !state.isEmpty) {
          _persistRecentSearch(query);
        }
      });
    });

    return Scaffold(
      backgroundColor: context.colors.bg,
      // A new query is a reload, and it shows as loading. Skipping it drew the
      // PREVIOUS query's sections under "N results found" for the whole
      // fan-out, and the very first search "No results found", because the
      // value carried over was the blank query's empty result. A pull to
      // refresh of the same query still keeps its sections on screen.
      body: listAsync.when(
        loading: () => _SearchScrollView(
          scrollController: _scrollController,
          onRefresh: () => ref.read(searchListProvider.notifier).refresh(),
          slivers: _contentSlivers(
            hasQuery: hasQuery,
            isLoading: true,
            state: null,
            groups: const [],
            groupFilter: groupFilter,
            pinnedIds: pinnedIds,
          ),
        ),
        error: (error, _) => _SearchError(
          error: error is AppError
              ? error
              : UnknownError(message: error.toString(), cause: error),
          onRetry: () => ref.read(searchListProvider.notifier).refresh(),
        ),
        data: (state) => _SearchScrollView(
          scrollController: _scrollController,
          onRefresh: () => ref.read(searchListProvider.notifier).refresh(),
          slivers: _contentSlivers(
            hasQuery: hasQuery,
            isLoading: false,
            state: state,
            groups: visibleGroups,
            groupFilter: groupFilter,
            pinnedIds: pinnedIds,
          ),
        ),
      ),
    );
  }

  /// Builds the screen as lazily-evaluated slivers so a 50-source answer stays
  /// virtualized: the header is one adapter sliver and the sections are a
  /// `SliverList.builder`, so only on-screen sections (and their auth-gated
  /// cover images) are ever materialized.
  List<Widget> _contentSlivers({
    required bool hasQuery,
    required bool isLoading,
    required GroupedSearchResult? state,
    required List<SourceSearchGroup> groups,
    required SearchGroupFilter groupFilter,
    required List<String> pinnedIds,
  }) {
    final horizontalPadding = EdgeInsets.symmetric(horizontal: context.space.xl2);

    // "Nothing matched anywhere" is the one case that earns the full empty
    // panel. If any source failed we still draw the sections, because the
    // per-source error rows (and their Retry) are the only way back.
    final showEmptyPanel = hasQuery &&
        !isLoading &&
        state != null &&
        state.isEmpty &&
        state.sourcesFailed == 0;
    final showSections =
        hasQuery && !isLoading && state != null && !showEmptyPanel;

    final slivers = <Widget>[
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          context.space.xl2,
          context.space.xl2,
          context.space.xl2,
          0,
        ),
        sliver: SliverToBoxAdapter(
          child: _SearchHeader(
            hasQuery: hasQuery,
            isLoading: isLoading,
            state: state,
            showEmptyPanel: showEmptyPanel,
            showGroupFilters: showSections,
            groupFilter: groupFilter,
            pinnedIds: pinnedIds,
            recentSearches: _recentSearches,
            searchController: _searchController,
            onSearchChanged: _onSearchChanged,
            onSubmitSearch: _submitSearch,
            onSelectSuggestion: _applySuggestion,
            onGroupFilterChanged: (value) =>
                ref.read(searchGroupFilterProvider.notifier).state = value,
          ),
        ),
      ),
    ];

    if (showSections && groups.isEmpty) {
      slivers.add(
        SliverPadding(
          padding: horizontalPadding,
          sliver: SliverToBoxAdapter(
            child: _NoteCard(
              icon: Icons.filter_alt_off,
              title: 'No sources in this view',
              message: groupFilter == SearchGroupFilter.pinned
                  ? 'Pin a source on the Sources tab to keep it here.'
                  : 'Switch back to All to see every source that answered.',
            ),
          ),
        ),
      );
    } else if (showSections) {
      final notifier = ref.read(searchListProvider.notifier);
      slivers.add(
        SliverPadding(
          padding: horizontalPadding,
          sliver: SliverList.builder(
            itemCount: groups.length,
            itemBuilder: (context, index) {
              final group = groups[index];
              final sourceId = group.source;
              return ScrollReveal(
                key: ValueKey(group.key),
                index: index,
                child: _SourceSection(
                  group: group,
                  isRetrying:
                      sourceId != null && notifier.isRetrying(sourceId),
                  onRetry: sourceId == null
                      ? null
                      : () => notifier.retrySource(sourceId),
                  onOpenItem: _openItem,
                ),
              );
            },
          ),
        ),
      );
    }

    slivers.add(
      SliverPadding(
        padding: horizontalPadding,
        sliver: SliverToBoxAdapter(
          child: Column(
            children: [
              if (state?.isLoadingMore ?? false) ...[
                SizedBox(height: context.space.xl2),
                Center(
                  child: Padding(
                    padding: EdgeInsets.all(context.space.lg),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: context.colors.primary,
                    ),
                  ),
                ),
              ],
              // Clear the floating nav bar (56pt) and the gap it floats in
              // (the bottom inset, 34pt on an iPhone) — the shell sets
              // `extendBody`, so the last result otherwise comes to rest
              // underneath both. Matches sources_list_screen.dart.
              SizedBox(
                height: context.space.xl7 + MediaQuery.paddingOf(context).bottom,
              ),
            ],
          ),
        ),
      ),
    );

    return slivers;
  }
}

/// Non-result header: hero heading, search field, the status/progress line and
/// section filters, and the pre-results states (suggestions, loading skeleton,
/// and the empty "No results found" panel). The per-source sections are
/// rendered as separate virtualized slivers by the parent.
class _SearchHeader extends StatelessWidget {
  const _SearchHeader({
    required this.hasQuery,
    required this.isLoading,
    required this.showEmptyPanel,
    required this.showGroupFilters,
    required this.groupFilter,
    required this.pinnedIds,
    required this.recentSearches,
    required this.searchController,
    required this.onSearchChanged,
    required this.onSubmitSearch,
    required this.onSelectSuggestion,
    required this.onGroupFilterChanged,
    this.state,
  });

  final bool hasQuery;
  final bool isLoading;
  final bool showEmptyPanel;
  final bool showGroupFilters;
  final SearchGroupFilter groupFilter;
  final List<String> pinnedIds;
  final GroupedSearchResult? state;
  final List<String> recentSearches;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onSubmitSearch;
  final ValueChanged<String> onSelectSuggestion;
  final ValueChanged<SearchGroupFilter> onGroupFilterChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FadeIn(
          child: Padding(
            padding: EdgeInsets.only(bottom: context.space.xl2),
            // The mode decides which sources answer a query at all, so it
            // belongs on this screen — but beside the heading, not above the
            // All / With results / Pinned row, where a second segmented
            // control would read as a fourth per-view filter.
            child: const Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: HeroHeading(text: 'Search', fontSize: 40),
                  ),
                ),
                ContentModeChip(padding: EdgeInsets.zero),
              ],
            ),
          ),
        ),
        TextField(
          controller: searchController,
          onChanged: onSearchChanged,
          onSubmitted: onSubmitSearch,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.search, color: context.colors.muted),
            hintText: 'Search manga, manhwa, webtoons…',
            filled: true,
            fillColor: context.colors.fg.withAlpha(8),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(context.radii.xl),
              borderSide: BorderSide(color: context.colors.border.withAlpha(128)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(context.radii.xl),
              borderSide: BorderSide(color: context.colors.border.withAlpha(128)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(context.radii.xl),
              borderSide: BorderSide(color: context.colors.primary.withAlpha(77)),
            ),
            contentPadding: EdgeInsets.symmetric(
              horizontal: context.space.xl2,
              vertical: context.space.lg,
            ),
          ),
        ),
        if (!hasQuery) ...[
          SizedBox(height: context.space.xl2),
          SearchSuggestionsPanel(
            recentSearches: recentSearches,
            onSelect: onSelectSuggestion,
            filtersOpen: false,
            onToggleFilters: () {},
          ),
        ],
        if (hasQuery) ...[
          SizedBox(height: context.space.xl2),
          _StatusLine(isLoading: isLoading, state: state),
          if (showGroupFilters && state != null) ...[
            SizedBox(height: context.space.lg),
            _GroupFilterRow(
              filter: groupFilter,
              onChanged: onGroupFilterChanged,
              allCount: state!.groups.length,
              withResultsCount: state!.groupsWithResults.length,
              pinnedCount: state!.groups
                  .where(
                    (group) =>
                        group.isLocal || pinnedIds.contains(group.source),
                  )
                  .length,
            ),
          ],
          SizedBox(height: context.space.xl),
          if (isLoading)
            const _SearchSectionsSkeleton()
          else if (showEmptyPanel)
            const LibraryEmptyPanel(emptyState: LibraryEmptyState.search),
        ],
      ],
    );
  }
}

/// Which source sections are on screen. Client-side only, so the chips carry
/// their own counts — otherwise "Pinned" looks broken when nothing is pinned.
class _GroupFilterRow extends StatelessWidget {
  const _GroupFilterRow({
    required this.filter,
    required this.onChanged,
    required this.allCount,
    required this.withResultsCount,
    required this.pinnedCount,
  });

  final SearchGroupFilter filter;
  final ValueChanged<SearchGroupFilter> onChanged;
  final int allCount;
  final int withResultsCount;
  final int pinnedCount;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: FilterPill.height,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          FilterPill(
            label: 'All',
            count: allCount,
            selected: filter == SearchGroupFilter.all,
            onTap: () => onChanged(SearchGroupFilter.all),
          ),
          SizedBox(width: context.space.sm),
          FilterPill(
            label: 'With results',
            count: withResultsCount,
            selected: filter == SearchGroupFilter.hasResults,
            onTap: () => onChanged(SearchGroupFilter.hasResults),
          ),
          SizedBox(width: context.space.sm),
          FilterPill(
            label: 'Pinned',
            count: pinnedCount,
            selected: filter == SearchGroupFilter.pinned,
            onTap: () => onChanged(SearchGroupFilter.pinned),
          ),
        ],
      ),
    );
  }
}

/// One source's slice of the answer: a header identifying the source, then its
/// matches — or that source's own loading / empty / failed state, so a dead
/// connector costs one row instead of the whole screen.
class _SourceSection extends StatelessWidget {
  const _SourceSection({
    required this.group,
    required this.isRetrying,
    required this.onRetry,
    required this.onOpenItem,
  });

  final SourceSearchGroup group;
  final bool isRetrying;

  /// Null for the local library group — there is no remote call to retry.
  final VoidCallback? onRetry;
  final ValueChanged<GlobalSearchItem> onOpenItem;

  /// Cover-first cards on a horizontal shelf: at ~50 sections, stacking every
  /// source's hits vertically would make the second source unreachable.
  static const double cardWidth = 112;
  static const double shelfHeight = 200;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.space.xl2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SourceSectionHeader(group: group),
          SizedBox(height: context.space.md),
          _body(context),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (isRetrying) return const _ShelfSkeleton();

    if (group.hasError) {
      return _SourceSectionNote(
        icon: Icons.cloud_off,
        message: group.error ?? 'This source did not answer.',
        tone: context.colors.danger,
        onRetry: onRetry,
      );
    }

    if (group.items.isEmpty) {
      return _SourceSectionNote(
        icon: Icons.search_off,
        // A backend-supplied note on an empty group means the source answered
        // with results it judged irrelevant — worth saying, because "nothing
        // matched" and "this source returned noise" are different problems.
        message: group.error ?? 'No matches',
        tone: context.colors.muted,
      );
    }

    return SizedBox(
      height: shelfHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: group.items.length,
        separatorBuilder: (_, __) => SizedBox(width: context.space.md),
        itemBuilder: (context, index) {
          final item = group.items[index];
          return SizedBox(
            width: cardWidth,
            child: GlobalSearchResultGridCard(
              item: item,
              coverWidth: cardWidth,
              // The section header already names the source; repeating it on
              // every cover is noise.
              showSourceBadge: false,
              onTap: () => onOpenItem(item),
            ),
          );
        },
      ),
    );
  }
}

class _SourceSectionHeader extends StatelessWidget {
  const _SourceSectionHeader({required this.group});

  final SourceSearchGroup group;

  static const double _logoSize = 28;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (group.isLocal)
          Container(
            width: _logoSize,
            height: _logoSize,
            decoration: BoxDecoration(
              color: context.colors.primary.withAlpha(28),
              borderRadius: BorderRadius.circular(context.radii.md),
              border: Border.all(color: context.colors.primary.withAlpha(90)),
            ),
            child: Icon(
              Icons.bookmark_outline,
              size: 16,
              color: context.colors.primary,
            ),
          )
        else
          SourceLogo(
            id: group.source ?? '',
            name: group.sourceName,
            iconUrl: group.iconUrl,
            size: _logoSize,
          ),
        SizedBox(width: context.space.md),
        Flexible(
          child: Text(
            group.sourceName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.labelLg.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colors.fg,
            ),
          ),
        ),
        if (group.items.isNotEmpty) ...[
          SizedBox(width: context.space.sm),
          _CountBadge(count: group.total),
        ],
      ],
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.space.sm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: context.colors.fg.withAlpha(13),
        borderRadius: BorderRadius.circular(context.radii.full),
        border: Border.all(color: context.colors.border.withAlpha(128)),
      ),
      child: Text(
        '$count',
        style: context.text.caption.copyWith(
          color: context.colors.muted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// One-line stand-in for a section with nothing to show — kept to a single row
/// so a query that only two sources answer doesn't become fifty empty panels.
class _SourceSectionNote extends StatelessWidget {
  const _SourceSectionNote({
    required this.icon,
    required this.message,
    required this.tone,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final Color tone;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: tone.withAlpha(180)),
        SizedBox(width: context.space.sm),
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.bodySm.copyWith(color: tone),
          ),
        ),
        if (onRetry != null)
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: context.colors.primary,
              minimumSize: const Size(64, 36),
              padding: EdgeInsets.symmetric(horizontal: context.space.md),
            ),
            child: Text('Retry', style: context.text.label),
          ),
      ],
    );
  }
}

/// Panel for "your filter hid everything" — distinct from "nothing matched",
/// which is what [LibraryEmptyPanel] says.
class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(context.space.xl2),
      decoration: BoxDecoration(
        color: context.colors.panel,
        borderRadius: BorderRadius.circular(context.radii.xl),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 28, color: context.colors.muted.withAlpha(140)),
          SizedBox(height: context.space.md),
          Text(title, style: context.text.h4, textAlign: TextAlign.center),
          SizedBox(height: context.space.sm),
          Text(
            message,
            style: context.text.body.copyWith(color: context.colors.muted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Loading state shaped like the sections it becomes, so the screen doesn't
/// reflow when the answer lands.
class _SearchSectionsSkeleton extends StatelessWidget {
  const _SearchSectionsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < 3; i++) ...[
          Row(
            children: [
              const SkeletonBox(width: 28, height: 28),
              SizedBox(width: context.space.md),
              const SkeletonBox(width: 120, height: 14),
            ],
          ),
          SizedBox(height: context.space.md),
          const _ShelfSkeleton(),
          SizedBox(height: context.space.xl2),
        ],
      ],
    );
  }
}

class _ShelfSkeleton extends StatelessWidget {
  const _ShelfSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _SourceSection.shelfHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: 4,
        separatorBuilder: (_, __) => SizedBox(width: context.space.md),
        itemBuilder: (_, __) => const SkeletonBox(
          width: _SourceSection.cardWidth,
          height: _SourceSection.shelfHeight,
        ),
      ),
    );
  }
}

/// The search status/progress line — never an endless spinner. While a request
/// is in flight it reads "Searching sources…"; once resolved it reports the
/// result count and how many sources were queried, plus a subtle unavailable
/// note when some sources failed.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.isLoading, required this.state});

  final bool isLoading;
  final GroupedSearchResult? state;

  @override
  Widget build(BuildContext context) {
    if (isLoading || state == null) {
      return Text(
        'Searching sources…',
        style: context.text.body.copyWith(color: context.colors.muted),
      );
    }

    final count = state!.resultCount;
    final queried = state!.sourcesQueried;
    final failed = state!.sourcesFailed;

    final buffer = StringBuffer()
      ..write('$count ${count == 1 ? 'result' : 'results'} found');
    if (queried > 0) {
      buffer.write(' · $queried ${queried == 1 ? 'source' : 'sources'}');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          buffer.toString(),
          style: context.text.body.copyWith(color: context.colors.muted),
        ),
        if (failed > 0) ...[
          const SizedBox(height: 2),
          Text(
            'Some sources unavailable',
            style: context.text.caption.copyWith(
              color: context.colors.warning.withAlpha(204),
            ),
          ),
        ],
      ],
    );
  }
}

class _SearchScrollView extends StatelessWidget {
  const _SearchScrollView({
    required this.scrollController,
    required this.onRefresh,
    required this.slivers,
  });

  final ScrollController scrollController;
  final Future<void> Function() onRefresh;
  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: context.colors.primary,
      child: CustomScrollView(
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: slivers,
      ),
    );
  }
}

class _SearchError extends StatelessWidget {
  const _SearchError({required this.error, required this.onRetry});

  final AppError error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.space.xl3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: context.colors.danger, size: 48),
            SizedBox(height: context.space.lg),
            Text(
              'Search failed',
              style: context.text.h3,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: context.space.sm),
            Text(
              error.userMessage,
              style: context.text.body.copyWith(color: context.colors.muted),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: context.space.xl2),
            PrimaryPillButton(
              label: 'Try Again',
              icon: Icons.refresh,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
