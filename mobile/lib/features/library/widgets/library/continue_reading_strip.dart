import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/sources/utils/chapter_label.dart';
import 'package:manhwamaniacs/shared/widgets/glass_card.dart';

/// "Where you were", across the top of the Library tab.
///
/// The gap this closes: resuming on the phone used to cost a cold launch, a
/// profile pick, a tap on a cover, a wait on the series-detail fetch and then a
/// Continue — while the website put the same thing one tap from the tab you
/// land on. The data had been fetched by a provider nothing watched.
///
/// Deliberately a single row and not the website's hero-plus-rail: at 375px a
/// hero pushes the first followed cover below the fold, so the shelf underneath
/// — which is what the tab is for — would start off screen.
///
/// Renders nothing at all when there is no answer: no reading yet, still
/// loading, or the request failed. A resume affordance is a shortcut, and a
/// shortcut that shows a spinner or an error above the content you asked for is
/// worse than no shortcut. The shelf below never depends on this.
class ContinueReadingStrip extends ConsumerWidget {
  const ContinueReadingStrip({super.key, required this.gutter});

  /// The page gutter, passed in rather than assumed, so the heading above and
  /// the shelf below line up with this row exactly — the same arrangement
  /// `NovelShelf` is given, for the same reason.
  final double gutter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(contentModeScopeProvider);
    // Scoped like every other list on this screen: in Novels mode the Library
    // tab is a shelf of books, so a half-read manhwa chapter does not belong on
    // top of it.
    final items = scope.filter(
      ref.watch(continueReadingProvider).valueOrNull ?? const <ContinueReadingItem>[],
      (item) => item.sourceId,
    );
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: gutter),
          child: Text(
            'Continue reading',
            style: context.text.labelLg.copyWith(color: context.colors.muted),
          ),
        ),
        SizedBox(height: context.space.sm),
        SizedBox(
          height: _cardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: gutter),
            itemCount: items.length,
            separatorBuilder: (_, __) => SizedBox(width: context.space.sm),
            itemBuilder: (context, i) => _ContinueCard(
              item: items[i],
              isNovel: scope.modeOf(items[i].sourceId) == ContentMode.novel,
            ),
          ),
        ),
        SizedBox(height: context.space.lg),
      ],
    );
  }
}

const double _cardHeight = 74;
const double _cardWidth = 208;

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.item, required this.isNovel});

  final ContinueReadingItem item;

  /// Which reader this row opens. The row carries a source id and no kind, so
  /// the kind comes from the source-mode index — the same resolution reading
  /// history and the downloads list make.
  final bool isNovel;

  @override
  Widget build(BuildContext context) {
    final label = chapterLabel(number: item.chapterNumber, title: null);

    return SizedBox(
      width: _cardWidth,
      child: GlassCard(
        padding: EdgeInsets.all(context.space.sm),
        // No page or position on the link, matching every other screen that
        // opens a chapter here. Both readers restore their own position, and
        // the two units are not interchangeable: a novel's `last_page` is a
        // progress BUCKET (1-100), so handing it to the page reader as a page
        // would open the wrong place with total confidence.
        onTap: () => context.push(
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
        child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label.primary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelLg,
                ),
                SizedBox(height: context.space.xs),
                Text(
                  // A novel's stored position is a percentage of the chapter,
                  // not a page count, so "Page 7/0" would be nonsense there.
                  isNovel
                      ? '${(item.progressPct * 100).round()}% through'
                      : item.pageCount > 0
                          ? 'Page ${item.lastPage} of ${item.pageCount}'
                          : 'Page ${item.lastPage}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.caption
                      .copyWith(color: context.colors.muted),
                ),
                SizedBox(height: context.space.xs),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: item.progressPct.clamp(0.0, 1.0),
                    minHeight: 3,
                    backgroundColor: context.colors.muted.withValues(alpha: 0.2),
                    valueColor:
                        AlwaysStoppedAnimation<Color>(context.colors.primary),
                  ),
                ),
              ],
        ),
      ),
    );
  }
}
