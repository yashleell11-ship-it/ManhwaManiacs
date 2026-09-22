import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/utils/cover_url.dart';
import 'package:manhwamaniacs/features/library/utils/read_state_label.dart';
import 'package:manhwamaniacs/features/sources/utils/chapter_label.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/widgets/pressable.dart';
import 'package:manhwamaniacs/shared/widgets/series_cover_image.dart';

/// Everything the Library card can say *truthfully* about a followed series
/// without firing a per-series network request.
///
/// [FollowedSeries.chapterCount] is only refreshed by the backend update
/// checker, so a freshly-followed series — or one whose connector is erroring
/// — reports 0 even though the series has hundreds of chapters. Rendering "0
/// chapters" is therefore a lie, and the only way to get a real count on this
/// screen would be one chapter-list request per followed series on every
/// Library open. Instead we surface what the already-loaded updates payload
/// knows: the newest chapter we have ever been notified about, and how many
/// of those notifications are still unread.
class FollowedSeriesMeta {
  const FollowedSeriesMeta({
    required this.unreadCount,
    required this.latestChapterLabel,
  });

  /// Unread new-chapter notifications for this series, counted from the same
  /// notification page the Updates tab renders — so the two always agree.
  final int unreadCount;

  /// Label of the newest chapter we have been notified about ("Chapter 120"),
  /// or null when the series has never produced a notification.
  final String? latestChapterLabel;

  static const FollowedSeriesMeta none =
      FollowedSeriesMeta(unreadCount: 0, latestChapterLabel: null);

  /// `followedSeriesId -> meta` for every series [notifications] mentions.
  ///
  /// Built once per notification list rather than per card. The grid's item
  /// builder runs for every tile entering the cache extent during a scroll, so
  /// deriving one card's meta by scanning the whole list there makes that
  /// builder O(notifications) — and `updatesProvider` fetches an unpaginated
  /// list. Series with no notification are simply absent; the card falls back
  /// to [none].
  static Map<int, FollowedSeriesMeta> indexBySeries(
    List<UpdateNotification> notifications,
  ) {
    final unread = <int, int>{};
    final latest = <int, UpdateNotification>{};
    for (final notification in notifications) {
      final seriesId = notification.followedSeriesId;
      if (seriesId == null) continue;
      if (!notification.isRead) unread[seriesId] = (unread[seriesId] ?? 0) + 1;
      final current = latest[seriesId];
      if (current == null || _isNewer(notification, current)) {
        latest[seriesId] = notification;
      }
    }
    return {
      for (final entry in latest.entries)
        entry.key: FollowedSeriesMeta(
          unreadCount: unread[entry.key] ?? 0,
          latestChapterLabel: chapterLabel(
            number: entry.value.chapterNumber,
            title: entry.value.chapterTitle,
          ).primary,
        ),
    };
  }

  /// Newest-first ordering: chapter number when both sides have one, else the
  /// creation timestamp, else insertion id.
  static bool _isNewer(UpdateNotification a, UpdateNotification b) {
    final an = a.chapterNumber;
    final bn = b.chapterNumber;
    if (an != null && bn != null && an != bn) return an > bn;
    final at = a.createdAt;
    final bt = b.createdAt;
    if (at != null && bt != null && at != bt) return at.isAfter(bt);
    return a.id > b.id;
  }
}

/// The card's one muted line: where the reader is ("Not started", "Ch 5 of
/// 120") when the row carries a read state; else the latest chapter we
/// actually know about, else a chapter count only when the checker has
/// populated one, else nothing at all.
String? followedSeriesCardSubtitle(
  FollowedSeries series,
  FollowedSeriesMeta meta,
) {
  final progress = readStateLabel(series.readState);
  if (progress != null) return progress;
  final latest = meta.latestChapterLabel;
  if (latest != null) return 'Latest: $latest';
  final known = series.chapterCount;
  if (known <= 0) return null;
  return known == 1 ? '1 chapter' : '$known chapters';
}

/// A cover-first Library grid card for one followed series.
///
/// Matches the sources/search cards: cover, title, and a single muted meta
/// line — which is omitted entirely when nothing true is known, rather than
/// claiming "0 chapters".
class FollowedSeriesCard extends ConsumerWidget {
  const FollowedSeriesCard({
    super.key,
    required this.series,
    required this.coverWidth,
    required this.meta,
    required this.onTap,
    this.onLongPress,
  });

  final FollowedSeries series;

  /// Logical width of one grid tile — the card fills its cell, so only the
  /// grid that laid it out knows how wide the cover will actually be.
  final double coverWidth;

  final FollowedSeriesMeta meta;
  final VoidCallback onTap;

  /// Opens the per-series menu (favourite, remove). Null on a surface that
  /// has no menu to open — a multi-select, say — rather than a no-op, so the
  /// press has no haptic to answer with either.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baseUrl = ref.watch(apiBaseUrlProvider);
    final coverUrl = followedSeriesCoverUrl(baseUrl, series);
    final subtitle = followedSeriesCardSubtitle(series, meta);
    final newCount = libraryCardNewCount(
      series.readState,
      unreadNotifications: meta.unreadCount,
    );

    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(context.radii.xl),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (coverUrl == null)
                    ColoredBox(color: context.colors.surface2)
                  else
                    SeriesCoverImage(
                      url: coverUrl,
                      displayWidth: coverWidth,
                      borderRadius: context.radii.xl,
                    ),
                  if (newCount > 0)
                    Positioned(
                      top: context.space.sm,
                      right: context.space.sm,
                      child: _NewBadge(count: newCount),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.space.sm),
          Text(
            series.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.label.copyWith(
              color: context.colors.fg,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (subtitle != null) ...[
            SizedBox(height: context.space.xxs),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.caption.copyWith(color: context.colors.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Warm amber "N NEW" pill: chapters past the furthest one read (or, for a
/// row with no read state, unread new-chapter notifications).
class _NewBadge extends StatelessWidget {
  const _NewBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.space.sm,
        vertical: context.space.xxs,
      ),
      decoration: BoxDecoration(
        color: context.colors.primary,
        borderRadius: BorderRadius.circular(context.radii.pill),
      ),
      child: Text(
        newCountBadgeText(count),
        style: context.text.caption.copyWith(
          color: context.colors.primaryFg,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}
