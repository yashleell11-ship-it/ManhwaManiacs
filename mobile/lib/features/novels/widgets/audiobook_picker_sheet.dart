import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_selection.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/series_download_status_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
import 'package:manhwamaniacs/features/novels/models/narration_save_state.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_audio_provider.dart';
import 'package:manhwamaniacs/features/novels/providers/series_audio_provider.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

/// What the sheet is for right now.
enum AudiobookPickerMode {
  /// Ask the render PC to narrate chapters that have no audio yet.
  narrate,

  /// Keep audio that already exists on this phone, for listening offline.
  save,
}

/// Choose which chapters to have narrated, or which narrations to keep on
/// the phone.
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
///
/// Saving is the other half, and costs the server nothing but bandwidth: only
/// chapters that already have audio can be saved, and a saved one says so.
/// When the server has no render worker, saving is all this sheet offers —
/// and it says plainly why narrating is not.
class AudiobookPickerSheet extends ConsumerStatefulWidget {
  const AudiobookPickerSheet({
    super.key,
    required this.sourceId,
    required this.seriesKey,
    required this.chapters,
    required this.cached,
    this.canRender = true,
    this.seriesTitle,
  });

  final String sourceId;
  final String seriesKey;

  /// Every chapter in the book, in reading order. `isDownloaded` means
  /// "already has audio on the server" on this sheet.
  final List<SelectableChapter> chapters;

  /// Chapter keys whose text is on the server. Only these can be narrated —
  /// rendering reads the chapter, and reading one that is not cached would
  /// make the server scrape the source.
  final Set<String> cached;

  /// Whether the server can make new audio at all.
  final bool canRender;

  /// For the Downloads screen's heading over what gets saved.
  final String? seriesTitle;

  static Future<void> show(
    BuildContext context, {
    required String sourceId,
    required String seriesKey,
    required List<SelectableChapter> chapters,
    required Set<String> cached,
    bool canRender = true,
    String? seriesTitle,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => AudiobookPickerSheet(
        sourceId: sourceId,
        seriesKey: seriesKey,
        chapters: chapters,
        cached: cached,
        canRender: canRender,
        seriesTitle: seriesTitle,
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
  late AudiobookPickerMode _mode = widget.canRender
      ? AudiobookPickerMode.narrate
      : AudiobookPickerMode.save;

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

  /// What the rows showed at the last build, for the save button to act on:
  /// what the reader saw is what they chose from.
  Map<String, NarrationSaveState> _shown = const {};

  /// Saved-narration state per chapter key, from the phone's own store, with
  /// a complete copy this phone cannot play told apart from one it can.
  Map<String, NarrationSaveState> get _saved {
    final series = (sourceId: widget.sourceId, seriesKey: widget.seriesKey);
    final statuses =
        ref.watch(seriesNarrationStatusProvider(series)).valueOrNull ??
            const <String, ChapterDownloadStatus>{};
    final unplayable =
        ref.watch(unplayableNarrationSavesProvider(series)).valueOrNull ??
            const <String>{};
    return {
      for (final entry in statuses.entries)
        entry.key: narrationSaveState(
          entry.value,
          unplayable: unplayable.contains(entry.key),
        ),
    };
  }

  /// The chapters that can actually be narrated: text on the server, and no
  /// audio yet.
  List<SelectableChapter> get _narratable => [
    for (final chapter in widget.chapters)
      if (widget.cached.contains(chapter.key) && !chapter.isDownloaded)
        chapter,
  ];

  /// The chapters whose audio can be saved: narrated, and not already on the
  /// phone or on its way. A FAILED save is offered again — that is the retry
  /// — and so is a copy this phone cannot play, which saving replaces.
  List<SelectableChapter> _savable(Map<String, NarrationSaveState> saved) => [
    for (final chapter in widget.chapters)
      if (chapter.isDownloaded &&
          offersNarrationSave(saved[chapter.key] ?? NarrationSaveState.none))
        chapter,
  ];

  void _switchTo(AudiobookPickerMode mode) {
    if (mode == _mode) return;
    _selection.clearSelection();
    setState(() => _mode = mode);
  }

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
      // The server's own words: a refusal ("Administrator access required.")
      // and an outage are different things to the person holding the phone,
      // and "could not reach the server" was wrong for the first.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error.userMessage)),
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

  /// Queue the selected chapters' audio — and their text, which offline
  /// listening needs just as much (see [narrationDownloadRequests]).
  Future<void> _save() async {
    final selected = _selection.selected;
    if (selected.isEmpty || _sending) return;
    final saved = _shown;
    final queue = ref.read(downloadQueueControllerProvider.notifier);
    setState(() => _sending = true);
    // A copy that cannot play has to go first: saving onto a complete row
    // keeps the bytes it already has, which are the ones that do not play.
    for (final key in selected) {
      if (saved[key] != NarrationSaveState.unplayable) continue;
      final ChapterIdentity chapter = (
        sourceId: widget.sourceId,
        seriesKey: widget.seriesKey,
        chapterKey: key,
      );
      await queue.cancelChapter(audioIdentity(chapter));
    }
    final requests = [
      for (final chapter in widget.chapters)
        if (selected.contains(chapter.key))
          ...narrationDownloadRequests(
            chapter: (
              sourceId: widget.sourceId,
              seriesKey: widget.seriesKey,
              chapterKey: chapter.key,
            ),
            chapterNumber: chapter.number,
            title: chapter.title,
            seriesTitle: widget.seriesTitle,
          ),
    ];
    await queue.enqueueChapters(requests);
    if (!mounted) return;
    final count = selected.length;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == 1
              ? 'Saving the audio of 1 chapter to this phone.'
              : 'Saving the audio of $count chapters to this phone.',
        ),
      ),
    );
  }

