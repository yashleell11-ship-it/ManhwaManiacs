import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_selection.dart';
import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/series_download_status_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
import 'package:manhwamaniacs/features/downloads/widgets/chapter_download_action.dart';
import 'package:manhwamaniacs/features/downloads/widgets/download_series_button.dart';
import 'package:manhwamaniacs/features/novels/models/novel_typography.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_series_providers.dart';
import 'package:manhwamaniacs/features/novels/providers/series_audio_provider.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_book.dart';
import 'package:manhwamaniacs/features/novels/widgets/audiobook_picker_sheet.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';
import 'package:manhwamaniacs/features/updates/widgets/series_follow_button.dart';
import 'package:manhwamaniacs/shared/widgets/premium/primary_pill_button.dart';
import 'package:manhwamaniacs/shared/widgets/series_cover_image.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_chapter_sort.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_chapter_tile.dart';

/// A book's front matter and its Contents.
///
/// Deliberately not the manga series screen with a different font. The manga
/// screen is poster-led: a full-bleed cover carries the identity and the
/// metadata is a caption under it. Novels have weak cover art — an
/// aggregator's generated placeholder more often than not — and strong
/// metadata, so this inverts it: the title is the largest thing on the page,
/// set in the serif that carries the whole mode, with the byline under it and
/// the cover kept small and subordinate beside them. When there IS real art it
/// still aids recognition, which is why it is kept rather than dropped.
///
/// The chapter list is a **table of contents**, not a download queue: the
/// number sits in its own column and the title beside it, once (see
/// [tocEntry]), and the second line is length — words and an estimated reading
/// time — because a novel chapter has no page count worth showing.
class NovelSeriesDetailView extends ConsumerStatefulWidget {
  const NovelSeriesDetailView({
    super.key,
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
  ConsumerState<NovelSeriesDetailView> createState() =>
      _NovelSeriesDetailViewState();
}

class _NovelSeriesDetailViewState extends ConsumerState<NovelSeriesDetailView> {
  SeriesChapterSortOrder _sortOrder = SeriesChapterSortOrder.oldest;

  @override
  Widget build(BuildContext context) {
    final series = widget.series;
    final colors = context.colors;
    final identity = (sourceId: widget.sourceId, seriesKey: widget.seriesId);
    final progressMap = ref.watch(sourceProgressProvider);
    final hasScope = ref.watch(activeDownloadsScopeIdProvider) != null;
    final downloadStatuses =
        ref.watch(seriesChapterDownloadStatusProvider(identity)).valueOrNull;
    final wordCounts =
        ref.watch(novelSeriesWordCountsProvider(identity)).valueOrNull ??
            const <String, int>{};

    final ordered = sortSeriesChapters(
      widget.chapters,
      numberOf: (chapter) => chapter.number,
      order: _sortOrder,
    );
    final estimate = estimateSeriesLength(
      widget.chapters.isNotEmpty ? widget.chapters.length : series.chapterCount,
      wordCounts.values,
    );

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _FrontMatter(
            series: series,
            sourceId: widget.sourceId,
            seriesId: widget.seriesId,
            chapterCount: widget.chapters.isNotEmpty
                ? widget.chapters.length
                : series.chapterCount,
            estimate: estimate,
            chapters: widget.chapters,
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            context.space.lg,
            context.space.xl,
            context.space.lg,
            context.space.sm,
          ),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Text(
                  'CONTENTS',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                    color: colors.muted,
                  ),
                ),
                const Spacer(),
                SeriesChapterSortToggle(
                  value: _sortOrder,
                  onChanged: (order) => setState(() => _sortOrder = order),
                ),
              ],
            ),
          ),
        ),
        if (ordered.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(context.space.xl),
              child: Center(
                child: Text(
                  'This source did not return any chapters for this book.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.muted),
                ),
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: ordered.length,
            itemBuilder: (context, index) {
              final chapter = ordered[index];
              return _TocRow(
                chapter: chapter,
                wordCount: wordCounts[chapter.id],
                progress: progressMap[sourceProgressKey(
                  sourceId: widget.sourceId,
                  seriesId: widget.seriesId,
                  chapterId: chapter.id,
                )],
                hasScope: hasScope,
                status: downloadStatuses?[chapter.id],
                onOpen: () => context.push(
                  RoutePaths.novelReader(
                    widget.sourceId,
                    widget.seriesId,
                    chapter.id,
                  ),
                ),
                identity: (
                  sourceId: widget.sourceId,
                  seriesKey: widget.seriesId,
                  chapterKey: chapter.id,
                ),
                seriesTitle: series.title,
              );
            },
          ),
        SliverToBoxAdapter(
          child: SizedBox(
            height: context.space.xl5 + MediaQuery.paddingOf(context).bottom,
          ),
        ),
      ],
    );
  }
}

