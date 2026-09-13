import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/features/library/models/library_statistics.dart';
import 'package:manhwamaniacs/features/library/utils/cover_url.dart';
import 'package:manhwamaniacs/features/library/utils/reading_time_format.dart';
import 'package:manhwamaniacs/features/library/utils/series_display.dart';
import 'package:manhwamaniacs/features/library/widgets/statistics/activity_bars.dart';
import 'package:manhwamaniacs/features/sources/utils/chapter_label.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/widgets/glass_card.dart';
import 'package:manhwamaniacs/shared/widgets/premium/primary_pill_button.dart';
import 'package:manhwamaniacs/shared/widgets/section_header.dart';
import 'package:manhwamaniacs/shared/widgets/series_cover_image.dart';
import 'package:manhwamaniacs/shared/widgets/stat_card.dart';

/// The sections of the statistics screen.
///
/// Split out of the screen so the screen file stays the composition and the
/// async states, the way the library widgets under `widgets/library/` are. Every
/// section renders only what the payload can back up: a profile that last read
/// months ago still has all-time totals and recent sessions but an empty
/// window, and each section decides for itself whether it has anything to say.

/// The honest empty state for a profile with no recorded reading.
///
/// Zeroes here would be a lie of omission — they read as "you have read
/// nothing" when the truth is "nothing has been recorded yet", so this says
/// where the numbers come from and points at the one action that starts them.
class NoReadingHistoryCard extends StatelessWidget {
  const NoReadingHistoryCard({super.key, required this.followedTotal});

  final int followedTotal;

  @override
  Widget build(BuildContext context) {
    final hasLibrary = followedTotal > 0;

    return GlassCard(
      glowColor: context.colors.primary,
      padding: EdgeInsets.all(context.space.xl2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(context.radii.md),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      context.colors.primary.withAlpha(60),
                      context.colors.primary.withAlpha(20),
                    ],
                  ),
                  border: Border.all(color: context.colors.primary.withAlpha(50)),
                ),
                child: Icon(
                  Icons.insights_outlined,
                  size: 20,
                  color: context.colors.violet400,
                ),
              ),
              SizedBox(width: context.space.lg),
              Expanded(
                child: Text('No reading recorded yet', style: context.text.h3),
              ),
            ],
          ),
          SizedBox(height: context.space.lg),
          Text(
            'Streaks, daily activity and time spent are built from chapters you '
            'read in the app. Open one and the first day fills in as soon as you '
            'turn a page — nothing is counted retroactively.',
            style: context.text.body.copyWith(
              color: context.colors.muted,
              height: 1.6,
            ),
          ),
          SizedBox(height: context.space.xl2),
          PrimaryPillButton(
            label: hasLibrary ? 'Continue Reading' : 'Browse Sources',
            expanded: true,
            icon: hasLibrary ? Icons.play_arrow_rounded : Icons.explore_outlined,
            onPressed: () => context.go(hasLibrary ? Routes.library : Routes.sources),
          ),
        ],
      ),
    );
  }
}

/// Current streak, longest streak, and which of the last seven days were read.
class StreakCard extends StatelessWidget {
  const StreakCard({super.key, required this.stats});

  final LibraryStatistics stats;

