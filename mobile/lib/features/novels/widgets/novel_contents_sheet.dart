import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_book.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_chapter_view.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/providers/sources_provider.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_chapter_sort.dart';

/// Every row is this tall, which is what lets the list open at the current
/// chapter by arithmetic ([contentsScrollOffset]) instead of building 3,188
/// rows to find out where one of them is.
const double _kRowExtent = 52;

/// How many matches "Go to chapter" lists before it says how many more.
const int _kMaxMatches = 30;

/// A book's contents as a sheet: the reader's Contents button, and the book
/// page's "Go to chapter".
///
/// One list, two ways in. From the reader it opens at the chapter on screen;
/// from the book page it opens with the number field focused. Typing a number
/// swaps the list for the chapters whose TITLE prints that number
/// ([goToChapterMatches]) — never a key, which for a novel is a row ordinal —
/// each shown with its row, because printed numbers repeat.
///
/// Lazily built with a fixed row height, so Shadow Slave's 3,188 chapters cost
/// the dozen rows on screen. It works only from the chapter list: the book
/// page hands over the one it has, and the reader reads the series page's own
/// provider — the same request the book page makes, already cached when the
/// reader was opened from it.
class NovelContentsSheet extends ConsumerStatefulWidget {
  const NovelContentsSheet({
    super.key,
    required this.sourceId,
    required this.seriesKey,
    required this.onOpen,
    this.chapters,
    this.currentChapterKey,
    this.startWithSearch = false,
    this.surface,
  });

  final String sourceId;
  final String seriesKey;

  /// Open a chapter. The sheet closes itself first.
  final ValueChanged<String> onOpen;

  /// The chapter list, when the caller already holds it; otherwise the
  /// series page's provider supplies it.
  final List<SourceChapterSummary>? chapters;

  /// The chapter on screen — the list opens at it and marks it.
  final String? currentChapterKey;

  /// Focus the number field on open: "Go to chapter" rather than Contents.
  final bool startWithSearch;

  /// The reading palette, from inside the reader; the app theme otherwise.
  final NovelSurfaceColors? surface;

  static Future<void> show(
    BuildContext context, {
    required String sourceId,
    required String seriesKey,
    required ValueChanged<String> onOpen,
    List<SourceChapterSummary>? chapters,
    String? currentChapterKey,
    bool startWithSearch = false,
    NovelSurfaceColors? surface,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface?.bg ?? context.colors.surface,
      isScrollControlled: true,
      useSafeArea: true,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(context.radii.xl)),
      ),
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.85,
        child: NovelContentsSheet(
          sourceId: sourceId,
          seriesKey: seriesKey,
          onOpen: onOpen,
          chapters: chapters,
          currentChapterKey: currentChapterKey,
          startWithSearch: startWithSearch,
          surface: surface,
        ),
      ),
    );
  }

  @override
  ConsumerState<NovelContentsSheet> createState() => _NovelContentsSheetState();
}

class _NovelContentsSheetState extends ConsumerState<NovelContentsSheet> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(String chapterKey) {
    Navigator.of(context).pop();
    widget.onOpen(chapterKey);
  }

  @override
  Widget build(BuildContext context) {
    final surface = widget.surface;
    final ink = surface?.ink ?? context.colors.fg;
    final muted = surface?.muted ?? context.colors.muted;
    final rule = surface?.rule ?? context.colors.border;

    final given = widget.chapters;
    final detail = given == null
        ? ref.watch(
            sourceSeriesDetailProvider(
              (sourceId: widget.sourceId, seriesId: widget.seriesKey),
            ),
          )
        : null;
    final chapters = given ?? detail?.valueOrNull?.chapters;
    final loadFailed = detail?.hasError ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.space.lg,
            context.space.md,
            context.space.lg,
            context.space.sm,
          ),
          child: Row(
            children: [
              Text(
                'CONTENTS',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                  color: muted,
                ),
              ),
              SizedBox(width: context.space.lg),
              Expanded(
                child: TextField(
                  key: const Key('contents-go-to'),
                  controller: _query,
                  autofocus: widget.startWithSearch,
                  textInputAction: TextInputAction.go,
                  style: TextStyle(fontSize: 14, color: ink),
                  cursorColor: ink,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Go to chapter',
                    hintStyle: TextStyle(color: muted),
                    prefixIcon: Icon(Icons.search_rounded, size: 18, color: muted),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(context.radii.md),
                      borderSide: BorderSide(color: rule),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(context.radii.md),
                      borderSide: BorderSide(color: rule),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (text) {
                    final first = chapters == null
                        ? null
                        : goToChapterMatches(chapters, text).firstOrNull;
                    if (first != null) _open(first.id);
                  },
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: rule),
        Expanded(
          child: chapters == null
              ? Center(
                  child: loadFailed
                      ? Text(
                          'The contents need a connection to load.',
                          style: TextStyle(color: muted),
                        )
                      : CircularProgressIndicator(color: muted),
                )
              : _query.text.trim().isEmpty
                  ? _ContentsList(
                      chapters: chapters,
                      currentChapterKey: widget.currentChapterKey,
                      ink: ink,
                      muted: muted,
                      onOpen: _open,
                    )
                  : _Matches(
                      chapters: chapters,
                      query: _query.text,
                      ink: ink,
                      muted: muted,
                      onOpen: _open,
                    ),
        ),
      ],
    );
  }
}

