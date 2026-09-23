import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_selection.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/series_download_status_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
import 'package:manhwamaniacs/features/downloads/widgets/chapter_download_action.dart';
import 'package:manhwamaniacs/features/downloads/widgets/chapter_selection_actions.dart';
import 'package:manhwamaniacs/features/downloads/widgets/download_series_button.dart';
import 'package:manhwamaniacs/features/downloads/widgets/series_download_progress.dart';
import 'package:manhwamaniacs/features/library/utils/resume_location.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_series_detail_view.dart';
import 'package:manhwamaniacs/features/reader/widgets/read_all_button.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';
import 'package:manhwamaniacs/features/sources/providers/sources_provider.dart';
import 'package:manhwamaniacs/features/sources/utils/chapter_date.dart';
import 'package:manhwamaniacs/features/sources/utils/chapter_label.dart';
import 'package:manhwamaniacs/features/updates/widgets/series_follow_button.dart';
import 'package:manhwamaniacs/shared/widgets/empty_state.dart';
import 'package:manhwamaniacs/shared/widgets/premium/primary_pill_button.dart';
import 'package:manhwamaniacs/shared/widgets/series_cover_image.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_chapter_sort.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_chapter_tile.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_detail_body.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_detail_chips.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_detail_meta.dart';

class SourceSeriesDetailScreen extends ConsumerWidget {
  const SourceSeriesDetailScreen({
    super.key,
    required this.sourceId,
    required this.seriesId,
  });

  final String sourceId;
  final String seriesId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(
      sourceSeriesDetailProvider((sourceId: sourceId, seriesId: seriesId)),
    );
    // Name the screen after the series the user tapped, not the generic route.
    final title = detailAsync.valueOrNull?.series.title;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go(RoutePaths.sourceBrowse(sourceId)),
        ),
        title: Text(
          title == null || title.isEmpty ? 'Series' : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error is AppError ? error.userMessage : 'Failed to load series.',
                style: context.text.body.copyWith(color: context.colors.danger),
              ),
              SizedBox(height: context.space.lg),
              FilledButton(
                onPressed: () => ref.invalidate(
                  sourceSeriesDetailProvider((sourceId: sourceId, seriesId: seriesId)),
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        // Prose gets its own screen, not this one with a different font: a
        // novel's identity is its title and its length, not its cover, so the
        // two pages are built the opposite way up. Which one to render is a
        // property of the SOURCE, not of the reader's current mode — opening a
        // novel from a manga-mode search result must still open the book page.
        data: (data) =>
            ref.watch(contentModeScopeProvider).modeOf(sourceId) ==
                    ContentMode.novel
                ? NovelSeriesDetailView(
                    sourceId: sourceId,
                    seriesId: seriesId,
                    series: data.series,
                    chapters: data.chapters,
                  )
                : _SeriesDetailBody(
                    sourceId: sourceId,
                    seriesId: seriesId,
                    series: data.series,
                    chapters: data.chapters,
                  ),
      ),
    );
  }
}

class _SeriesDetailBody extends ConsumerStatefulWidget {
  const _SeriesDetailBody({
    required this.sourceId,
    required this.seriesId,
    required this.series,
    required this.chapters,
  });

  final String sourceId;
  final String seriesId;
  final SourceSeriesSummary series;
  final List<SourceChapterSummary> chapters;

  @override
  ConsumerState<_SeriesDetailBody> createState() => _SeriesDetailBodyState();
}

class _SeriesDetailBodyState extends ConsumerState<_SeriesDetailBody> {
  SeriesChapterSortOrder _sortOrder = SeriesChapterSortOrder.newest;

  /// The chapter list the two orderings below were built from — the memo key,
  /// compared by identity because the detail payload hands out the same list
  /// until it is refetched.
  List<SourceChapterSummary> _sortedFrom = const [];
  List<SourceChapterSummary> _newestFirst = const [];
  List<SourceChapterSummary> _oldestFirst = const [];

  /// Multi-select state for this visit to this page (spec R4). Owned here,
  /// disposed here — leaving the series must forget the selection.
  final _selection = ChapterSelectionController();