  @override
  Widget build(BuildContext context) {
    final streak = stats.streak;
    final alive = streak.currentDays > 0;
    // The last seven buckets of a dense window — never fewer, because the
    // backend pads days with no reading rather than dropping them.
    final week = stats.daily.length <= 7
        ? stats.daily
        : stats.daily.sublist(stats.daily.length - 7);

    return GlassCard(
      glowColor: alive ? context.colors.primary : null,
      padding: EdgeInsets.all(context.space.xl2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          alive
                              ? Icons.local_fire_department_rounded
                              : Icons.local_fire_department_outlined,
                          size: 22,
                          color: alive ? context.colors.primary : context.colors.muted,
                        ),
                        SizedBox(width: context.space.sm),
                        Text(
                          '${streak.currentDays}',
                          style: context.text.h1.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        SizedBox(width: context.space.xs),
                        Padding(
                          padding: EdgeInsets.only(top: context.space.sm),
                          child: Text(
                            streak.currentDays == 1 ? 'day' : 'days',
                            style: context.text.body.copyWith(color: context.colors.muted),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.space.xxs),
                    Text(
                      alive
                          ? 'Current streak'
                          : 'Read today to start a new streak',
                      style: context.text.caption.copyWith(color: context.colors.muted),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${streak.longestDays}',
                    style: context.text.h3.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: context.colors.violet400,
                    ),
                  ),
                  Text('Longest', style: context.text.caption.copyWith(color: context.colors.muted)),
                ],
              ),
            ],
          ),
          if (week.isNotEmpty) ...[
            SizedBox(height: context.space.xl),
            Row(
              children: [
                for (final day in week)
                  Expanded(child: _StreakDay(day: day)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StreakDay extends StatelessWidget {
  const _StreakDay({required this.day});

  final DailyActivity day;

  @override
  Widget build(BuildContext context) {
    final read = day.sessions > 0;
    return Column(
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: read ? context.colors.primary.withAlpha(45) : context.colors.fg.withAlpha(12),
            border: Border.all(
              color: read ? context.colors.primary.withAlpha(120) : context.colors.border,
            ),
          ),
          child: read
              ? Icon(Icons.check, size: 14, color: context.colors.violet400)
              : null,
        ),
        SizedBox(height: context.space.xs),
        Text(
          DateFormat.E().format(day.date).substring(0, 1),
          style: context.text.caption.copyWith(
            color: read ? context.colors.fg : context.colors.muted,
          ),
        ),
      ],
    );
  }
}

/// Per-day activity over the window, as a chart you can interrogate.
///
/// Bars carry pages where pages were recorded and fall back to session count
/// otherwise — a chart that plots a metric the client never reported is a flat
/// line that looks like a bug rather than like a quiet month.
class ActivityCard extends StatefulWidget {
  const ActivityCard({super.key, required this.stats});

  final LibraryStatistics stats;

  @override
  State<ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<ActivityCard> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final days = widget.stats.daily;
    final usePages = days.any((d) => d.pagesRead > 0);
    final values = [for (final d in days) usePages ? d.pagesRead : d.sessions];
    final total = values.fold<int>(0, (sum, v) => sum + v);
    // A refresh can shorten the window; a stale index would read off the end.
    final selected =
        (_selected != null && _selected! < days.length) ? _selected : null;

    return GlassCard(
      padding: EdgeInsets.all(context.space.xl2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Activity', style: context.text.h4)),
              _RangePill(label: 'Last ${widget.stats.rangeDays} days'),
            ],
          ),
          SizedBox(height: context.space.xs),
          Text(
            selected != null
                ? _dayReadout(days[selected], usePages)
                : total > 0
                    ? '${usePages ? formatPages(total) : '$total sessions'} in the '
                        'last ${widget.stats.rangeDays} days'
                    : 'Nothing read in the last ${widget.stats.rangeDays} days',
            style: context.text.body.copyWith(
              color: selected != null ? context.colors.fg : context.colors.muted,
            ),
          ),
          SizedBox(height: context.space.xl),
          ActivityBars(
            values: values,
            height: 96,
            selectedIndex: selected,
            onSelect: (index) => setState(() => _selected = index),
            semanticsLabel: usePages
                ? 'Pages read per day over the last ${widget.stats.rangeDays} days'
                : 'Reading sessions per day over the last '
                    '${widget.stats.rangeDays} days',
          ),
          if (days.isNotEmpty) ...[
            SizedBox(height: context.space.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatShortDay(days.first.date), style: context.text.caption.copyWith(color: context.colors.muted)),
                Text(formatShortDay(days.last.date), style: context.text.caption.copyWith(color: context.colors.muted)),
              ],
            ),
          ],
          if (total > 0) ...[
            SizedBox(height: context.space.lg),
            Text('Tap a bar for that day.', style: context.text.caption.copyWith(color: context.colors.muted)),
          ],
        ],
      ),
    );
  }

  String _dayReadout(DailyActivity day, bool usePages) {
    final parts = <String>[
      DateFormat.MMMEd().format(day.date),
      if (usePages) formatPages(day.pagesRead) else '${day.sessions} sessions',
      if (day.chaptersRead > 0) formatChapters(day.chaptersRead),
      if (day.secondsRead > 0) formatReadingDuration(day.secondsRead),
    ];
    return parts.join('  ·  ');
  }
}

