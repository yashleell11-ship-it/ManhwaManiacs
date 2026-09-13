import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/responsive.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/content_mode/widgets/content_mode_switch.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/utils/library_shelf.dart';
import 'package:manhwamaniacs/features/library/widgets/home/followed_series_card.dart';
import 'package:manhwamaniacs/features/library/widgets/library/continue_reading_strip.dart';
import 'package:manhwamaniacs/features/library/widgets/library/series_actions_sheet.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_shelf.dart';
import 'package:manhwamaniacs/features/profiles/widgets/profile_switcher_chip.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/widgets/empty_state.dart';
import 'package:manhwamaniacs/shared/widgets/premium/fade_in.dart';
import 'package:manhwamaniacs/shared/widgets/premium/hero_heading.dart';
import 'package:manhwamaniacs/shared/widgets/premium/primary_pill_button.dart';
import 'package:manhwamaniacs/shared/widgets/scroll_reveal.dart';
import 'package:manhwamaniacs/shared/widgets/skeleton_box.dart';

/// Library tab — the followed series, and nothing else.
///
/// Deliberately spare (DESIGN_SYSTEM.md hard constraint: "Library tab (mobile)
/// = followed series only"): one heading, and one grid of covers — or, in
/// Novels mode, one shelf of books. Tapping either opens that series' detail
/// screen, where the full chapter list lives with the latest chapter first.
/// Browse Sources is reachable from exactly one place at a time — the empty
/// state when there is nothing followed yet, otherwise the small app-bar
/// action.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    // Dismiss any download queue snackbar left over from series detail.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    });
  }

  Future<void> _refresh() => ref.read(updatesProvider.notifier).refresh();

  /// The same menu the browse screen under this tab opens, on the tab the
  /// reader actually lands on. Unconditional, unlike over there: this screen
  /// has no multi-select for a long-press to fire underneath.
  void _showSeriesActions(FollowedSeries series) {
    unawaited(
      showSeriesActionsSheet(
        context,
        ref,
        series,
        onOpen: () => _openSeries(context, series),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final updatesAsync = ref.watch(updatesProvider);
    final scope = ref.watch(contentModeScopeProvider);
    // Resolved once so the app bar and the body agree on whether the shelf is
    // empty (and therefore on which single Browse affordance is shown).
    // Scoped to the active mode: the Library tab is a list of what the reader
    // is currently reading, and in Novels mode that is books.
    final followed = scope.filter(
      _followedOf(updatesAsync.valueOrNull),
      (series) => series.sourceId,
    );

    return Scaffold(
      // Float the active-profile chip (Netflix-style) over the top-right of the
      // grid without pushing the heading down.
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: kToolbarHeight,
        automaticallyImplyLeading: false,
        actions: [
          // The single Browse affordance once the shelf has something on it —
          // with an empty shelf the empty state owns that job instead, so the
          // screen never shows two routes to the same place.
          if (followed.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.travel_explore_rounded),
              tooltip: 'Browse Sources',
              onPressed: () => context.go(Routes.sources),
            ),
          const ProfileSwitcherChip(),
          SizedBox(width: context.space.sm),
        ],
      ),
      body: updatesAsync.when(
        loading: () => _LibrarySkeleton(novels: scope.isNovel),
        error: (error, _) => _FollowedSeriesError(
          error: error is AppError
              ? error
              : UnknownError(message: error.toString(), cause: error),
          onRetry: () => ref.invalidate(updatesProvider),
        ),
        data: (data) {
          if (followed.isEmpty) {
            return _LibraryEmpty(onRefresh: _refresh, novels: scope.isNovel);
          }

          return RefreshIndicator(
            color: context.colors.primary,
            onRefresh: _refresh,
            child: _FollowedShelf(
              isNovelMode: scope.isNovel,
              followed: followed,
              metaBySeries: FollowedSeriesMeta.indexBySeries(
                scope.filter(
                  data.notifications,
                  (notification) => notification.sourceId,
                ),
              ),
              onOpenSeries: (series) => _openSeries(context, series),
              onSeriesLongPress: _showSeriesActions,
            ),
          );
        },
      ),
    );
  }

  List<FollowedSeries> _followedOf(UpdatesState? state) =>
      state?.followed ?? const [];

  void _openSeries(BuildContext context, FollowedSeries series) {
    context.push(
      RoutePaths.sourceSeriesDetail(series.sourceId, series.seriesKey),
    );
  }
}

