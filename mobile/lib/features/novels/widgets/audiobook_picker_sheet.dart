import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_selection.dart';
import 'package:manhwamaniacs/features/novels/providers/series_audio_provider.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

/// Choose which chapters to have narrated.
///
/// Reuses the selection machinery the download picker already has — the same
/// controller, the same "next ten" idea — because "pick some chapters" should
/// mean the same thing on this sheet as on that one.
///
/// Two things here are specific to audio, and both are about cost. A chapter
/// is roughly nine minutes on a GPU that is also somebody's games machine, so
/// the count is always in front of the reader and the estimate is stated in
/// minutes rather than hidden. And a chapter whose TEXT is not on the server
/// cannot be narrated at all: it is shown greyed with the reason, rather than
/// being selectable and then silently refused.
class AudiobookPickerSheet extends ConsumerStatefulWidget {
  const AudiobookPickerSheet({
    super.key,
    required this.sourceId,
    required this.seriesKey,
    required this.chapters,
    required this.cached,
  });

  final String sourceId;
  final String seriesKey;

  /// Every chapter in the book, in reading order.
  final List<SelectableChapter> chapters;

  /// Chapter keys whose text is on the server. Only these can be narrated —
  /// rendering reads the chapter, and reading one that is not cached would
  /// make the server scrape the source.
  final Set<String> cached;

  static Future<void> show(
    BuildContext context, {
    required String sourceId,
    required String seriesKey,
    required List<SelectableChapter> chapters,
    required Set<String> cached,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => AudiobookPickerSheet(
        sourceId: sourceId,
        seriesKey: seriesKey,
        chapters: chapters,
        cached: cached,
      ),
    );
  }

  @override
  ConsumerState<AudiobookPickerSheet> createState() =>
      _AudiobookPickerSheetState();
}

/// Measured on this library: ~13 minutes of audio per chapter, rendered at
/// about 0.67× real time on an uncontended card. Stated rather than hidden,
/// because nine minutes of somebody's GPU is a real thing to spend.
const int _minutesPerChapter = 9;

class _AudiobookPickerSheetState extends ConsumerState<AudiobookPickerSheet> {
  final ChapterSelectionController _selection = ChapterSelectionController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _selection.begin();
    _selection.addListener(_onSelectionChanged);
  }

  @override
  void dispose() {
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    super.dispose();
  }

  void _onSelectionChanged() => setState(() {});

  /// The chapters that can actually be narrated: text on the server, and no
  /// audio yet.
  List<SelectableChapter> get _eligible => [
    for (final chapter in widget.chapters)
      if (widget.cached.contains(chapter.key) && !chapter.isDownloaded)
        chapter,
  ];

  Future<void> _send() async {
    final keys = _selection.selected.toList(growable: false);
    if (keys.isEmpty || _sending) return;
    setState(() => _sending = true);
    final result = await ref
        .read(novelsRepositoryProvider)
        .requestAudio(
          sourceId: widget.sourceId,
          seriesKey: widget.seriesKey,
          chapterKeys: keys,
        );
    if (!mounted) return;
    setState(() => _sending = false);

    if (result.isErr) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not reach the server.')),
      );
      return;
    }
    final request = result.value;
    final key = (
      sourceId: widget.sourceId,
      seriesKey: widget.seriesKey,
    );
    ref.invalidate(novelAudioJobsProvider(key));
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_outcome(request.queued.length, request.skipped))),
    );
  }

  /// Say what happened to every chapter, not just the good half.
  String _outcome(int queued, Map<String, String> skipped) {
    final parts = <String>[
      if (queued > 0)
        queued == 1
            ? 'Queued 1 chapter for narration.'
            : 'Queued $queued chapters for narration.',
      if (skipped.isNotEmpty) '${skipped.length} skipped.',
    ];
    return parts.isEmpty ? 'Nothing to narrate.' : parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final eligible = _eligible;
    final count = _selection.count;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.all(context.space.md),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Make audiobook',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.space.md),
              child: Wrap(
                spacing: context.space.xs,
                children: [
                  _chip(
                    'Next $kQuickRangeChapterCount',
                    () => _selection.replaceWith(
                      nextUnreadUndownloadedKeys(eligible),
                    ),
                  ),
                  _chip(
                    'All un-narrated (${eligible.length})',
                    () => _selection.replaceWith(eligible.map((c) => c.key)),
                  ),
                  _chip('None', _selection.clearSelection),
                ],
              ),
            ),
            const Divider(height: 24),
            Flexible(
              child: ListView.builder(
                itemCount: widget.chapters.length,
                itemBuilder: (context, index) {
                  final chapter = widget.chapters[index];
                  final narratable = widget.cached.contains(chapter.key);
                  final already = chapter.isDownloaded;
                  return CheckboxListTile(
                    dense: true,
                    value: _selection.isSelected(chapter.key),
                    // Not selectable is not the same as not shown: a reader
                    // looking for a chapter needs to see it and be told why
                    // it cannot be narrated yet.
                    onChanged: !narratable || already
                        ? null
                        : (_) => _selection.toggle(chapter.key),
                    title: Text(
                      chapter.title ??
                          'Chapter ${chapter.number?.toString() ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: already
                        ? const Text('Already narrated')
                        : narratable
                        ? null
                        : const Text('Download the text first'),
                    secondary: already
                        ? const Icon(Icons.headphones_rounded, size: 18)
                        : null,
                  );
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.all(context.space.md),
              child: Column(
                children: [
                  if (count > 0)
                    Padding(
                      padding: EdgeInsets.only(bottom: context.space.xs),
                      child: Text(
                        'About ${count * _minutesPerChapter} minutes of '
                        'rendering on the PC.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: count == 0 || _sending ? null : _send,
                      icon: const Icon(Icons.graphic_eq_rounded),
                      label: Text(
                        count == 0
                            ? 'Select chapters'
                            : 'Make audiobook of $count '
                                  '${count == 1 ? "chapter" : "chapters"}',
                      ),
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

  Widget _chip(String label, VoidCallback onTap) =>
      ActionChip(label: Text(label), onPressed: onTap);
}