class _FrontMatter extends ConsumerWidget {
  const _FrontMatter({
    required this.series,
    required this.sourceId,
    required this.seriesId,
    required this.chapterCount,
    required this.estimate,
    required this.chapters,
  });

  final SourceSeriesSummary series;
  final String sourceId;
  final String seriesId;
  final int chapterCount;
  final SeriesLengthEstimate estimate;
  final List<SourceChapterSummary> chapters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    const serif = kNovelSerifStack;
    final meta = [
      byline(series.author),
      formatChapterCount(chapterCount),
      formatStatus(series.status),
    ].whereType<String>().join('  ·  ');
    final blurb = shelfBlurb(series.description);
    final genres = shelfGenres(series.genres);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.lg,
        context.space.lg,
        context.space.lg,
        0,
      ),
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
                    Text(
                      series.title,
                      style: TextStyle(
                        fontFamily: serif.first,
                        fontFamilyFallback: serif.sublist(1),
                        fontSize: 27,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        color: colors.fg,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      SizedBox(height: context.space.sm),
                      Text(
                        meta,
                        style: TextStyle(fontSize: 13, color: colors.muted),
                      ),
                    ],
                  ],
                ),
              ),
              // Small and subordinate — present when the art is real, never
              // the thing the page is built around.
              if (series.coverUrl.isNotEmpty) ...[
                SizedBox(width: context.space.lg),
                ClipRRect(
                  borderRadius: BorderRadius.circular(context.radii.md),
                  child: SizedBox(
                    width: 76,
                    height: 112,
                    child: SeriesCoverImage(
                      url: series.coverUrl,
                      displayWidth: 76,
                      borderRadius: 0,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_lengthLine() != null) ...[
            SizedBox(height: context.space.md),
            Text(
              _lengthLine()!,
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
          ],
          SizedBox(height: context.space.lg),
          if (chapters.isNotEmpty) ...[
            _ReadButton(
              sourceId: sourceId,
              seriesId: seriesId,
              chapters: chapters,
            ),
            SizedBox(height: context.space.sm),
          ],
          Row(
            children: [
              Expanded(
                child: SeriesFollowButton(
                  key: const Key('follow-toggle'),
                  sourceId: sourceId,
                  seriesKey: seriesId,
                ),
              ),
              SizedBox(width: context.space.sm),
              DownloadSeriesButton(
                // The whole book, fetched in server-sized windows rather than
                // one request per chapter — see
                // `DownloadQueueController._primeNovelWindow`.
                label: 'Download book',
                chapters: [
                  for (final chapter in chapters)
                    (
                      id: (
                        sourceId: sourceId,
                        seriesKey: seriesId,
                        chapterKey: chapter.id,
                      ),
                      chapterNumber: chapter.number,
                      title: chapter.title,
                      seriesTitle: series.title,
                      // Prose, so the queue fetches /novels/chapter and stores
                      // one small text blob instead of a page loop.
                      kind: DownloadKind.novel,
                    ),
                ],
              ),
            ],
          ),
          SizedBox(height: context.space.sm),
          // Narration is a REQUEST, not a download: it costs about nine
          // minutes on the render PC per chapter, so it is its own deliberate
          // control rather than a checkbox on "Download book".
          AudiobookButton(
            sourceId: sourceId,
            seriesKey: seriesId,
            chapters: [
              for (final chapter in chapters)
                (
                  key: chapter.id,
                  number: chapter.number,
                  title: chapter.title,
                  isRead: false,
                  isDownloaded: false,
                ),
            ],
          ),
          if (blurb != null) ...[
            SizedBox(height: context.space.lg),
            Text(
              blurb,
              style: TextStyle(
                fontFamily: serif.first,
                fontFamilyFallback: serif.sublist(1),
                fontSize: 15,
                height: 1.6,
                color: colors.fg,
              ),
            ),
          ],
          if (genres.isNotEmpty) ...[
            SizedBox(height: context.space.lg),
            Wrap(
              spacing: context.space.xs,
              runSpacing: context.space.xs,
              children: [
                for (final genre in genres)
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.space.sm,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(context.radii.sm),
                      border: Border.all(color: colors.border),
                    ),
                    child: Text(
                      genre,
                      style: TextStyle(fontSize: 11, color: colors.muted),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// "≈ 1.1M words · ≈ 73 h — estimated from 5 chapters", or nothing.
  ///
  /// Never presented as a count: the qualifier is part of the line, not a
  /// footnote, because the number is a projection from whatever chapters the
  /// phone happens to hold.
  String? _lengthLine() {
    final words = formatEstimatedWords(estimate);
    final time = formatEstimatedTotal(estimate);
    if (words == null || time == null) return null;
    final from = estimate.sampleSize == 1
        ? '1 chapter'
        : '${estimate.sampleSize} chapters';
    return '$words  ·  $time    estimated from $from';
  }
}

/// "Start reading" / "Continue" — the one control a book page needs above
/// everything else.
///
/// The resume rule is the manga screen's, unchanged: a finished chapter
/// advances to the next unread one at the top, an unfinished one reopens at
/// the stored position. The only difference is what the stored position means
/// — a paragraph bucket rather than a page — and since both ride `?page=`,
/// this needs no arithmetic of its own.
class _ReadButton extends ConsumerWidget {
  const _ReadButton({
    required this.sourceId,
    required this.seriesId,
    required this.chapters,
  });

  final String sourceId;
  final String seriesId;
  final List<SourceChapterSummary> chapters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched, not read: finishing a chapter in the reader and coming back
    // must flip this from "Continue" to the next chapter without a refresh.
    ref.watch(sourceProgressProvider);
    final resume = ref.read(sourceProgressProvider.notifier).latestForSeries(
          sourceId: sourceId,
          seriesId: seriesId,
        );
    final ordered = sortSeriesChapters(
      chapters,
      numberOf: (chapter) => chapter.number,
      order: SeriesChapterSortOrder.oldest,
    );

    String target;
    if (resume != null) {
      final index = ordered.indexWhere((c) => c.id == resume.chapterId);
      final next = resume.progress.completed &&
              index != -1 &&
              index + 1 < ordered.length
          ? ordered[index + 1]
          : null;
      if (next != null) {
        target = RoutePaths.novelReader(sourceId, seriesId, next.id);
      } else {
        target = '${RoutePaths.novelReader(sourceId, seriesId, resume.chapterId)}'
            '?page=${resume.progress.page}';
      }
    } else {
      target = RoutePaths.novelReader(sourceId, seriesId, ordered.first.id);
    }

    return PrimaryPillButton(
      key: const Key('read-primary'),
      expanded: true,
      onPressed: () => context.push(target),
      icon: resume != null
          ? Icons.play_arrow_rounded
          : Icons.menu_book_outlined,
      label: resume != null ? 'Continue' : 'Start reading',
    );
  }
}

class _TocRow extends ConsumerWidget {
  const _TocRow({
    required this.chapter,
    required this.wordCount,
    required this.progress,
    required this.hasScope,
    required this.status,
    required this.onOpen,
    required this.identity,
    required this.seriesTitle,
  });

  final SourceChapterSummary chapter;
  final int? wordCount;
  final SourceChapterProgress? progress;
  final bool hasScope;
  final ChapterDownloadStatus? status;
  final VoidCallback onOpen;
  final ({String sourceId, String seriesKey, String chapterKey}) identity;
  final String seriesTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final entry = tocEntry(number: chapter.number, title: chapter.title);
    final read = progress?.completed ?? false;
    const serif = kNovelSerifStack;

    // Words and minutes when the phone actually has the chapter; otherwise
    // nothing, rather than a guess. A novel chapter's page count is always 0.
    final length = formatChapterLength(wordCount);

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.space.lg,
          vertical: context.space.sm + 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 40,
              child: Text(
                entry.ordinal ?? '·',
                style: TextStyle(
                  fontFamily: serif.first,
                  fontFamilyFallback: serif.sublist(1),
                  fontSize: 16,
                  color: read ? colors.muted : colors.fg,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (entry.title != null)
                    Text(
                      entry.title!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: serif.first,
                        fontFamilyFallback: serif.sublist(1),
                        fontSize: 15,
                        height: 1.35,
                        color: read ? colors.muted : colors.fg,
                      ),
                    ),
                  if (length != null || progress != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        [
                          if (length != null) length,
                          if (read)
                            'Read'
                          else if (progress != null)
                            '${progress!.page}% in',
                        ].join('  ·  '),
                        style: TextStyle(fontSize: 11, color: colors.muted),
                      ),
                    ),
                ],
              ),
            ),
            // The same control the manga rows use, decided by the same
            // mapping — a novel chapter is queued, retried and finished
            // exactly like any other row in the store.
            if (chapterDownloadAction(
                  hasScope: hasScope,
                  status: status,
                  buttonKey: Key('download-${chapter.id}'),
                  onDownload: () => ref
                      .read(downloadQueueControllerProvider.notifier)
                      .enqueueChapter(
                        id: identity,
                        chapterNumber: chapter.number,
                        title: chapter.title,
                        seriesTitle: seriesTitle,
                        kind: DownloadKind.novel,
                      ),
                ) case final action?)
              SeriesChapterDownloadControl(download: action),
          ],
        ),
      ),
    );
  }
}


