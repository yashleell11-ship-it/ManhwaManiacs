import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/series_download_status_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';

/// Keep this chapter's narration on the phone, and show that it is kept.
///
/// Sits beside the reader's player: the place somebody deciding to listen
/// offline already is. One control through every state — save, saving,
/// saved (tap to remove), failed (tap to retry) — so the chapter always says
/// where its audio stands rather than the reader having to go and look in
/// Downloads.
///
/// Hidden with no active profile: there is no store to save into, and the
/// rest of the app hides its download controls in the same case.
///
/// Like every download here it runs only while the app is in the foreground —
/// a sideloaded iPhone gives the app no dependable background time — and it
/// resumes by itself when the app comes back.
class NarrationSaveButton extends ConsumerWidget {
  const NarrationSaveButton({
    required this.chapter,
    required this.color,
    this.chapterNumber,
    this.title,
    this.seriesTitle,
    super.key,
  });

  /// The CHAPTER, not its audio row.
  final ChapterIdentity chapter;
  final Color color;
  final double? chapterNumber;
  final String? title;
  final String? seriesTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(downloadsStoreProvider) == null) {
      return const SizedBox.shrink();
    }
    final series = (sourceId: chapter.sourceId, seriesKey: chapter.seriesKey);
    final status = ref
        .watch(seriesNarrationStatusProvider(series))
        .valueOrNull?[chapter.chapterKey];

    void save() => ref
        .read(downloadQueueControllerProvider.notifier)
        .enqueueChapters(
          narrationDownloadRequests(
            chapter: chapter,
            chapterNumber: chapterNumber,
            title: title,
            seriesTitle: seriesTitle,
          ),
        );

    return switch (status?.state) {
      null => IconButton(
          key: const Key('narration-save'),
          tooltip: 'Save audio to this phone',
          onPressed: save,
          icon: Icon(Icons.download_for_offline_outlined, color: color),
        ),
      DownloadChapterState.queued ||
      DownloadChapterState.downloading =>
        Tooltip(
          message: 'Saving audio to this phone…',
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
          ),
        ),
      DownloadChapterState.complete => IconButton(
          key: const Key('narration-saved'),
          tooltip: 'Audio saved on this phone',
          onPressed: () => _confirmRemove(context, ref),
          icon: Icon(Icons.download_done_rounded, color: color),
        ),
      DownloadChapterState.failed => IconButton(
          key: const Key('narration-failed'),
          tooltip: 'The audio could not be saved'
              '${status?.error == null ? '' : ': ${status!.error}'}'
              ' — tap to try again',
          onPressed: save,
          icon: Icon(Icons.error_outline_rounded, color: color),
        ),
    };
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove saved audio?'),
        content: const Text(
          'The chapter stays on this phone to read. You can save its audio '
          'again any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    // The audio row alone — its blobs are released with it, and the text is
    // left readable. Through the queue so a row still being written is
    // deleted by the loop that owns it, exactly as a cancel would be.
    await ref
        .read(downloadQueueControllerProvider.notifier)
        .cancelChapter(audioIdentity(chapter));
  }
}