/// The whole screen body: a heading, and under it the follows — a grid of
/// covers for manhwa, a shelf of books for novels.
class _FollowedShelf extends ConsumerWidget {
  const _FollowedShelf({
    required this.followed,
    required this.metaBySeries,
    required this.onOpenSeries,
    required this.onSeriesLongPress,
    required this.isNovelMode,
  });

  final List<FollowedSeries> followed;

  /// Notification-derived meta, already reduced to one entry per series.
  /// The item builder does a map lookup rather than a scan — see
  /// [FollowedSeriesMeta.indexBySeries].
  final Map<int, FollowedSeriesMeta> metaBySeries;

  final void Function(FollowedSeries) onOpenSeries;

  /// The per-row menu: favourite, and take it out of the library.
  final void Function(FollowedSeries) onSeriesLongPress;

  /// Novels are shelved, not gridded — the same inversion browsing makes, for
  /// the same reason. The reader's own library is where it matters most: the
  /// browse grid at least holds books the reader has never seen, while this
  /// screen would be showing him a page of identical generated rectangles and
  /// asking him to find the one he was reading last night.
  final bool isNovelMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    // "series" is already its own plural; "novel" is not.
    final countLine = isNovelMode
        ? '${followed.length} '
            '${followed.length == 1 ? 'novel' : 'novels'} on your shelf'
        : '${followed.length} series followed';
    final gutter = context.space.xl2;
    // Resolved here rather than inside the shelf's row builder, which runs
    // lazily — a `watch` from there would be a read on a closed element.
    final baseUrl = ref.watch(apiBaseUrlProvider);
    final columns = context.layout.columnsFor(context.seriesGridColumns);
    // The grid spans the viewport inside its own horizontal padding, so the
    // tile width is arithmetic rather than a measurement — and a card cannot
    // work it out for itself, because it fills whatever cell it is given.
    final coverWidth = gridTileWidth(
      available: context.screenWidth - context.space.xl2 * 2,
      columns: columns,
      spacing: context.space.md,
    );

    return CustomScrollView(
      // Always scrollable so pull-to-refresh still works with a single follow
      // that doesn't fill the viewport.
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            _headingTopPadding(context),
            gutter,
            context.space.xl,
          ),
          sliver: SliverToBoxAdapter(
            child: FadeIn(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const HeroHeading(text: 'Library', fontSize: 40),
                  SizedBox(height: context.space.xs),
                  Text(
                    countLine,
                    style:
                        context.text.caption.copyWith(color: context.colors.muted),
                  ),
                  // The app-wide Manga/Novels switch. Nothing renders here
                  // when the novels gate is shut.
                  Padding(
                    padding: EdgeInsets.only(top: context.space.md),
                    child: const ContentModeSwitch(),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Above the shelf, because resuming is what the reader came to do and
        // the shelf is how they find something else. Renders nothing when
        // there is no answer yet, so it never delays the follows below it.
        SliverToBoxAdapter(child: ContinueReadingStrip(gutter: gutter)),
        if (isNovelMode)
          NovelShelf(
            itemCount: followed.length,
            // Given the page gutter rather than wrapped in it, so the rows
            // line up with the heading while their hairlines still run the
            // full width — the edge of a shelf, not the side of a card.
            gutter: gutter,
            bookAt: (index) {
              final series = followed[index];
              final meta = metaBySeries[series.id] ?? FollowedSeriesMeta.none;
              return libraryShelfBook(
                series,
                apiBaseUrl: baseUrl,
                // What the grid card says in its one muted line, in the slot
                // the shelf keeps for it — and beside a chapter count the row
                // can now show as well, instead of choosing between them.
                note: latestChapterNote(meta.latestChapterLabel),
                unreadCount: meta.unreadCount,
                onTap: () => onOpenSeries(series),
                onLongPress: () => onSeriesLongPress(series),
              );
            },
          )
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: context.space.md,
                mainAxisSpacing: context.space.xl,
                childAspectRatio: 0.5,
              ),
              itemCount: followed.length,
              itemBuilder: (context, index) {
                final series = followed[index];
                return ScrollReveal(
                  index: index,
                  child: FollowedSeriesCard(
                    series: series,
                    coverWidth: coverWidth,
                    meta: metaBySeries[series.id] ?? FollowedSeriesMeta.none,
                    onTap: () => onOpenSeries(series),
                    onLongPress: () => onSeriesLongPress(series),
                  ),
                );
              },
            ),
          ),
        SliverToBoxAdapter(
          child: SizedBox(height: context.space.xl6 + bottomPad),
        ),
      ],
    );
  }
}