  /// Say what happened to every chapter, not just the good half.
  String _outcome(int queued, Map<String, String> skipped) {
    final parts = <String>[
      if (queued > 0)
        queued == 1
            ? 'Queued 1 chapter for narration.'
            : 'Queued $queued chapters for narration.',
      if (skipped.isNotEmpty) skippedNarrationLine(skipped),
    ];
    return parts.isEmpty ? 'Nothing to narrate.' : parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final saved = _shown = _saved;
    final saving = _mode == AudiobookPickerMode.save;
    // Saving needs somewhere to save into; the rest of the app hides its
    // download controls with no active profile, and so does this.
    final canSave = ref.watch(downloadsStoreProvider) != null;
    final eligible = saving ? _savable(saved) : _narratable;
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
                      'Audiobook',
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
            if (widget.canRender && canSave)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  context.space.md,
                  0,
                  context.space.md,
                  context.space.sm,
                ),
                child: SegmentedButton<AudiobookPickerMode>(
                  segments: const [
                    ButtonSegment(
                      value: AudiobookPickerMode.narrate,
                      label: Text('Narrate'),
                      icon: Icon(Icons.graphic_eq_rounded),
                    ),
                    ButtonSegment(
                      value: AudiobookPickerMode.save,
                      label: Text('Save to phone'),
                      icon: Icon(Icons.download_for_offline_outlined),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (modes) => _switchTo(modes.first),
                ),
              ),
            if (!widget.canRender)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  context.space.md,
                  0,
                  context.space.md,
                  context.space.sm,
                ),
                child: Text(
                  'Narration of new chapters is not available right now. '
                  'Chapters that already have audio can be saved to this '
                  'phone.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.space.md),
              child: Wrap(
                spacing: context.space.xs,
                children: [
                  if (!saving)
                    _chip(
                      'Next $kQuickRangeChapterCount',
                      () => _selection.replaceWith(
                        nextUnreadUndownloadedKeys(eligible),
                      ),
                    ),
                  _chip(
                    saving
                        ? 'All narrated (${eligible.length})'
                        : 'All un-narrated (${eligible.length})',
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
                  return saving
                      ? _saveRow(chapter, saved[chapter.key])
                      : _narrateRow(chapter, saved[chapter.key]);
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.all(context.space.md),
              child: Column(
                children: [
                  if (count > 0 && !saving)
                    Padding(
                      padding: EdgeInsets.only(bottom: context.space.xs),
                      child: Text(
                        'About ${count * _minutesPerChapter} minutes of '
                        'rendering on the PC.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (count > 0 && saving)
                    Padding(
                      padding: EdgeInsets.only(bottom: context.space.xs),
                      child: Text(
                        // Foreground-only, as every download here is: a
                        // sideloaded iPhone gives the app no dependable time
                        // in the background.
                        'Saves while the app is open. The text is saved too, '
                        'so the chapter plays and follows along offline.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: count == 0 || _sending
                          ? null
                          : saving
                          ? _save
                          : _send,
                      icon: Icon(
                        saving
                            ? Icons.download_for_offline_outlined
                            : Icons.graphic_eq_rounded,
                      ),
                      label: Text(
                        count == 0
                            ? 'Select chapters'
                            : saving
                            ? 'Save audio of $count '
                                  '${count == 1 ? "chapter" : "chapters"}'
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

  Widget _title(SelectableChapter chapter) => Text(
    chapter.title ?? 'Chapter ${chapter.number?.toString() ?? ''}',
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );

  Widget _narrateRow(SelectableChapter chapter, NarrationSaveState? saved) {
    final narratable = widget.cached.contains(chapter.key);
    final already = chapter.isDownloaded;
    return CheckboxListTile(
      dense: true,
      value: _selection.isSelected(chapter.key),
      // Not selectable is not the same as not shown: a reader looking for a
      // chapter needs to see it and be told why it cannot be narrated yet.
      onChanged: !narratable || already
          ? null
          : (_) => _selection.toggle(chapter.key),
      title: _title(chapter),
      subtitle: already
          ? Text(
              saved == NarrationSaveState.saved
                  ? 'Already narrated · saved on this phone'
                  : 'Already narrated',
            )
          : narratable
          ? null
          : const Text('Download the text first'),
      secondary: already
          ? const Icon(Icons.headphones_rounded, size: 18)
          : null,
    );
  }

  Widget _saveRow(SelectableChapter chapter, NarrationSaveState? saved) {
    final state = saved ?? NarrationSaveState.none;
    final selectable = chapter.isDownloaded && offersNarrationSave(state);
    return CheckboxListTile(
      dense: true,
      value: _selection.isSelected(chapter.key),
      onChanged: selectable ? (_) => _selection.toggle(chapter.key) : null,
      title: _title(chapter),
      subtitle: Text(
        switch (state) {
          NarrationSaveState.saved => 'Saved on this phone',
          NarrationSaveState.unplayable =>
            'Saved copy cannot play on this phone — select to save again',
          NarrationSaveState.saving => 'Saving…',
          NarrationSaveState.failed => 'Could not be saved — select to retry',
          NarrationSaveState.none when chapter.isDownloaded => 'Narrated',
          NarrationSaveState.none => 'Not narrated yet',
        },
      ),
      secondary: switch (state) {
        NarrationSaveState.saved =>
          const Icon(Icons.download_done_rounded, size: 18),
        NarrationSaveState.unplayable =>
          const Icon(Icons.sync_problem_rounded, size: 18),
        _ => null,
      },
    );
  }

  Widget _chip(String label, VoidCallback onTap) =>
      ActionChip(label: Text(label), onPressed: onTap);
}

/// "Skipped: 2 already asked for, 1 not downloaded to the server yet." — the
/// reasons, because "N skipped." with none left a reader re-asking for the
/// same chapters to find out why.
String skippedNarrationLine(Map<String, String> skipped) {
  final counts = <String, int>{};
  for (final reason in skipped.values) {
    final text = _skipReasons[reason] ?? 'could not be narrated';
    counts[text] = (counts[text] ?? 0) + 1;
  }
  final parts = [
    for (final entry in counts.entries) '${entry.value} ${entry.key}',
  ];
  return 'Skipped: ${parts.join(', ')}.';
}

/// The server's reason codes (`novel_render_queue.enqueue`), as a reader
/// would say them.
const Map<String, String> _skipReasons = {
  'already_queued': 'already asked for',
  'already_rendered': 'already narrated',
  'chapter_not_cached': 'not downloaded to the server yet',
  'chapter_unreadable': 'could not be read',
};