class _ContentsList extends StatefulWidget {
  const _ContentsList({
    required this.chapters,
    required this.currentChapterKey,
    required this.ink,
    required this.muted,
    required this.onOpen,
  });

  final List<SourceChapterSummary> chapters;
  final String? currentChapterKey;
  final Color ink;
  final Color muted;
  final ValueChanged<String> onOpen;

  @override
  State<_ContentsList> createState() => _ContentsListState();
}

class _ContentsListState extends State<_ContentsList> {
  late final List<SourceChapterSummary> _ordered = sortSeriesChapters(
    widget.chapters,
    numberOf: (chapter) => chapter.number,
    order: SeriesChapterSortOrder.oldest,
  );

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: contentsScrollOffset(
      _ordered.indexWhere((chapter) => chapter.id == widget.currentChapterKey),
      _kRowExtent,
    ),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scroll,
      itemExtent: _kRowExtent,
      itemCount: _ordered.length,
      itemBuilder: (context, index) {
        final chapter = _ordered[index];
        return _ChapterLine(
          chapter: chapter,
          current: chapter.id == widget.currentChapterKey,
          ink: widget.ink,
          muted: widget.muted,
          onTap: () => widget.onOpen(chapter.id),
        );
      },
    );
  }
}

class _Matches extends StatelessWidget {
  const _Matches({
    required this.chapters,
    required this.query,
    required this.ink,
    required this.muted,
    required this.onOpen,
  });

  final List<SourceChapterSummary> chapters;
  final String query;
  final Color ink;
  final Color muted;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final wanted = goToChapterQuery(query);
    final matches = goToChapterMatches(chapters, query);
    final message = wanted == null
        ? 'Type a chapter number.'
        : matches.isEmpty
            ? 'No chapter ${formatChapterNumber(wanted)} in this book.'
            : null;
    if (message != null) {
      return Padding(
        padding: EdgeInsets.all(context.space.lg),
        child: Text(message, style: TextStyle(color: muted)),
      );
    }
    final shown = matches.take(_kMaxMatches).toList();
    return ListView(
      children: [
        for (final chapter in shown)
          SizedBox(
            height: _kRowExtent,
            child: _ChapterLine(
              chapter: chapter,
              current: false,
              ink: ink,
              muted: muted,
              onTap: () => onOpen(chapter.id),
            ),
          ),
        if (matches.length > shown.length)
          Padding(
            padding: EdgeInsets.all(context.space.lg),
            child: Text(
              'and ${matches.length - shown.length} more',
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ),
      ],
    );
  }
}

/// One contents line: the row number and the title, on one line so every
/// row is exactly [_kRowExtent] tall. The row number is also what tells two
/// "Go to" matches apart — two chapters can print the same number.
class _ChapterLine extends StatelessWidget {
  const _ChapterLine({
    required this.chapter,
    required this.current,
    required this.ink,
    required this.muted,
    required this.onTap,
  });

  final SourceChapterSummary chapter;
  final bool current;
  final Color ink;
  final Color muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final entry = tocEntry(number: chapter.number, title: chapter.title);
    final title = entry.title ??
        (entry.ordinal != null ? 'Chapter ${entry.ordinal}' : 'Chapter');
    return InkWell(
      key: Key('contents-${chapter.id}'),
      onTap: onTap,
      child: Container(
        color: current ? ink.withValues(alpha: 0.07) : null,
        padding: EdgeInsets.symmetric(horizontal: context.space.lg),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Text(
                entry.ordinal ?? '·',
                style: TextStyle(
                  fontSize: 13,
                  color: muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                  color: ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
