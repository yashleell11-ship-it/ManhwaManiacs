import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/content_mode/widgets/content_mode_chip.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/models/downloaded_series_group.dart';
import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';
import 'package:manhwamaniacs/features/downloads/providers/active_download_queue_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloaded_series_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/widgets/active_downloads_panel.dart';
import 'package:manhwamaniacs/features/downloads/widgets/downloads_storage_card.dart';
import 'package:manhwamaniacs/features/downloads/widgets/export_downloads_action.dart';
import 'package:manhwamaniacs/features/ocr/widgets/ocr_chapter_action.dart';
import 'package:manhwamaniacs/features/ocr/widgets/ocr_run_banner.dart';
import 'package:manhwamaniacs/features/sources/utils/chapter_label.dart';
import 'package:manhwamaniacs/shared/widgets/empty_state.dart';
import 'package:manhwamaniacs/shared/widgets/glass_card.dart';

/// The downloads area: a top-level tab, not a row buried in More.
///
/// It answers three questions the owner asked in this order — *is anything
/// happening?* (the live queue panel), *what is on my phone and what is it
/// costing me?* (the saved list, largest series first), and *where did it
/// go?* (the note below the queue plus Save to Files).
///
/// Two tabs rather than one long scroll: Chapters is the thing you open the
/// area for, Storage is the thing you open it for once a month. Storage holds
/// the very same [DownloadsStorageCard] that Settings → Storage does — the
/// widget is embedded twice, never forked, so the cap, the retention interval
/// and Free up space have exactly one implementation and one set of
/// providers behind them.
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen>
    with SingleTickerProviderStateMixin {
  /// Built in [initState], not lazily: the no-profile branch below never
  /// renders the TabBar, and a `late final` initialiser would then run for
  /// the first time inside [dispose] — where looking up the TickerMode
  /// ancestor is already unsafe.
  late final TabController _tabs;

  /// The per-chapter queue list is collapsed by default: the panel's summary
  /// answers "is it working" on its own, and a 200-chapter queue would bury
  /// the library underneath it.
  var _queueExpanded = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scopeId = ref.watch(activeDownloadsScopeIdProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        // The saved shelf and the queue below are both scoped to the active
        // mode; without this the only way to change it was the Library tab.
        // Absent with no scope for the same reason the TabBar is: there is no
        // list to be in the wrong mode about.
        actions: scopeId == null ? null : const [ContentModeChip()],
        bottom: scopeId == null
            ? null
            : TabBar(
                controller: _tabs,
                labelColor: context.colors.primary,
                unselectedLabelColor: context.colors.muted,
                indicatorColor: context.colors.primary,
                tabs: const [
                  Tab(text: 'Chapters'),
                  Tab(text: 'Storage'),
                ],
              ),
      ),
      body: scopeId == null
          ? const EmptyState(
              icon: Icons.person_outline,
              message: 'No active profile',
              subtitle: 'Choose a reading profile to see its downloads.',
            )
          : TabBarView(
              controller: _tabs,
              children: [
                _ChaptersTab(
                  queueExpanded: _queueExpanded,
                  onToggleQueue: () =>
                      setState(() => _queueExpanded = !_queueExpanded),
                  onOpenStorageSettings: () => _tabs.animateTo(1),
                ),
                const _StorageTab(),
              ],
            ),
    );
  }
}

class _ChaptersTab extends ConsumerWidget {
  const _ChaptersTab({
    required this.queueExpanded,
    required this.onToggleQueue,
    required this.onOpenStorageSettings,
  });

  final bool queueExpanded;
  final VoidCallback onToggleQueue;
  final VoidCallback onOpenStorageSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(contentModeScopeProvider);
    // Already scoped and already ordered — see [downloadedShelfProvider]. The
    // screen only lays it out.
    final shelfAsync = ref.watch(downloadedShelfProvider);
    final queued = chaptersInMode(
      ref.watch(activeDownloadQueueProvider).valueOrNull ??
          const <SavedChapter>[],
      scope,
    );

