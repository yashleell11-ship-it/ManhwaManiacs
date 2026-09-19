import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_chapter_provider.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

/// Whether this chapter has been rendered, and the map to follow along with.
///
/// Deliberately a SEPARATE request from the prose, and never awaited in front
/// of it: almost nothing in the library is rendered, so a reader must not wait
/// on a lookup that usually answers "no".
///
/// A failure resolves to [NovelAudio.none] rather than throwing. Audio is an
/// addition to the page — it has to leave exactly the reading experience that
/// shipped before any of this existed, not an error screen.
final novelAudioProvider = FutureProvider.autoDispose
    .family<NovelAudio, NovelChapterKey>((ref, key) async {
  final result = await ref.watch(novelsRepositoryProvider).audio(
        sourceId: key.sourceId,
        seriesKey: key.seriesKey,
        chapterKey: key.chapterKey,
      );
  return result.isErr ? NovelAudio.none : result.value;
});
