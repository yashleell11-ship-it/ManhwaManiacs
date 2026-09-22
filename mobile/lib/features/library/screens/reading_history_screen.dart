import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/responsive.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/content_mode/widgets/content_mode_chip.dart';
import 'package:manhwamaniacs/features/library/providers/intelligence_providers.dart';
import 'package:manhwamaniacs/features/library/widgets/history/history_series_card.dart';
import 'package:manhwamaniacs/shared/widgets/empty_state.dart';
import 'package:manhwamaniacs/shared/widgets/premium/hero_heading.dart';
import 'package:manhwamaniacs/shared/widgets/skeleton_box.dart';

/// Reading history — source-native (`GET /reader/history`). Rows are stored
/// reading positions, not sessions: no start/end page range and no calendar
/// (both removed with the local catalog and the reading_sessions aggregation
/// the old backend built them from).
///
/// Each row leads with the BOOK. It used to lead with a chapter number over a
/// raw connector id, which made every row look like every other row — fifty
/// books rendering as fifty near-identical cards, none of them saying what
/// you had been reading. A position is meaningless without the thing it is a
/// position in.
class ReadingHistoryScreen extends ConsumerWidget {
  const ReadingHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(readingHistoryProvider);
    final scope = ref.watch(contentModeScopeProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go(Routes.library),
        ),
        title: const Text('Reading History'),
        actions: const [ContentModeChip()],
      ),
      body: historyAsync.when(
        loading: () => ListView(
          padding: EdgeInsets.all(context.space.xl2),
          children: [
            const SkeletonBox(width: double.infinity, height: 100),
            SizedBox(height: context.space.md),
            const SkeletonBox(width: double.infinity, height: 100),
          ],
        ),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error is AppError ? error.userMessage : 'Failed to load reading history.',
                style: context.text.body.copyWith(color: context.colors.danger),
              ),
              SizedBox(height: context.space.lg),
              FilledButton(
                onPressed: () => ref.invalidate(readingHistoryProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (allSessions) {
          final sessions = scope.filter(allSessions, (s) => s.sourceId);
          final layout = context.layout;
          final columns = layout.columnsFor(context.seriesGridColumns);
          final spacing = context.space.md;
          final contentWidth =
              MediaQuery.sizeOf(context).width - context.space.xl2 * 2;
          final coverWidth = gridTileWidth(
            available: contentWidth,
            columns: columns,
            spacing: spacing,
          );

          return RefreshIndicator(
            color: context.colors.primary,
            onRefresh: () async => ref.invalidate(readingHistoryProvider),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    context.space.xl2,
                    context.space.xl2,
                    context.space.xl2,
                    context.space.lg,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const HeroHeading(text: 'Reading History'),
                        SizedBox(height: context.space.xs),
                        Text(
                          'Books you have been reading, most recent first.',
                          style: context.text.body.copyWith(
                            color: context.colors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (sessions.isEmpty)
                  SliverPadding(
                    padding: EdgeInsets.all(context.space.xl2),
                    sliver: const SliverToBoxAdapter(
                      child: EmptyState(
                        icon: Icons.history,
                        message: 'No reading history yet',
                        subtitle:
                            'Open a chapter from your library to start '
                            'tracking history.',
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.space.xl2,
                    ),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            crossAxisSpacing: spacing,
                            mainAxisSpacing: context.space.xl,
                            childAspectRatio: layout.gridAspectRatio,
                          ),
                      itemCount: sessions.length,
                      itemBuilder: (context, index) {
                        final item = sessions[index];
                        final isNovel =
                            scope.modeOf(item.sourceId) == ContentMode.novel;
                        return HistorySeriesCard(
                          item: item,
                          coverWidth: coverWidth,
                          // The cover opens the book's page, exactly as it
                          // does on the library shelf.
                          onTap: () => context.push(
                            RoutePaths.sourceSeriesDetail(
                              item.sourceId,
                              item.seriesKey,
                            ),
                          ),
                          // And the play badge goes straight back into the
                          // chapter, which is why somebody opened history.
                          onContinue: () => context.push(
                            isNovel
                                ? RoutePaths.novelReader(
                                    item.sourceId,
                                    item.seriesKey,
                                    item.chapterKey,
                                  )
                                : RoutePaths.reader(
                                    item.sourceId,
                                    item.seriesKey,
                                    item.chapterKey,
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
                SliverToBoxAdapter(
                  child: SizedBox(height: context.space.xl2),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
