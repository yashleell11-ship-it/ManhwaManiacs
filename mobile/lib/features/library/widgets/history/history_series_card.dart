import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/features/library/models/reading_history_item.dart';
import 'package:manhwamaniacs/features/library/utils/cover_url.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/widgets/pressable.dart';
import 'package:manhwamaniacs/shared/widgets/series_cover_image.dart';

/// One recently-read book, as a cover — the same shape the library shelves.
///
/// Deliberately NOT [SeriesCard]. That one takes a `FollowedSeries` and draws
/// a favourite toggle, a remove button and a selection checkbox from it. A
/// history row is a reading position: it knows the book's title and cover and
/// nothing about following, so building a `FollowedSeries` to reuse the card
/// would mean inventing `isFavorite: false` — and then rendering a control
/// that lies about a book the reader may well have favourited.
///
/// What it DOES share is the shape: the same 2:3 cover, the same corner
/// radius, the same two lines under it. The shelf should look like the shelf.
class HistorySeriesCard extends ConsumerWidget {
  const HistorySeriesCard({
    super.key,
    required this.item,
    required this.coverWidth,
    required this.onTap,
    required this.onContinue,
  });

  final ReadingHistoryItem item;

  /// Logical width of one grid tile — only the grid that laid this out knows
  /// how wide the cover will actually be.
  final double coverWidth;

  /// Open the book's page. Matches what a library cover does.
  final VoidCallback onTap;

  /// Back to where the reader stopped — the stored position, or the next
  /// chapter when this one is finished. The reason somebody opens history.
  ///
  /// A Future because a finished chapter has to fetch the chapter list first,
  /// which scrapes upstream and can take seconds. The badge awaits it so it
  /// can show that it is working and ignore a second tap meanwhile.
  final Future<void> Function() onContinue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = item.pageCount > 0
        ? (item.lastPage / item.pageCount).clamp(0.0, 1.0)
        : null;
    // The server hands the cover over as a backend-relative proxy path; the
    // image loader needs a host. See [historyCoverUrl].
    final coverUrl =
        historyCoverUrl(ref.watch(apiBaseUrlProvider), item.coverUrl);

    return Pressable(
      onTap: onTap,
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
                  if (coverUrl != null)
                    SeriesCoverImage(url: coverUrl, width: coverWidth)
                  else
                    ColoredBox(
                      color: context.colors.muted.withValues(alpha: 0.12),
                      child: Icon(
                        Icons.history_rounded,
                        color: context.colors.muted,
                      ),
                    ),
                  // How far through the chapter, along the bottom edge. A
                  // number would compete with the title; a line does not.
                  if (progress != null && !item.isCompleted)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                      ),
                    ),
                  Positioned(
                    right: 4,
                    bottom: 6,
                    child: _ContinueButton(onPressed: onContinue),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.space.sm),
          Text(
            // The server's series cache has a TTL, so a book read months ago
            // may have aged out. Say so rather than leaving the line blank.
            item.seriesTitle ?? 'Unknown book',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.labelLg.copyWith(
              color: item.seriesTitle == null ? context.colors.muted : null,
            ),
          ),
          SizedBox(height: context.space.xxs),
          Text(
            _subtitle(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.caption.copyWith(color: context.colors.muted),
          ),
        ],
      ),
    );
  }

  String _subtitle() {
    final chapter = item.chapterNumber != null
        ? 'Ch. ${_trimZero(item.chapterNumber!)}'
        : 'Chapter';
    final when = item.lastReadAt == null
        ? null
        : relativeReadTime(item.lastReadAt!.toLocal());
    return [
      if (item.isCompleted) '$chapter · done' else chapter,
      if (when != null) when,
    ].join(' · ');
  }

  static String _trimZero(double value) =>
      value == value.roundToDouble() ? value.round().toString() : '$value';
}

/// "2h ago", not "Sep 20, 2026 3:42 PM".
///
/// History answers "where was I", and an absolute timestamp makes the reader
/// do the subtraction. Past a week the date is genuinely more useful than
/// "37 days ago", so it switches.
String relativeReadTime(DateTime when, {DateTime? now}) {
  final gap = (now ?? DateTime.now()).difference(when);
  if (gap.isNegative) return 'just now';
  if (gap.inMinutes < 1) return 'just now';
  if (gap.inMinutes < 60) return '${gap.inMinutes}m ago';
  if (gap.inHours < 24) return '${gap.inHours}h ago';
  if (gap.inDays < 7) return '${gap.inDays}d ago';
  if (gap.inDays < 365) return '${(gap.inDays / 7).floor()}w ago';
  return '${(gap.inDays / 365).floor()}y ago';
}

/// The play badge. Owns its busy state so the card does not have to.
///
/// Continue on a finished chapter waits on a chapter-list request before it
/// knows where to go. With nothing on screen during that wait, the badge looked
/// dead, and a second tap started a second request and pushed a second reader
/// on top of the first.
class _ContinueButton extends StatefulWidget {
  const _ContinueButton({required this.onPressed});

  final Future<void> Function() onPressed;

  @override
  State<_ContinueButton> createState() => _ContinueButtonState();
}

class _ContinueButtonState extends State<_ContinueButton> {
  bool _busy = false;

  Future<void> _press() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onPressed();
    } catch (error, stack) {
      // The handler deals with its own request failures. One that escapes is
      // reported the way the framework reports any error in a gesture, rather
      // than thrown into the zone from a tap callback nobody awaits.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'history shelf',
          context: ErrorDescription('while continuing from the history shelf'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _busy ? null : _press,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(
                  Icons.play_arrow_rounded,
                  size: 18,
                  color: Colors.white,
                ),
        ),
      ),
    );
  }
}