  @override
  void initState() {
    super.initState();
    // The rows carry the checkboxes but the range helpers live in the action
    // bar, so a "Next 10" tap has to repaint the list too.
    _selection.addListener(_onSelectionChanged);
  }

  @override
  void dispose() {
    _selection
      ..removeListener(_onSelectionChanged)
      ..dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  /// Rebuilds both chapter orderings, but only when the chapters changed.
  ///
  /// One build needs newest-first (the header's "Latest:" line), oldest-first
  /// (the read CTA's next-chapter walk, and the order the multi-select ranges
  /// are defined against) and whichever of the two the sort toggle is showing.
  /// Deriving those in `build` meant four allocate-index-sort-rebuild passes
  /// over the whole chapter list on every rebuild.
  void _ensureSorted() {
    if (identical(_sortedFrom, widget.chapters)) return;
    _sortedFrom = widget.chapters;
    _newestFirst = sortSeriesChapters(
      _sortedFrom,
      numberOf: (chapter) => chapter.number,
      order: SeriesChapterSortOrder.newest,
    );
    _oldestFirst = sortSeriesChapters(
      _sortedFrom,
      numberOf: (chapter) => chapter.number,
      order: SeriesChapterSortOrder.oldest,
    );
  }

  /// Newest chapter, for the header meta line. Prefers the highest-numbered
  /// chapter in the loaded list and falls back to the source-provided
  /// `latest_chapter` string. Null only when neither is available.
  String? _latestChapterLabel() {
    // The loaded list wins over the source's summary field. Connectors scrape
    // `latest_chapter` from a listing page that can lag the chapter list by
    // days, so preferring it let the header read "Latest: Ch. 118" directly
    // above a newest-first list whose top row was Chapter 120 -- the one number
    // on this screen that has to be right.
    final newest = _newestFirst.firstOrNull;
    if (newest != null) {
      return chapterLabel(number: newest.number, title: newest.title).primary;
    }
    final provided = widget.series.latestChapter?.trim();
    if (provided != null && provided.isNotEmpty) return provided;
    return null;
  }

  /// This series' domain identity — what every downloads provider is keyed
  /// by. On this screen the route parameters already *are* that identity.
  SeriesIdentity get _identity =>
      (sourceId: widget.sourceId, seriesKey: widget.seriesId);

  @override
  Widget build(BuildContext context) {
    _ensureSorted();
    final series = widget.series;
    final chapters = widget.chapters;
    // This phone's records and the server's, merged — the novel reader and
    // the web save only to the server.
    final progressMap = ref.watch(
      sourceSeriesProgressProvider(
        (sourceId: widget.sourceId, seriesId: widget.seriesId),
      ),
    );
    // Watched once for the whole page rather than per row: one store query
    // and one queue subscription drive every chapter's download state.
    final downloadStatuses = ref
        .watch(seriesChapterDownloadStatusProvider(_identity))
        .valueOrNull;
    final activeProgress =
        ref.watch(seriesActiveChapterProgressProvider(_identity));
    final hasScope = ref.watch(activeDownloadsScopeIdProvider) != null;
    final sortedChapters = _sortOrder == SeriesChapterSortOrder.newest
        ? _newestFirst
        : _oldestFirst;
    // The one Continue rule — see [seriesContinue].
    final continueTo =
        seriesContinue(chapters: chapters, progress: progressMap);

    return SeriesDetailBody(
      cover: series.coverUrl.isEmpty
          ? null
          : SeriesCoverImage(
              url: series.coverUrl,
              displayWidth: SeriesDetailBody.coverWidthFor(context),
              borderRadius: 0,
            ),
      title: series.title,
      author: series.author,
      artist: series.artist,
      metaLine: seriesDetailMetaLine(
        latestChapterLabel: _latestChapterLabel(),
        // The loaded chapter list is authoritative; the summary count is only a
        // fallback for sources that omit chapters from the detail payload.
        chapterCount:
            chapters.isNotEmpty ? chapters.length : series.chapterCount,
      ),
      description: series.description,
      primaryAction: continueTo == null
          ? null
          : _ReadPrimaryButton(
              sourceId: widget.sourceId,
              seriesId: widget.seriesId,
              continueTo: continueTo,
              orderedChapters: _oldestFirst,
            ),
      followAction: SeriesFollowButton(
        key: const Key('follow-toggle'),
        sourceId: widget.sourceId,
        seriesKey: widget.seriesId,
      ),
      secondaryActions: [
        ChapterSelectionActions(
          controller: _selection,
          identity: _identity,
          chaptersInReadingOrder: _selectableChapters(
            downloadStatuses: downloadStatuses,
            progressMap: progressMap,
          ),
          seriesTitle: series.title,
          kind: DownloadKind.manga,
        ),
        DownloadSeriesButton(
          chapters: [
            for (final chapter in chapters)
              (
                id: (
                  sourceId: widget.sourceId,
                  seriesKey: widget.seriesId,
                  chapterKey: chapter.id,
                ),
                chapterNumber: chapter.number,
                title: chapter.title,
                seriesTitle: series.title,
                // This body only ever renders for a manga source — the novel
                // branch above took the other path.
                kind: DownloadKind.manga,
              ),
          ],
        ),
      ],
      details: [
        if (hasScope)
          SeriesDownloadProgress(
            identity: _identity,
            totalChapters: chapters.length,
          ),
        // Status and genres get the same pill treatment the library page gives
        // reading status and tags -- the source page simply had nowhere to put
        // them before.
        if ((series.status != null && series.status!.isNotEmpty) ||
            series.genres.isNotEmpty)
          SeriesDetailChipRow(
            chips: [
              if (series.status != null && series.status!.isNotEmpty)
                SeriesDetailChip(
                  label: series.status!.toUpperCase(),
                  color: context.colors.primary,
                ),
              for (final genre in series.genres) SeriesDetailChip(label: genre),
            ],
          ),
      ],
      sortOrder: _sortOrder,
      onSortOrderChanged: (order) => setState(() => _sortOrder = order),
      emptyChapters: const EmptyState(
        icon: Icons.menu_book_outlined,
        message: 'No chapters available',
        subtitle: 'This source did not return any chapters for this series.',
      ),
      chapterTiles: [
        for (final chapter in sortedChapters)
          _buildChapterTile(
            chapter: chapter,
            progressMap: progressMap,
            continueTo: continueTo,
            hasScope: hasScope,
            status: downloadStatuses?[chapter.id],
            downloadProgress: activeProgress?.chapterKey == chapter.id
                ? activeProgress?.progress
                : null,
          ),
      ],
    );
  }

  /// The chapter list as the multi-select ranges see it, oldest first — the
  /// order "next 10" is defined against, independent of the Newest/Oldest
  /// toggle driving what is on screen.
  List<SelectableChapter> _selectableChapters({
    required Map<String, ChapterDownloadStatus>? downloadStatuses,
    required Map<String, SourceChapterProgress> progressMap,
  }) {
    return [
      for (final chapter in _oldestFirst)
        (
          key: chapter.id,
          number: chapter.number,
          title: chapter.title,
          isRead: progressMap[chapter.id]?.completed ?? false,
          isDownloaded: downloadStatuses?[chapter.id]?.state ==
              DownloadChapterState.complete,
        ),
    ];
  }

  Widget _buildChapterTile({
    required SourceChapterSummary chapter,
    required Map<String, SourceChapterProgress> progressMap,
    required SeriesContinue? continueTo,
    required bool hasScope,
    required ChapterDownloadStatus? status,
    required ChapterDownloadProgress? downloadProgress,
  }) {
    final progress = progressMap[chapter.id];
    final completed = progress?.completed ?? false;
    // Prefer the page count captured while reading (authoritative for this
    // reader), falling back to the source-provided count.
    final storedCount = progress?.pageCount ?? 0;
    final effectiveCount = storedCount > 0 ? storedCount : chapter.pageCount;

    return SeriesChapterTile(
      key: Key('chapter-${chapter.id}'),
      label: chapterLabel(number: chapter.number, title: chapter.title),
      uploadedLabel: chapterDateLabel(chapter.releaseDate),
      progressText: seriesChapterProgressText(
        pageCount: effectiveCount,
        page: progress?.page,
        completed: completed,
      ),
      inProgress: progress != null && !completed,
      isRead: completed,
      // "Reading" marks the chapter Continue would resume -- the furthest one
      // opened, and only while it is unfinished.
      isCurrent: continueTo?.point?.chapterKey == chapter.id &&
          progress != null &&
          !completed,
      // While selecting, a row tap ticks the box instead of opening the
      // chapter: nothing else would explain what the checkbox is for.
      onTap: _selection.isActive
          ? () => _selection.toggle(chapter.id)
          : () => context.go(
                RoutePaths.sourceReader(
                  widget.sourceId,
                  widget.seriesId,
                  chapter.id,
                ),
              ),
      selection: _selection.isActive
          ? SeriesChapterSelection(
              selected: _selection.isSelected(chapter.id),
              checkboxKey: Key('select-${chapter.id}'),
              onChanged: (_) => _selection.toggle(chapter.id),
            )
          : null,
      download: chapterDownloadAction(
        hasScope: hasScope,
        status: status,
        progress: downloadProgress,
        buttonKey: Key('download-${chapter.id}'),
        onDownload: () => ref.read(downloadQueueControllerProvider.notifier).enqueueChapter(
              id: (
                sourceId: widget.sourceId,
                seriesKey: widget.seriesId,
                chapterKey: chapter.id,
              ),
              chapterNumber: chapter.number,
              title: chapter.title,
              seriesTitle: widget.series.title,
            ),
      ),
    );
  }
}

/// Primary read CTA. "Continue" when there is progress — resuming the
/// chapter the reader got furthest in at its saved page while it is still in
/// progress, or advancing to the next chapter at page 1 once that chapter is
/// finished — otherwise "Read Online" from the earliest chapter at page 1.
/// "All caught up", and inert, when the last chapter is read.
class _ReadPrimaryButton extends StatelessWidget {
  const _ReadPrimaryButton({
    required this.sourceId,
    required this.seriesId,
    required this.continueTo,
    required this.orderedChapters,
  });