/// Clears the transparent app bar the body is drawn behind.
double _headingTopPadding(BuildContext context) =>
    MediaQuery.paddingOf(context).top + kToolbarHeight + context.space.lg;

/// Empty shelf — every account on this server starts here, so it has to say
/// what to do and offer the one way to do it.
class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({required this.onRefresh, required this.novels});

  final Future<void> Function() onRefresh;

  /// An empty shelf in Novels mode is a different sentence: there is nothing
  /// to follow *series* from here, and "library" is not what the owner calls
  /// the place he keeps books.
  final bool novels;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: context.colors.primary,
      onRefresh: onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.all(context.space.xl3),
              child: Center(
                child: EmptyState(
                  icon: Icons.menu_book_outlined,
                  message: novels ? 'Your shelf is empty' : 'Your library is empty',
                  subtitle: novels
                      ? 'Add a book from a novel source to start your shelf.'
                      : 'Follow series from Sources to build your warm little shelf.',
                  action: PrimaryPillButton(
                    label: 'Browse Sources',
                    icon: Icons.travel_explore_rounded,
                    onPressed: () => context.go(Routes.sources),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Loading shimmer shaped like the real thing, so nothing shifts on load —
/// which is why it has to know the mode too: a grid of poster blocks
/// resolving into a shelf of rows reflows the whole page on arrival.
class _LibrarySkeleton extends StatelessWidget {
  const _LibrarySkeleton({required this.novels});

  final bool novels;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      physics: const NeverScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            context.space.xl2,
            _headingTopPadding(context),
            context.space.xl2,
            context.space.xl,
          ),
          sliver: const SliverToBoxAdapter(
            child: SkeletonBox(width: 200, height: 40),
          ),
        ),
        if (novels)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: context.space.xl2),
            sliver: SliverList.builder(
              itemCount: 6,
              itemBuilder: (_, __) => Padding(
                padding: EdgeInsets.only(bottom: context.space.md),
                child: const SkeletonBox(width: double.infinity, height: 92),
              ),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: context.space.xl2),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:
                    context.layout.columnsFor(context.seriesGridColumns),
                crossAxisSpacing: context.space.md,
                mainAxisSpacing: context.space.xl,
                childAspectRatio: 0.5,
              ),
              itemCount: 6,
              itemBuilder: (_, __) => SkeletonBox(
                width: double.infinity,
                height: double.infinity,
                borderRadius: context.radii.xl,
              ),
            ),
          ),
      ],
    );
  }
}

class _FollowedSeriesError extends StatelessWidget {
  const _FollowedSeriesError({
    required this.error,
    required this.onRetry,
  });

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
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.colors.danger.withValues(alpha: 0.08),
              ),
              child: Icon(Icons.error_outline, color: context.colors.danger, size: 32),
            ),
            SizedBox(height: context.space.xl2),
            const HeroHeading(text: 'Oops', fontSize: 40, textAlign: TextAlign.center),
            SizedBox(height: context.space.sm),
            Text(
              error.userMessage,
              style: context.text.body.copyWith(color: context.colors.muted),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: context.space.xl3),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }
}
