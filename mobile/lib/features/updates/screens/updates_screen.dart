import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/content_mode/widgets/content_mode_chip.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';
import 'package:manhwamaniacs/shared/widgets/empty_state.dart';
import 'package:manhwamaniacs/shared/widgets/glass_card.dart';
import 'package:manhwamaniacs/shared/widgets/premium/fade_in.dart';
import 'package:manhwamaniacs/shared/widgets/premium/ghost_pill_button.dart';
import 'package:manhwamaniacs/shared/widgets/premium/hero_heading.dart';
import 'package:manhwamaniacs/shared/widgets/premium/primary_pill_button.dart';
import 'package:manhwamaniacs/shared/widgets/skeleton_box.dart';

class UpdatesScreen extends ConsumerWidget {
  const UpdatesScreen({super.key});

  /// Awaits an action that returns an [AppError] on failure and surfaces it as
  /// a SnackBar. Silent on success.
  Future<void> _run(BuildContext context, Future<AppError?> action) async {
    final error = await action;
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.userMessage)),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updatesAsync = ref.watch(updatesProvider);
    final notifier = ref.read(updatesProvider.notifier);

    return Scaffold(
      backgroundColor: context.colors.bg,
      appBar: AppBar(
        backgroundColor: context.colors.bg,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go(Routes.more),
        ),
        title: Text('Updates', style: context.text.h3),
        actions: [
          const ContentModeChip(),
          IconButton(
            tooltip: 'Check now',
            color: context.colors.primary,
            onPressed: () => _run(context, notifier.triggerCheck()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: updatesAsync.when(
        loading: () => const _UpdatesSkeleton(),
        error: (error, _) => _UpdatesError(
          error: error is AppError
              ? error
              : UnknownError(message: error.toString(), cause: error),
          onRetry: notifier.refresh,
        ),
        data: (state) {
          // Notifications and follows both carry a source id and no kind, so
          // both are scoped through the source-mode index.
          final scope = ref.watch(contentModeScopeProvider);
          final notifications =
              scope.filter(state.notifications, (n) => n.sourceId);
          final followed = scope.filter(state.followed, (f) => f.sourceId);
          // A notification carries a chapter title and a source id but not the
          // SERIES title, so the card used to print the bare source ("asurascans")
          // where the name of the thing you follow belongs. The follows are in
          // the same state object; one map turns that into a real line.
          final seriesTitles = {
            for (final f in state.followed) f.id: f.title,
          };
          final unread = notifications.where((n) => !n.isRead).length;
          final gutter = context.space.xl2;
          return RefreshIndicator(
            color: context.colors.primary,
            onRefresh: notifier.refresh,
            // Slivers rather than one ListView of everything: both sections
            // are as long as the server says, and a `ListView(children: [...])`
            // builds every row of both before the first frame.
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(gutter, gutter, gutter, 0),
                  sliver: SliverToBoxAdapter(
                    child: FadeIn(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const HeroHeading(text: 'Updates', fontSize: 40),
                          SizedBox(height: context.space.xs),
                          Text(
                            '$unread unread · ${followed.length} followed '
                            '${scope.isNovel ? 'books' : 'series'}',
                            style: context.text.body
                                .copyWith(color: context.colors.muted),
                          ),
                          SizedBox(height: context.space.xl2),
                          Wrap(
                            spacing: context.space.sm,
                            runSpacing: context.space.sm,
                            children: [
                              PrimaryPillButton(
                                label: 'Check all now',
                                icon: Icons.sync,
                                onPressed: () =>
                                    _run(context, notifier.triggerCheck()),
                              ),
                              if (unread > 0)
                                GhostPillButton(
                                  label: 'Mark all read',
                                  icon: Icons.done_all,
                                  onPressed: () =>
                                      _run(context, notifier.markAllRead()),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    gutter,
                    gutter,
                    context.space.md,
                  ),
                  sliver: const SliverToBoxAdapter(
                    child: _SectionHeader(title: 'Notifications'),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: gutter),
                  sliver: notifications.isEmpty
                      ? const SliverToBoxAdapter(
                          child: EmptyState(
                            icon: Icons.notifications_none,
                            message: 'No update notifications',
                            subtitle:
                                'Follow series to get notified of new chapters.',
                          ),
                        )
                      : SliverList.builder(
                          itemCount: notifications.length,
                          itemBuilder: (context, index) {
                            final notification = notifications[index];
                            return Padding(
                              padding:
                                  EdgeInsets.only(bottom: context.space.md),
                              child: _NotificationCard(
                                notification: notification,
                                seriesTitle:
                                    seriesTitles[notification.followedSeriesId],
                                isNovel: scope.modeOf(notification.sourceId) ==
                                    ContentMode.novel,
                                // Opening the chapter IS reading it, so the
                                // badge clears on the way through rather than
                                // asking for a second, separate tap on a
                                // button most people never press.
                                onOpen: () {
                                  if (!notification.isRead) {
                                    unawaited(
                                      notifier.markRead(notification.id),
                                    );
                                  }
                                },
                                onMarkRead: notification.isRead
                                    ? null
                                    : () => _run(
                                          context,
                                          notifier.markRead(notification.id),
                                        ),
                              ),
                            );
                          },
                        ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    gutter,
                    gutter,
                    context.space.md,
                  ),
                  sliver: const SliverToBoxAdapter(
                    child: _SectionHeader(title: 'Followed series'),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(gutter, 0, gutter, gutter),
                  sliver: followed.isEmpty
                      ? const SliverToBoxAdapter(
                          child: EmptyState(
                            icon: Icons.rss_feed,
                            message: 'No followed series',
                            subtitle:
                                'Follow series from sources to monitor new chapters.',
                          ),
                        )
                      : SliverList.builder(
                          itemCount: followed.length,
                          itemBuilder: (context, index) {
                            final series = followed[index];
                            return Padding(
                              padding:
                                  EdgeInsets.only(bottom: context.space.md),
                              child: _FollowedSeriesCard(
                                series: series,
                                actionPending: state.actionPending,
                                onRemove: () =>
                                    _run(context, notifier.unfollow(series.id)),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 18,
          decoration: BoxDecoration(
            color: context.colors.primary,
            borderRadius: BorderRadius.circular(context.radii.full),
          ),
        ),
        SizedBox(width: context.space.sm),
        Text(title, style: context.text.h3),
      ],
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.notification,
    required this.isNovel,
    this.seriesTitle,
    this.onOpen,
    this.onMarkRead,
  });

  /// One formatter for the whole list. Constructing a [DateFormat] parses the
  /// locale's pattern data, which is not a per-row cost worth paying.
  static final DateFormat _stamp = DateFormat.yMMMd().add_jm();

  final UpdateNotification notification;

  /// The followed series' own name, resolved from the follows in the same
  /// payload. Null when the follow is gone (unfollowed since the notification
  /// was written), in which case the source id is still better than nothing.
  final String? seriesTitle;

  /// Which reader this row opens. The notification carries a source id and no
  /// kind, so the kind comes from the source-mode index — the same resolution
  /// reading history, downloads and continue-reading make. Getting it wrong
  /// opens a novel in the page reader.
  final bool isNovel;

  /// Side effects of opening, run before navigating.
  final VoidCallback? onOpen;

  final VoidCallback? onMarkRead;

  @override
  Widget build(BuildContext context) {
    final date = notification.createdAt != null
        ? _stamp.format(notification.createdAt!.toLocal())
        : null;

    // GlassCard, not GlassPanel: a panel puts a real BackdropFilter behind
    // itself under the glass presets, and a repeating list row would make that
    // one backdrop readback and blur per visible card, per frame. Panels are
    // for the one-per-screen surfaces.
    return GlassCard(
      padding: EdgeInsets.all(context.space.lg),
      // The whole point of the screen: a new chapter you can open. This card
      // used to have no tap target at all, so the only way to reach the chapter
      // it announced was to remember the series and go find it.
      onTap: () {
        onOpen?.call();
        context.push(
          isNovel
              ? RoutePaths.novelReader(
                  notification.sourceId,
                  notification.seriesKey,
                  notification.chapterKey,
                )
              : RoutePaths.reader(
                  notification.sourceId,
                  notification.seriesKey,
                  notification.chapterKey,
                ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  seriesTitle ?? notification.chapterTitle,
                  style: context.text.labelLg,
                ),
              ),
              if (!notification.isRead) const _NewBadge(),
            ],
          ),
          SizedBox(height: context.space.xs),
          Text(
            // With the series named above, this line is now the chapter — the
            // thing the notification is actually about.
            seriesTitle == null
                ? notification.sourceId
                : notification.chapterTitle,
            style: context.text.body.copyWith(color: context.colors.muted),
          ),
          if (date != null) ...[
            SizedBox(height: context.space.xs),
            Text(date, style: context.text.caption.copyWith(color: context.colors.muted)),
          ],
          if (onMarkRead != null) ...[
            SizedBox(height: context.space.md),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onMarkRead,
                style: TextButton.styleFrom(foregroundColor: context.colors.primary),
                child: const Text('Mark read'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NewBadge extends StatelessWidget {
  const _NewBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: context.colors.primary.withValues(alpha: 0.20),
        borderRadius: BorderRadius.circular(context.radii.full),
        border: Border.all(color: context.colors.primary.withValues(alpha: 0.45)),
      ),
      child: Text(
        'NEW',
        style: context.text.caption.copyWith(
          color: context.colors.primary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _FollowedSeriesCard extends StatelessWidget {
  const _FollowedSeriesCard({
    required this.series,
    required this.onRemove,
    this.actionPending = false,
  });

  final FollowedSeries series;
  final VoidCallback onRemove;
  final bool actionPending;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.all(context.space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(series.title, style: context.text.labelLg)),
              _KindBadge(label: series.sourceId),
            ],
          ),
          SizedBox(height: context.space.xs),
          Text(
            // chapterCount is 0 until the first successful update check --
            // follow() creates the row without it -- so a freshly followed
            // series would otherwise be labelled "0 chapters", which reads as
            // "this series has none" rather than "not checked yet".
            series.chapterCount > 0
                ? '${series.chapterCount} chapters'
                : 'Not checked yet',
            style: context.text.body.copyWith(color: context.colors.muted),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: actionPending ? null : onRemove,
                style: TextButton.styleFrom(foregroundColor: context.colors.danger),
                child: const Text('Unfollow'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: context.colors.fg.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(context.radii.full),
        border: Border.all(color: context.colors.border),
      ),
      child: Text(
        label,
        style: context.text.caption.copyWith(color: context.colors.muted),
      ),
    );
  }
}

class _UpdatesSkeleton extends StatelessWidget {
  const _UpdatesSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(context.space.xl2),
      children: [
        const SkeletonBox(width: 200, height: 44),
        SizedBox(height: context.space.xl2),
        const SkeletonBox(width: double.infinity, height: 100),
        SizedBox(height: context.space.md),
        const SkeletonBox(width: double.infinity, height: 100),
      ],
    );
  }
}

class _UpdatesError extends StatelessWidget {
  const _UpdatesError({required this.error, required this.onRetry});

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
              error.userMessage,
              style: context.text.body.copyWith(color: context.colors.muted),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: context.space.xl2),
            PrimaryPillButton(
              label: 'Retry',
              icon: Icons.refresh,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