/// "Make audiobook" — opens the chapter picker.
///
/// Its own widget so the coverage lookup happens here rather than in the
/// page: the answer marks which chapters are already narrated, and a page
/// that awaited it would wait on a request that usually says "none" before
/// showing a table of contents.
class AudiobookButton extends ConsumerWidget {
  const AudiobookButton({
    super.key,
    required this.sourceId,
    required this.seriesKey,
    required this.chapters,
  });

  final String sourceId;
  final String seriesKey;
  final List<SelectableChapter> chapters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (sourceId: sourceId, seriesKey: seriesKey);
    final audio = ref.watch(seriesAudioProvider(key)).valueOrNull;
    final rendered = audio?.rendered ?? const <String>{};
    final narratable = audio?.narratable ?? const <String>{};
    // Until the server has answered, assume it can: the button is then
    // briefly enabled rather than briefly claiming narration is unavailable.
    final canRender = audio?.canRender ?? true;
    final jobs = ref.watch(novelAudioJobsProvider(key)).valueOrNull ?? const [];
    final running = jobs.where((job) => job.isRunning).length;
    final waiting = jobs.where((job) => job.isWaiting).length;

    final button = SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        // No render worker: a request would queue and never run, so it is not
        // offered at all rather than accepted and left "in progress" forever.
        onPressed: !canRender
            ? null
            : () => AudiobookPickerSheet.show(
                context,
                sourceId: sourceId,
                seriesKey: seriesKey,
                chapters: [
                  for (final chapter in chapters)
                    (
                      key: chapter.key,
                      number: chapter.number,
                      title: chapter.title,
                      isRead: chapter.isRead,
                      // "Downloaded" means "already has audio" on this sheet.
                      isDownloaded: rendered.contains(chapter.key),
                    ),
                ],
                // Only chapters whose text is on the server can be narrated.
                // The picker shows the rest greyed with the reason rather
                // than letting them be chosen and then refused.
                cached: narratable,
              ),
        icon: const Icon(Icons.graphic_eq_rounded, size: 18),
        label: Text(
          audiobookButtonLabel(
            canRender: canRender,
            running: running,
            waiting: waiting,
            rendered: rendered.length,
          ),
        ),
      ),
    );
    if (canRender) return button;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        button,
        Padding(
          padding: EdgeInsets.only(top: context.space.xxs),
          child: Text(
            kNarrationUnavailable,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Said plainly wherever a request for narration would otherwise be offered,
/// when the server has no render worker to run one.
const String kNarrationUnavailable =
    'Narration of new chapters is not available right now.';

/// The audiobook button's words.
///
/// "In progress" only for a job a render box is actually working on. A job
/// that is merely queued is WAITING — with no worker free it can sit there a
/// long time — and with no worker configured at all there is no job to talk
/// about, because nothing will ever move.
String audiobookButtonLabel({
  required bool canRender,
  required int running,
  required int waiting,
  required int rendered,
}) {
  if (canRender && running > 0) {
    return waiting > 0
        ? 'Making audiobook · $running in progress, $waiting waiting'
        : 'Making audiobook · $running in progress';
  }
  if (canRender && waiting > 0) {
    return 'Make audiobook · $waiting waiting for the narration PC';
  }
  return rendered == 0 ? 'Make audiobook' : 'Make audiobook · $rendered done';
}
