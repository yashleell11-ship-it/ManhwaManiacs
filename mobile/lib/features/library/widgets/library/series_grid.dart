import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_metrics.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/core/utils/responsive.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/library_query.dart';
import 'package:manhwamaniacs/features/library/utils/cover_url.dart';
import 'package:manhwamaniacs/features/library/utils/read_state_label.dart';
import 'package:manhwamaniacs/features/library/utils/series_display.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/widgets/glass_card.dart';
import 'package:manhwamaniacs/shared/widgets/pressable.dart';
import 'package:manhwamaniacs/shared/widgets/scroll_reveal.dart';
import 'package:manhwamaniacs/shared/widgets/series_cover_image.dart';

class SeriesCard extends ConsumerWidget {
  const SeriesCard({
    super.key,
    required this.series,
    required this.coverWidth,
    required this.onTap,
    required this.onToggleFavorite,
    this.onRemove,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  final FollowedSeries series;

  /// Logical width of one grid tile — the card fills its cell, so only the
  /// grid that laid it out knows how wide the cover will actually be.
  final double coverWidth;

  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onRemove;
  final VoidCallback? onLongPress;

  /// Whether the library is in multi-select mode. When true, every card
  /// shows a checkbox circle instead of its usual favorite/remove buttons.
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baseUrl = ref.watch(apiBaseUrlProvider);

    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(context.radii.xl),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Hero(
                    tag: seriesCoverHeroTag(series.id),
                    child: SeriesCoverImage(
                      url: followedSeriesCoverUrl(baseUrl, series) ?? '',
                      displayWidth: coverWidth,
                      borderRadius: context.radii.xl,
                    ),
                  ),
                  if (selected)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.colors.primary.withAlpha(60),
                        border: Border.all(color: context.colors.primary, width: 3),
                        borderRadius: BorderRadius.circular(context.radii.xl),
                      ),
                    ),
                  // Bottom gradient for text legibility
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 110,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            context.colors.bg.withAlpha(240),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (series.readingStatus.isNotEmpty)
                    Positioned(
                      left: context.space.sm,
                      top: context.space.sm,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: context.space.sm,
                          vertical: context.space.xxs,
                        ),
                        decoration: BoxDecoration(
                          color: readingStatusColor(context, series.readingStatus)
                              .withAlpha(220),
                          borderRadius: BorderRadius.circular(context.radii.sm),
                        ),
                        child: Text(
                          readingStatusLabel(series.readingStatus).toUpperCase(),
                          style: context.text.caption.copyWith(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ),
                  if (selectionMode)
                    Positioned(
                      right: context.space.xs,
                      top: context.space.xs,
                      child: _SelectionCheckbox(selected: selected),
                    )
                  else ...[
                    Positioned(
                      right: context.space.xs,
                      top: context.space.xs,
                      child: _FavoriteButton(
                        isFavorite: series.isFavorite,
                        onPressed: onToggleFavorite,
                      ),
                    ),
                    if (onRemove != null)
                      Positioned(
                        left: context.space.xs,
                        top: context.space.xs,
                        child: _RemoveButton(onPressed: onRemove!),
                      ),
                  ],
                  Positioned(
                    left: context.space.md,
                    right: context.space.md,
                    bottom: context.space.md,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          series.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.label.copyWith(
                            color: Colors.white,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        // The chapter count is the line a minimal preset
                        // drops: it duplicates what the progress label under
                        // the cover already says, and on a smaller card the
                        // title needs the room more.
                        if (context.layout.cardDetail != CardDetail.minimal) ...[
                          SizedBox(height: context.space.xxs),
                          Text(
                            '${series.chapterCount} ch',
                            style: context.text.caption.copyWith(
                              color: Colors.white.withAlpha(160),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.space.xs),
          _ProgressLabel(series: series),
        ],
      ),
    );
  }
}

class SeriesListTile extends ConsumerWidget {
  const SeriesListTile({
    super.key,
    required this.series,
    required this.onTap,
    required this.onToggleFavorite,
    this.onRemove,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  final FollowedSeries series;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback? onRemove;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baseUrl = ref.watch(apiBaseUrlProvider);

    return GestureDetector(
      onLongPress: onLongPress,
      child: GlassCard(
      onTap: onTap,
      padding: EdgeInsets.all(context.space.md),
      child: Row(
        children: [
          Hero(
            tag: seriesCoverHeroTag(series.id),
            child: SeriesCoverImage(
              url: followedSeriesCoverUrl(baseUrl, series) ?? '',
              width: 64,
              height: 64,
            ),
          ),
          SizedBox(width: context.space.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: context.space.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      series.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.labelLg,
                    ),
                    if (series.readingStatus.isNotEmpty)
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: context.space.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: readingStatusColor(context, series.readingStatus)
                              .withAlpha(204),
                          borderRadius: BorderRadius.circular(context.radii.sm),
                        ),
                        child: Text(
                          readingStatusLabel(series.readingStatus).toUpperCase(),
                          style: context.text.caption.copyWith(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  seriesCardMeta(series),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.caption.copyWith(color: context.colors.muted),
                ),
              ],
            ),
          ),
          if (selectionMode)
            _SelectionCheckbox(selected: selected)
          else ...[
            _FavoriteButton(
              isFavorite: series.isFavorite,
              onPressed: onToggleFavorite,
              compact: true,
            ),
            if (onRemove != null) ...[
              SizedBox(width: context.space.sm),
              _RemoveButton(onPressed: onRemove!),
            ],
          ],
        ],
      ),
      ),
    );
  }
}

class _FavoriteButton extends StatelessWidget {
  const _FavoriteButton({
    required this.isFavorite,
    required this.onPressed,
    this.compact = false,
  });