    // Slivers, not a ListView of everything: both the queue and the saved
    // library are unbounded (a "download series" can be hundreds of
    // chapters), and only slivers keep those rows lazy.
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: OcrRunBanner()),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            context.space.xl2,
            context.space.lg,
            context.space.xl2,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: ActiveDownloadsPanel(
              expanded: queueExpanded,
              onToggleExpanded: onToggleQueue,
              onOpenStorageSettings: onOpenStorageSettings,
            ),
          ),
        ),
        if (queueExpanded && queued.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              context.space.md,
              context.space.sm,
              context.space.md,
              0,
            ),
            sliver: SliverList.builder(
              itemCount: queued.length,
              itemBuilder: (context, index) =>
                  QueuedChapterRow(chapter: queued[index]),
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            context.space.xl2,
            context.space.lg,
            context.space.xl2,
            0,
          ),
          sliver: const SliverToBoxAdapter(child: _WhereItLivesCard()),
        ),
        ...shelfAsync.when(
          loading: () => const [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
          error: (error, _) => [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  'Could not load downloads.',
                  style: context.text.body.copyWith(color: context.colors.danger),
                ),
              ),
            ),
          ],
          data: (groups) => _savedSlivers(context, groups, scope),
        ),
      ],
    );
  }

  /// Lays out the already-scoped, already-ordered [groups].
  List<Widget> _savedSlivers(
    BuildContext context,
    List<DownloadedSeriesGroup> groups,
    ContentModeScope scope,
  ) {
    if (groups.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.download_outlined,
            message: scope.isNovel ? 'No books downloaded' : 'No downloads yet',
            subtitle: scope.isNovel
                ? 'Chapters you download read offline, text and all.'
                : 'Chapters you download for offline reading show up here.',
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          context.space.xl2,
          context.space.xl2,
          context.space.xl2,
          context.space.sm,
        ),
        sliver: SliverToBoxAdapter(
          child: Text(
            'On this phone — biggest first',
            style: context.text.labelSm.copyWith(
              color: context.colors.muted,
              letterSpacing: 1.0,
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          context.space.xl2,
          0,
          context.space.xl2,
          context.space.xl7 + MediaQuery.paddingOf(context).bottom,
        ),
        sliver: SliverList.builder(
          itemCount: groups.length,
          itemBuilder: (context, index) => Padding(
            padding: EdgeInsets.only(bottom: context.space.md),
            child: _SeriesDownloadCard(group: groups[index]),
          ),
        ),
      ),
    ];
  }
}

class _StorageTab extends StatelessWidget {
  const _StorageTab();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        context.space.xl2,
        context.space.xl2,
        context.space.xl2,
        context.space.xl7 + MediaQuery.paddingOf(context).bottom,
      ),
      children: const [DownloadsStorageCard()],
    );
  }
}

