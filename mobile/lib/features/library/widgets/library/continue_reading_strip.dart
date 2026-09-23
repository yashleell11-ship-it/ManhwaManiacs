import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/core/network/api_image.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/library/utils/cover_url.dart';
import 'package:manhwamaniacs/features/library/utils/resume_location.dart';
import 'package:manhwamaniacs/features/library/utils/series_identity.dart';
import 'package:manhwamaniacs/features/sources/utils/chapter_label.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/widgets/glass_card.dart';
import 'package:manhwamaniacs/shared/widgets/series_cover_image.dart';

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
///
/// Each card leads with the SERIES: "Chapter 94, page 3" alone does not say
/// which of a dozen series it resumes. The title is the payload's own where
/// the server sends one, else the follow's from [followed].
class ContinueReadingStrip extends ConsumerWidget {
  const ContinueReadingStrip({
    super.key,
    required this.gutter,
    this.followed = const [],
  });

  /// The page gutter, passed in rather than assumed, so the heading above and
  /// the shelf below line up with this row exactly — the same arrangement
  /// `NovelShelf` is given, for the same reason.
  final double gutter;

  /// The followed list the screen already holds, to name a row by when the
  /// payload carries no title (a server older than the field) and to give it
  /// a cover. Passed in, not fetched: the Library tab has just loaded every
  /// follow, and a second request to learn one string per row is waste.
  final List<FollowedSeries> followed;

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

    final baseUrl = ref.watch(apiBaseUrlProvider);
    final follows = ContinueFollowLookup(followed);

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
            itemBuilder: (context, i) {
              final item = items[i];
              final follow = follows.find(item);
              return _ContinueCard(
                item: item,
                isNovel: scope.modeOf(item.sourceId) == ContentMode.novel,
                title: continueRowTitle(item, follow),
                coverUrl: continueRowCoverUrl(baseUrl, item, follow),
              );
            },
          ),
        ),
        SizedBox(height: context.space.lg),
      ],
    );
  }
}

/// Which follow a continue row resumes: the one under the row's own key,
/// else — on Asura, which rotates its slug suffixes — the one naming the same
/// series under another suffix. The reader stores progress under the key it
/// was opened with, and Browse opens this week's key while the follow keeps
/// the one it was made under.
class ContinueFollowLookup {
  ContinueFollowLookup(Iterable<FollowedSeries> followed) {
    for (final series in followed) {
      _byKey.putIfAbsent(
        _pair(series.sourceId, series.seriesKey),
        () => series,
      );
      _byIdentity.putIfAbsent(
        _pair(series.sourceId, followIdentity(series)),
        () => series,
      );
    }
  }

  final Map<(String, String), FollowedSeries> _byKey = {};
  final Map<(String, String), FollowedSeries> _byIdentity = {};

  static (String, String) _pair(String sourceId, String key) => (sourceId, key);

  /// The follow [item] belongs to, or null when none does.
  FollowedSeries? find(ContinueReadingItem item) =>
      _byKey[_pair(item.sourceId, item.seriesKey)] ??
      _byIdentity[_pair(
        item.sourceId,
        seriesIdentityOf(item.sourceId, item.seriesKey),
      )];
}

/// The card's first line: the payload's title, else the follow's, else null
/// (the card then leads with the chapter, as it always did).
String? continueRowTitle(ContinueReadingItem item, FollowedSeries? follow) {
  final fromPayload = item.title;
  if (fromPayload != null && fromPayload.isNotEmpty) return fromPayload;
  final fromFollow = follow?.title.trim();
  return fromFollow == null || fromFollow.isEmpty ? null : fromFollow;
}

/// The card's art, absolute: the payload's cover, else the follow's, else
/// null — a text-only card, rather than a broken-image box.
String? continueRowCoverUrl(
  String apiBaseUrl,
  ContinueReadingItem item,
  FollowedSeries? follow,
) {
  final fromPayload = item.coverUrl;
  if (fromPayload != null && fromPayload.isNotEmpty) {
    return resolveApiResourceUrl(apiBaseUrl, fromPayload);
  }
  return follow == null ? null : followedSeriesCoverUrl(apiBaseUrl, follow);
}

const double _cardHeight = 74;

/// Wider than the text-only card it replaced: a cover and a title now share
/// the row, and a title cut to four letters names nothing.
const double _cardWidth = 232;

/// A 2:3 cover about the height of the card's content.
const double _coverWidth = 40;

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({
    required this.item,
    required this.isNovel,
    required this.title,
    required this.coverUrl,
  });

  final ContinueReadingItem item;

  /// Which reader this row opens. The row carries a source id and no kind, so
  /// the kind comes from the source-mode index — the same resolution reading
  /// history and the downloads list make.
  final bool isNovel;

  /// The series' title, or null when neither the payload nor a follow names
  /// it.
  final String? title;

  /// Absolute cover URL, or null for a text-only card.
  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    final chapter =
        chapterLabel(number: item.chapterNumber, title: null).primary;
    // A novel's stored position is a percentage of the chapter, not a page
    // count, so "Page 7/0" would be nonsense there.
    final position = isNovel
        ? '${(item.progressPct * 100).round()}% through'
        : item.pageCount > 0
            ? 'Page ${item.lastPage} of ${item.pageCount}'
            : 'Page ${item.lastPage}';
    final heading = title;
    // With the title on top the chapter moves down beside the position, and
    // is left out for a row with no number, where all it could say is
    // "Chapter".
    final primary = heading ?? chapter;
    final secondary = heading == null || item.chapterNumber == null
        ? position
        : '$chapter · $position';
    final cover = coverUrl;

    return SizedBox(
      width: _cardWidth,
      child: GlassCard(
        padding: EdgeInsets.all(context.space.sm),
        // The stored position rides `?page=`, by the rule history's Continue
        // shares (`resume_location.dart`). This used to leave it off on the
        // belief that both readers restore their own position; neither does
        // from the server — the novel reader opened a 60%-read chapter at the
        // top, and the page reader only remembers an offset saved on this
        // device. Each route reads `?page=` in the unit its reader saved it
        // in (a page, or a novel's progress BUCKET), and this link only ever
        // carries a row back to the reader kind that wrote it, so the units
        // never cross. A finished chapter is already moved on to the next one
        // by the server (`continue_reading`), arriving here as page 1.
        onTap: () => context.push(
          resumeLocation(
            sourceId: item.sourceId,
            seriesKey: item.seriesKey,
            point: resumePointFor(
              chapterKey: item.chapterKey,
              lastPage: item.lastPage,
              isCompleted: false,
            )!,
            isNovel: isNovel,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (cover != null) ...[
              SizedBox(
                width: _coverWidth,
                child: SeriesCoverImage(
                  url: cover,
                  displayWidth: _coverWidth,
                  borderRadius: context.radii.sm,
                ),
              ),
              SizedBox(width: context.space.sm),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    primary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.labelLg,
                  ),
                  SizedBox(height: context.space.xs),
                  Text(
                    secondary,
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
                      backgroundColor:
                          context.colors.muted.withValues(alpha: 0.2),
                      valueColor:
                          AlwaysStoppedAnimation<Color>(context.colors.primary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