  final String sourceId;
  final String seriesId;
  final SeriesContinue continueTo;

  /// Chapters in reading order (nulls-last ascending) — same comparator used
  /// for the earliest-chapter / auto-queue-next logic. Never empty (the button
  /// is only shown when the series has chapters).
  final List<SourceChapterSummary> orderedChapters;

  @override
  Widget build(BuildContext context) {
    final point = continueTo.point;
    final isStart = continueTo.kind == SeriesContinueKind.start;

    return Row(
      children: [
        Expanded(
          child: PrimaryPillButton(
            key: const Key('read-primary'),
            expanded: true,
            // Caught up: everything to the last chapter is read, and
            // Continue's answer — the book's page — is this page.
            onPressed: point == null
                ? null
                : () => context.go(
                      resumeLocation(
                        sourceId: sourceId,
                        seriesKey: seriesId,
                        point: point,
                        isNovel: false,
                      ),
                    ),
            icon: isStart
                ? Icons.menu_book_outlined
                : point == null
                    ? Icons.done_all_rounded
                    : Icons.play_arrow_rounded,
            label: isStart
                ? 'Read Online'
                : point == null
                    ? 'All caught up'
                    : 'Continue',
          ),
        ),
        SizedBox(width: context.space.sm),
        // Read-all starts where reading would start — resuming into the middle
        // of a series is still one continuous scroll, so the same target.
        ReadAllButton(
          onPressed: () => context.go(
            '${RoutePaths.sourceReadAll(sourceId, seriesId, _readAllStartId())}'
            '${_readAllPageSuffix()}',
          ),
        ),
      ],
    );
  }

  /// Where a Read-all session opens: the chapter Continue would open, or the
  /// first chapter when nothing is left to continue into. The mode is about
  /// how the series is presented, not about starting over.
  String _readAllStartId() =>
      continueTo.point?.chapterKey ?? orderedChapters.first.id;

  String _readAllPageSuffix() {
    final page = continueTo.point?.page ?? 1;
    return page > 1 ? '&page=$page' : '';
  }
}
