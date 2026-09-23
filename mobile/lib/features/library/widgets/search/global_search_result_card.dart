import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/features/library/models/global_search_result.dart';
import 'package:manhwamaniacs/features/library/utils/cover_url.dart';
import 'package:manhwamaniacs/features/sources/utils/source_branding.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/widgets/glass_card.dart';
import 'package:manhwamaniacs/shared/widgets/series_cover_image.dart';

/// List-style result row for a federated search hit. Renders
/// [GlobalSearchItem.coverUrl], resolved against the API base (see
/// [searchResultCoverUrl]), via [SeriesCoverImage] and tags remote hits with a
/// source badge so the user can tell library results apart from results pulled
/// live from an external source.
class GlobalSearchResultCard extends ConsumerWidget {
  const GlobalSearchResultCard({
    super.key,
    required this.item,
    required this.onTap,
    this.footnote,
  });

  final GlobalSearchItem item;
  final VoidCallback onTap;

  /// One line under the source badge. Used by AI suggestions to say why this
  /// one was picked — the reason is the whole value of a suggestion, and a
  /// card that just names a book is indistinguishable from a search hit.
  final String? footnote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GlassCard(
      onTap: onTap,
      padding: EdgeInsets.all(context.space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SeriesCoverImage(
            url: searchResultCoverUrl(
                  ref.watch(apiBaseUrlProvider),
                  item.coverUrl,
                ) ??
                '',
            width: 72,
            height: 108,
          ),
          SizedBox(width: context.space.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelLg.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (item.author != null && item.author!.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.author!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.body.copyWith(color: context.colors.muted),
                  ),
                ],
                SizedBox(height: context.space.md),
                SourceBadge(item: item),
                if (footnote != null && footnote!.trim().isNotEmpty) ...[
                  SizedBox(height: context.space.sm),
                  Text(
                    footnote!,
                    style: context.text.caption.copyWith(
                      color: context.colors.muted,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact cover-first card for the search results grid and for the horizontal
/// shelves under each source section.
class GlobalSearchResultGridCard extends ConsumerWidget {
  const GlobalSearchResultGridCard({
    super.key,
    required this.item,
    required this.coverWidth,
    required this.onTap,
    this.showSourceBadge = true,
  });

  final GlobalSearchItem item;

  /// Logical width of the card — it fills whatever cell or shelf slot it is
  /// given, so the cover cannot state its own width without being told.
  final double coverWidth;

  final VoidCallback onTap;

  /// Off inside a per-source section, where the section header already says
  /// where these results came from.
  final bool showSourceBadge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(context.radii.md),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.colors.surface,
            borderRadius: BorderRadius.circular(context.radii.md),
            border: Border.all(color: context.colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 6,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    SeriesCoverImage(
                      url: searchResultCoverUrl(
                            ref.watch(apiBaseUrlProvider),
                            item.coverUrl,
                          ) ??
                          '',
                      displayWidth: coverWidth,
                      borderRadius: 0,
                    ),
                    if (showSourceBadge)
                      Positioned(
                        left: context.space.xxs,
                        top: context.space.xxs,
                        child: SourceBadge(item: item, compact: true),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.space.xs,
                    vertical: context.space.xxs,
                  ),
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.caption.copyWith(
                      color: context.colors.fg,
                      fontSize: 10,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small pill identifying where a result came from: "Library" for local hits,
/// or the prettified source name (e.g. "MangaDex") for remote hits.
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.item, this.compact = false});

  final GlobalSearchItem item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isLocal = item.isLocal;
    final label = isLocal
        ? 'Library'
        : prettifySourceId(item.source ?? 'source');
    final color = isLocal ? context.colors.cyan400 : context.colors.violet400;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? context.space.xs : context.space.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: compact
            ? context.colors.bg.withAlpha(204)
            : color.withAlpha(28),
        borderRadius: BorderRadius.circular(context.radii.sm),
        border: Border.all(color: color.withAlpha(compact ? 120 : 77)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isLocal ? Icons.bookmark_outline : Icons.public,
            size: 11,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            label.toUpperCase(),
            style: context.text.caption.copyWith(
              color: color,
              fontSize: compact ? 8 : 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