/// The plain-sentence answer to "where is it landing on my iPhone".
///
/// Deliberately does **not** point at the blob tree. Page bytes are stored
/// content-addressed under `mm-store/blobs/{hash[0:2]}/{sha256}` — that is
/// what makes cross-profile dedup and refcounted deletion correct — so what
/// a user would actually find by going looking is thousands of extensionless
/// files sharded across 256 folders. Telling them to browse that would be
/// technically true and practically useless, so the honest answer is "they
/// live in the app; here is the button that gives you a readable copy".
class _WhereItLivesCard extends StatelessWidget {
  const _WhereItLivesCard();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colors.fg.withAlpha(13),
        borderRadius: BorderRadius.circular(context.radii.md),
        border: Border.all(color: context.colors.border),
      ),
      child: Padding(
        padding: EdgeInsets.all(context.space.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              color: context.colors.muted,
              size: 18,
            ),
            SizedBox(width: context.space.sm),
            Expanded(
              child: Text(
                'Downloaded chapters are stored inside ManhwaManiacs and read '
                'offline straight from this tab — there is nothing to find in '
                'the Files app. For a copy you can open elsewhere, use Save to '
                'Files on a series or chapter.',
                style: context.text.caption.copyWith(
                  color: context.colors.muted,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeriesDownloadCard extends ConsumerStatefulWidget {
  const _SeriesDownloadCard({required this.group});

  final DownloadedSeriesGroup group;

  @override
  ConsumerState<_SeriesDownloadCard> createState() => _SeriesDownloadCardState();
}

class _SeriesDownloadCardState extends ConsumerState<_SeriesDownloadCard> {
  var _expanded = false;

  String get _seriesLabel =>
      (widget.group.seriesTitle?.isNotEmpty ?? false)
          ? widget.group.seriesTitle!
          : widget.group.seriesKey;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final saved = group.chapters
        .where((c) => c.state == DownloadChapterState.complete)
        .length;

    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: EdgeInsets.all(context.space.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _seriesLabel,
                          style: context.text.labelLg,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: context.space.xxs),
                        Text(
                          _subtitle(saved, group),
                          style: context.text.caption.copyWith(color: context.colors.muted)
                              .copyWith(color: context.colors.muted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: Key('pin-series-${group.sourceId}-${group.seriesKey}'),
                    tooltip: group.pinned ? 'Unpin series' : 'Pin series',
                    icon: Icon(
                      group.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      color: group.pinned ? context.colors.primary : context.colors.muted,
                    ),
                    onPressed: () => _togglePin(group),
                  ),
                  PopupMenuButton<_SeriesAction>(
                    key: Key('series-menu-${group.sourceId}-${group.seriesKey}'),
                    tooltip: 'Series options',
                    color: context.colors.surfaceElevated,
                    icon: Icon(Icons.more_vert, color: context.colors.muted),
                    onSelected: _onSeriesAction,
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _SeriesAction.export,
                        child: Text('Save to Files…'),
                      ),
                      PopupMenuItem(
                        value: _SeriesAction.deleteAll,
                        child: Text('Remove all downloads'),
                      ),
                    ],
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: context.colors.muted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            for (final chapter in group.chapters)
              _ChapterRow(
                chapter: chapter,
                seriesLabel: _seriesLabel,
                onRemoved: () => ref.invalidate(downloadedSeriesProvider),
              ),
          if (_expanded) SizedBox(height: context.space.xs),
        ],
      ),
    );
  }

  String _subtitle(int saved, DownloadedSeriesGroup group) {
    // Narration rows are counted as audio, not as more chapters: a book with
    // ten chapters and their narration is still ten chapters.
    final audio = group.chapters.where((c) => c.kind.isAudio).toList();
    final total = group.chapters.length - audio.length;
    final savedText = saved -
        audio.where((c) => c.state == DownloadChapterState.complete).length;
    final size = formatDownloadBytes(group.totalBytes);
    final withAudio = audio.isEmpty ? '' : ' · ${audio.length} with audio';
    if (savedText == total) {
      return '$total chapter${total == 1 ? '' : 's'}$withAudio · $size';
    }
    return '$savedText of $total chapters saved$withAudio · $size';
  }

  Future<void> _onSeriesAction(_SeriesAction action) async {
    switch (action) {
      case _SeriesAction.export:
        await showDownloadExportSheet(
          context,
          ref,
          seriesLabel: _seriesLabel,
          // A zip of page images; speech has none to give it.
          chapters: [
            for (final chapter in widget.group.chapters)
              if (!chapter.kind.isAudio) chapter,
          ],
        );
      case _SeriesAction.deleteAll:
        await _confirmDeleteAll();
    }
  }

  Future<void> _confirmDeleteAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.colors.surfaceElevated,
        title: Text('Remove downloads?', style: context.text.h4),
        content: Text(
          'Deletes every downloaded chapter of $_seriesLabel from this phone. '
          'Your reading progress is kept, and you can download them again any '
          'time.',
          style: context.text.bodySm.copyWith(color: context.colors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              'Remove',
              style: context.text.label.copyWith(color: context.colors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final store = ref.read(downloadsStoreProvider);
    if (store == null) return;
    for (final chapter in widget.group.chapters) {
      await store.deleteDownload(chapter.identity);
    }
    ref.invalidate(downloadedSeriesProvider);
  }

  Future<void> _togglePin(DownloadedSeriesGroup group) async {
    await ref.read(downloadsStoreProvider)?.setSeriesPinned(
          series: (sourceId: group.sourceId, seriesKey: group.seriesKey),
          pinned: !group.pinned,
        );
    ref.invalidate(downloadedSeriesProvider);
  }
}

enum _SeriesAction { export, deleteAll }

class _ChapterRow extends ConsumerWidget {
  const _ChapterRow({
    required this.chapter,
    required this.seriesLabel,
    required this.onRemoved,
  });

  final SavedChapter chapter;
  final String seriesLabel;
  final VoidCallback onRemoved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = chapterLabel(number: chapter.chapterNumber, title: chapter.title);
    final complete = chapter.state == DownloadChapterState.complete;
    // A saved narration is listed as what it is — the chapter's AUDIO — and
    // opens the chapter it reads, where the player picks up the saved copy.
    final narration = chapter.kind.isAudio;
    final opens = textIdentity(chapter.identity);

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: context.space.md),
      leading: narration
          ? Icon(Icons.headphones_rounded, size: 18, color: context.colors.muted)
          : null,
      title: Text(
        narration ? '${label.primary} · audio' : label.primary,
        style: context.text.bodySm,
      ),
      subtitle: Text(
        '${_stateLabel(chapter.state, chapter.error)} · '
        '${formatDownloadBytes(chapter.bytes)}',
        style: context.text.caption.copyWith(color: context.colors.muted),
      ),
      // The row's own `kind` decides which reader opens — not the sources
      // listing, which is exactly what a downloaded chapter cannot rely on.
      onTap: complete
          ? () => context.push(
                chapter.kind.isNovelSide
                    ? RoutePaths.novelReader(
                        opens.sourceId,
                        opens.seriesKey,
                        opens.chapterKey,
                      )
                    : RoutePaths.reader(
                        chapter.sourceId,
                        chapter.seriesKey,
                        chapter.chapterKey,
                      ),
              )
          : null,
      // `mainAxisSize.min` because a ListTile's trailing slot is unbounded:
      // the OCR action hides itself on a device without an engine, and the
      // row must close up rather than leave a gap where it would have been.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Speech has no page images to recognise.
          if (!narration) OcrChapterAction(chapter: chapter),
          // "Save to Files" writes a CBZ of page images. A novel chapter has
          // one text blob and no pages, and narration is audio, so the export
          // would be a zip of nothing — not offered rather than offered broken.
          if (complete && !chapter.kind.isNovelSide)
            IconButton(
              key: Key(
                'export-${chapter.sourceId}-${chapter.seriesKey}-${chapter.chapterKey}',
              ),
              tooltip: 'Save to Files',
              icon: const Icon(Icons.save_alt, size: 20),
              onPressed: () => showDownloadExportSheet(
                context,
                ref,
                seriesLabel: seriesLabel,
                chapters: [chapter],
              ),
            ),
          IconButton(
            key: Key('remove-${chapter.sourceId}-${chapter.seriesKey}-${chapter.chapterKey}'),
            // For narration, the audio alone: the chapter's text stays.
            tooltip: narration ? 'Remove saved audio' : 'Remove download',
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () => _remove(ref),
          ),
        ],
      ),
    );
  }

  String _stateLabel(DownloadChapterState state, String? error) => switch (state) {
        DownloadChapterState.queued => 'Queued',
        DownloadChapterState.downloading => 'Downloading…',
        DownloadChapterState.complete => 'Downloaded',
        DownloadChapterState.failed => error == null ? 'Failed' : 'Failed — $error',
      };

  Future<void> _remove(WidgetRef ref) async {
    await ref.read(downloadsStoreProvider)?.deleteDownload(
          (
            sourceId: chapter.sourceId,
            seriesKey: chapter.seriesKey,
            chapterKey: chapter.chapterKey,
          ),
        );
    onRemoved();
  }
}