  final bool isFavorite;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.bg.withAlpha(128),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: compact ? 36 : 32,
          height: compact ? 36 : 32,
          child: Icon(
            isFavorite ? Icons.star : Icons.star_border,
            size: compact ? 20 : 18,
            color: isFavorite ? context.colors.warning : context.colors.fg.withAlpha(179),
          ),
        ),
      ),
    );
  }
}

/// Selection-mode checkbox circle. The whole card's `onTap` toggles it
/// (wired by the parent screen), so this is purely a visual indicator, not
/// an interactive widget itself.
class _SelectionCheckbox extends StatelessWidget {
  const _SelectionCheckbox({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? context.colors.primary : context.colors.bg.withAlpha(150),
        border: Border.all(
          color: selected ? context.colors.primary : context.colors.fg.withAlpha(150),
          width: 1.5,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, size: 16, color: Colors.white)
          : null,
    );
  }
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.bg.withAlpha(179),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            Icons.remove_circle_outline,
            size: 18,
            color: context.colors.danger,
          ),
        ),
      ),
    );
  }
}

class _ProgressLabel extends StatelessWidget {
  const _ProgressLabel({required this.series});

  final FollowedSeries series;

  @override
  Widget build(BuildContext context) {
    if (series.isFavorite) {
      return Row(
        children: [
          Icon(Icons.star, size: 12, color: context.colors.warning),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              readStateNote(series.readState) ?? 'Favorite',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  context.text.caption.copyWith(color: context.colors.warning),
            ),
          ),
        ],
      );
    }

    // Where the reader is, rather than the follow's reading_status — which
    // is "reading" for every follow, opened or not.
    return Text(
      progressCardLabel(series),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.text.caption.copyWith(color: context.colors.muted),
    );
  }
}

/// The library shelf — a SLIVER, in both view modes.
///
/// Never a shrink-wrapped box grid. Under a `SliverToBoxAdapter` the main-axis
/// constraint is unbounded, so a shrink-wrapping viewport has to lay out every
/// child to find its own extent: every followed series was inflated, measured
/// and had its cover fetched and decoded the moment the tab opened, however
/// far down the shelf it sat. As a real sliver the viewport builds a screenful
/// plus the cache extent, and each child gets the repaint boundary a Column
/// never gave it.
class SeriesGrid extends ConsumerWidget {
  const SeriesGrid({
    super.key,
    required this.items,
    required this.viewMode,
    required this.contentWidth,
    required this.onSeriesTap,
    required this.onToggleFavorite,
    this.onRemoveSeries,
    this.onSeriesLongPress,
    this.coverScale = 1.0,
    this.selectionMode = false,
    this.selectedIds = const {},
  });

  final List<FollowedSeries> items;
  final LibraryViewMode viewMode;

  /// Logical width the shelf spans — the screen's content column, stated by
  /// the screen that owns the padding rather than measured here. A tile's
  /// width becomes part of its cover URL, which is the disk cache's key, so it
  /// has to be constant for a device and orientation.
  final double contentWidth;
  final ValueChanged<FollowedSeries> onSeriesTap;
  final ValueChanged<int> onToggleFavorite;
  final ValueChanged<int>? onRemoveSeries;
  final ValueChanged<FollowedSeries>? onSeriesLongPress;

  /// Cover-size multiplier; higher = larger covers / fewer columns.
  final double coverScale;

  /// Library multi-select: shows a checkbox on every card instead of the
  /// usual favorite/remove buttons when true.
  final bool selectionMode;
  final Set<int> selectedIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (viewMode == LibraryViewMode.list) {
      return SliverList.builder(
        // Nothing under a card dispatches a KeepAliveNotification, so the
        // AutomaticKeepAlive wrapper is one extra element per row for nothing.
        addAutomaticKeepAlives: false,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final series = items[index];
          return Padding(
            padding: EdgeInsets.only(bottom: context.space.md),
            child: ScrollReveal(
              index: index,
              child: SeriesListTile(
                series: series,
                onTap: () => onSeriesTap(series),
                onToggleFavorite: () => onToggleFavorite(series.id),
                onLongPress: onSeriesLongPress == null
                    ? null
                    : () => onSeriesLongPress!(series),
                onRemove: onRemoveSeries == null
                    ? null
                    : () => onRemoveSeries!(series.id),
                selectionMode: selectionMode,
                selected: selectedIds.contains(series.id),
              ),
            ),
          );
        },
      );
    }

    // Fewer columns as covers scale up; clamp to a sensible range. The design
    // preset then biases that: a density-first preset fits one more column in,
    // a content-maximal one takes one out to make the covers bigger.
    final layout = context.layout;
    final base = context.seriesGridColumns;
    final columns = layout.columnsFor((base / coverScale).round());
    final spacing = context.space.md;
    final coverWidth = gridTileWidth(
      available: contentWidth,
      columns: columns,
      spacing: spacing,
    );

    return SliverGrid.builder(
      addAutomaticKeepAlives: false,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: spacing,
        mainAxisSpacing: context.space.xl,
        childAspectRatio: layout.gridAspectRatio,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final series = items[index];
        return ScrollReveal(
          index: index,
          child: SeriesCard(
            series: series,
            coverWidth: coverWidth,
            onTap: () => onSeriesTap(series),
            onToggleFavorite: () => onToggleFavorite(series.id),
            onLongPress: onSeriesLongPress == null
                ? null
                : () => onSeriesLongPress!(series),
            onRemove:
                onRemoveSeries == null ? null : () => onRemoveSeries!(series.id),
            selectionMode: selectionMode,
            selected: selectedIds.contains(series.id),
          ),
        );
      },
    );
  }
}