/// Which hours of the day this profile reads in.
class ReadingClockCard extends StatelessWidget {
  const ReadingClockCard({super.key, required this.byHour});

  final List<HourActivity> byHour;

  @override
  Widget build(BuildContext context) {
    final usePages = byHour.any((h) => h.pagesRead > 0);
    final values = [for (final h in byHour) usePages ? h.pagesRead : h.sessions];
    final peak = _peakHour();

    return GlassCard(
      padding: EdgeInsets.all(context.space.xl2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Reading Clock', style: context.text.h4),
          SizedBox(height: context.space.xs),
          Text(
            peak != null
                ? 'You read most around ${formatHourOfDay(peak)}.'
                : 'When you read, hour by hour.',
            style: context.text.body.copyWith(color: context.colors.muted),
          ),
          SizedBox(height: context.space.xl),
          ActivityBars(
            values: values,
            height: 72,
            semanticsLabel: 'Reading by hour of the day',
          ),
          SizedBox(height: context.space.sm),
          Row(
            children: [
              for (final hour in const [0, 6, 12, 18])
                Expanded(
                  child: Text(formatHourOfDay(hour), style: context.text.caption.copyWith(color: context.colors.muted)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  int? _peakHour() {
    HourActivity? best;
    for (final hour in byHour) {
      if (hour.sessions == 0) continue;
      if (best == null || hour.pagesRead > best.pagesRead) best = hour;
    }
    return best?.hour;
  }
}

/// Where the reading came from, as a share of the window's pages.
class SourceBreakdownCard extends StatelessWidget {
  const SourceBreakdownCard({super.key, required this.sources});

  final List<SourceActivity> sources;

  @override
  Widget build(BuildContext context) {
    final usePages = sources.any((s) => s.pagesRead > 0);
    int weight(SourceActivity s) => usePages ? s.pagesRead : s.sessions;
    final max = sources.fold<int>(0, (m, s) => math.max(m, weight(s)));

    return GlassCard(
      padding: EdgeInsets.all(context.space.xl2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sources', style: context.text.h4),
          SizedBox(height: context.space.lg),
          for (var i = 0; i < sources.length; i++)
            Padding(
              padding: EdgeInsets.only(
                bottom: i == sources.length - 1 ? 0 : context.space.lg,
              ),
              child: _SourceRow(
                source: sources[i],
                // Rank shades one accent rather than handing every source its
                // own hue: the palette is deliberately warm and narrow, and a
                // rainbow here would read as categorical meaning that is not
                // there.
                color: context.colors.primary.withAlpha(math.max(90, 255 - i * 28)),
                fraction: max > 0 ? weight(sources[i]) / max : 0,
                label: usePages
                    ? formatPages(sources[i].pagesRead)
                    : '${sources[i].sessions} sessions',
              ),
            ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.color,
    required this.fraction,
    required this.label,
  });

  final SourceActivity source;
  final Color color;
  final double fraction;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            SizedBox(width: context.space.sm),
            Expanded(
              child: Text(
                source.name,
                style: context.text.labelLg,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(label, style: context.text.caption.copyWith(color: context.colors.muted)),
          ],
        ),
        SizedBox(height: context.space.sm),
        _ProportionBar(fraction: fraction, color: color),
      ],
    );
  }
}

/// A rounded track with a proportional fill — the shared bar behind the source
/// and reading-status breakdowns.
class _ProportionBar extends StatelessWidget {
  const _ProportionBar({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(context.radii.full),
      child: Container(
        height: 6,
        color: context.colors.fg.withAlpha(16),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          // A source with a single page still deserves a visible sliver.
          widthFactor: fraction.clamp(0.02, 1.0),
          child: DecoratedBox(decoration: BoxDecoration(color: color)),
        ),
      ),
    );
  }
}

/// The series this profile actually read in the window, heaviest first.
class TopSeriesSection extends ConsumerWidget {
  const TopSeriesSection({super.key, required this.series});

  final List<SeriesActivity> series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baseUrl = ref.watch(apiBaseUrlProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(icon: Icons.workspace_premium_outlined, title: 'Most Read'),
        for (final item in series)
          Padding(
            padding: EdgeInsets.only(bottom: context.space.md),
            child: _SeriesRow(
              series: item,
              coverUrl: sourceSeriesCoverUrl(baseUrl, item.sourceId, item.seriesKey),
            ),
          ),
      ],
    );
  }
}

class _SeriesRow extends StatelessWidget {
  const _SeriesRow({required this.series, required this.coverUrl});

  final SeriesActivity series;
  final String coverUrl;

  @override
  Widget build(BuildContext context) {
    final subtitle = <String>[
      if (series.pagesRead > 0) formatPages(series.pagesRead),
      if (series.chaptersRead > 0) formatChapters(series.chaptersRead),
      if (series.secondsRead > 0) formatReadingDuration(series.secondsRead),
    ].join('  ·  ');

    return GlassCard(
      // The follow row's id is not in this payload, so the series opens by its
      // opaque `(source, series)` identity — the same route search and
      // collections use.
      onTap: () => context.push(
        RoutePaths.sourceSeriesDetail(series.sourceId, series.seriesKey),
      ),
      padding: EdgeInsets.all(context.space.lg),
      child: Row(
        children: [
          SeriesCoverImage(url: coverUrl, width: 44, height: 60),
          SizedBox(width: context.space.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // A series unfollowed since it was read keeps its history but
                  // loses its title; the source is the only honest label left.
                  (series.title?.isNotEmpty ?? false) ? series.title! : series.sourceId,
                  style: context.text.labelLg,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: context.space.xxs),
                Text(subtitle, style: context.text.caption.copyWith(color: context.colors.muted)),
                if (series.lastReadAt != null) ...[
                  SizedBox(height: context.space.xxs),
                  Text(
                    formatTimeAgo(series.lastReadAt!),
                    style: context.text.caption.copyWith(color: context.colors.muted),
                  ),
                ],
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: context.colors.muted),
        ],
      ),
    );
  }
}

/// The last few sessions, all-time — deliberately not windowed, so this never
/// goes blank on someone who last read a fortnight ago.
class RecentSessionsSection extends StatelessWidget {
  const RecentSessionsSection({super.key, required this.sessions});

  final List<RecentSession> sessions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(icon: Icons.history, title: 'Recent Sessions'),
        GlassCard(
          padding: EdgeInsets.symmetric(vertical: context.space.xs),
          child: Column(
            children: [
              for (var i = 0; i < sessions.length; i++) ...[
                if (i > 0)
                  Divider(height: 1, thickness: 1, color: context.colors.border),
                _SessionRow(session: sessions[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session});

  final RecentSession session;

  @override
  Widget build(BuildContext context) {
    final label = chapterLabel(number: session.chapterNumber, title: session.title);
    final meta = <String>[
      if (session.pagesRead > 0) formatPages(session.pagesRead),
      if (session.secondsRead > 0) formatReadingDuration(session.secondsRead),
      if (session.startedAt != null) formatTimeAgo(session.startedAt!),
    ].join('  ·  ');

    return InkWell(
      onTap: () => context.push(
        RoutePaths.reader(session.sourceId, session.seriesKey, session.chapterKey),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.space.lg,
          vertical: context.space.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label.secondary ?? label.primary,
                    style: context.text.labelLg,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: context.space.xxs),
                  Text(
                    label.secondary != null ? '${label.primary}  ·  $meta' : meta,
                    style: context.text.caption.copyWith(color: context.colors.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: context.colors.muted),
          ],
        ),
      ),
    );
  }
}

/// The shape of the library itself — the four counts that never depended on
/// session recording, and are honest for a profile that has never read a page.
class LibraryShapeGrid extends StatelessWidget {
  const LibraryShapeGrid({super.key, required this.stats});

  final LibraryStatistics stats;

  @override
  Widget build(BuildContext context) {
    final number = NumberFormat.decimalPattern();

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: context.space.md,
      crossAxisSpacing: context.space.md,
      childAspectRatio: 1.45,
      children: [
        StatCard(
          icon: Icons.menu_book_outlined,
          value: number.format(stats.followedTotal),
          label: 'Followed Series',
          accent: StatAccent.amber,
        ),
        StatCard(
          icon: Icons.star_outline,
          value: number.format(stats.favorites),
          label: 'Favorites',
          accent: StatAccent.amber,
        ),
        StatCard(
          icon: Icons.check_circle_outline,
          value: number.format(stats.byReadingStatus['completed'] ?? 0),
          label: 'Completed',
          accent: StatAccent.emerald,
        ),
        StatCard(
          icon: Icons.auto_stories_outlined,
          value: number.format(stats.chaptersCompleted),
          // Not "chapters read": this counts chapters *finished*, including
          // ones finished before sessions were recorded. All-time chapters
          // read is its own card in the totals grid, and the two differing is
          // the truth, not a bug.
          label: 'Chapters Finished',
          accent: StatAccent.emerald,
        ),
      ],
    );
  }
}

/// All-time reading totals.
///
/// The fourth card is time read only when the client reported elapsed time;
/// otherwise it is the session count, because a permanent "0m" reads as a
/// broken screen rather than as a metric this device does not report.
class ReadingTotalsGrid extends StatelessWidget {
  const ReadingTotalsGrid({super.key, required this.totals});

  final ReadingTotals totals;

  @override
  Widget build(BuildContext context) {
    final number = NumberFormat.decimalPattern();

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: context.space.md,
      crossAxisSpacing: context.space.md,
      childAspectRatio: 1.45,
      children: [
        StatCard(
          icon: Icons.auto_stories_outlined,
          value: number.format(totals.chaptersRead),
          label: 'Chapters Read',
          accent: StatAccent.amber,
        ),
        StatCard(
          icon: Icons.description_outlined,
          value: number.format(totals.pagesRead),
          label: 'Pages Read',
          accent: StatAccent.amber,
        ),
        StatCard(
          icon: Icons.collections_bookmark_outlined,
          value: number.format(totals.seriesRead),
          label: 'Series Read',
          accent: StatAccent.emerald,
        ),
        if (totals.secondsRead > 0)
          StatCard(
            icon: Icons.schedule_outlined,
            value: formatReadingDuration(totals.secondsRead),
            label: 'Time Read',
            accent: StatAccent.emerald,
          )
        else
          StatCard(
            icon: Icons.play_circle_outline,
            value: number.format(totals.sessions),
            label: 'Sessions',
            accent: StatAccent.emerald,
          ),
      ],
    );
  }
}

/// The followed set broken down by reading status.
class ReadingStatusCard extends StatelessWidget {
  const ReadingStatusCard({super.key, required this.byReadingStatus});

  final Map<String, int> byReadingStatus;

  @override
  Widget build(BuildContext context) {
    final entries = byReadingStatus.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<int>(0, (sum, e) => sum + e.value);

    return GlassCard(
      padding: EdgeInsets.all(context.space.xl2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('By Reading Status', style: context.text.h4),
          SizedBox(height: context.space.lg),
          for (var i = 0; i < entries.length; i++)
            Padding(
              padding: EdgeInsets.only(
                bottom: i == entries.length - 1 ? 0 : context.space.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _statusLabel(entries[i].key),
                          style: context.text.labelLg,
                        ),
                      ),
                      Text('${entries[i].value}', style: context.text.caption.copyWith(color: context.colors.muted)),
                    ],
                  ),
                  SizedBox(height: context.space.sm),
                  _ProportionBar(
                    fraction: total > 0 ? entries[i].value / total : 0,
                    color: readingStatusColor(context, entries[i].key),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// `readingStatusLabel` un-snakes the key; a breakdown row reads as a label,
  /// so the words are capitalised here rather than shouted in the shared util.
  static String _statusLabel(String status) => readingStatusLabel(status)
      .split(' ')
      .map((word) => word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}

class _RangePill extends StatelessWidget {
  const _RangePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.space.md,
        vertical: context.space.xs,
      ),
      decoration: BoxDecoration(
        color: context.colors.fg.withAlpha(10),
        borderRadius: BorderRadius.circular(context.radii.full),
        border: Border.all(color: context.colors.border),
      ),
      child: Text(
        label.toUpperCase(),
        style: context.text.caption.copyWith(
          color: context.colors.muted,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
