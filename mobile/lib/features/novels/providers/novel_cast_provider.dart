import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/novels/models/novel_cast.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_chapter_provider.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

/// Who speaks in this chapter, and in whose voice.
///
/// A separate request from the prose and never awaited in front of it:
/// attribution exists for a fraction of the library, so a reader must not wait
/// on a lookup that usually answers nothing.
///
/// A failure resolves to [NovelAttribution.none] rather than throwing. The
/// cast panel is an addition to the page — it has to leave exactly the reading
/// experience that shipped before it existed, not an error screen.
final novelAttributionProvider = FutureProvider.autoDispose
    .family<NovelAttribution, NovelChapterKey>((ref, key) async {
      final result = await ref
          .watch(novelsRepositoryProvider)
          .attribution(
            sourceId: key.sourceId,
            seriesKey: key.seriesKey,
            chapterKey: key.chapterKey,
          );
      return result.isErr ? NovelAttribution.none : result.value;
    });

/// Every voice a character can be given.
///
/// Per-server and effectively static — the roster changes when somebody drops
/// a clip on the box, not when a reader does anything — so it is kept alive
/// for the session rather than refetched per chapter.
///
/// An empty list is a real answer, and the one the picker checks: a deployment
/// with no pack installed still reads novels, it just cannot cast anybody, and
/// nothing should offer a choice that is not really there.
final novelVoicesProvider = FutureProvider<List<NovelVoice>>((ref) async {
  final result = await ref.watch(novelsRepositoryProvider).voices();
  return result.isErr ? const <NovelVoice>[] : result.value;
});

/// Pin a voice, for one character or for the series' narration.
///
/// Returns whether it stuck, so the sheet can say so rather than silently
/// showing a choice the server refused — a voice the renderer does not have
/// would otherwise read as narrator with the UI still claiming otherwise.
class NovelVoiceWriter {
  const NovelVoiceWriter(this._ref);

  final Ref _ref;

  Future<bool> setCharacter(
    NovelChapterKey key,
    String name,
    String? voiceId,
  ) async {
    final result = await _ref
        .read(novelsRepositoryProvider)
        .setCastVoice(
          sourceId: key.sourceId,
          seriesKey: key.seriesKey,
          name: name,
          voiceId: voiceId,
        );
    if (result.isErr) return false;
    _ref.invalidate(novelAttributionProvider(key));
    return true;
  }

  Future<bool> setNarrator(NovelChapterKey key, String? voiceId) async {
    final result = await _ref
        .read(novelsRepositoryProvider)
        .setNarratorVoice(
          sourceId: key.sourceId,
          seriesKey: key.seriesKey,
          voiceId: voiceId,
        );
    if (result.isErr) return false;
    _ref.invalidate(novelAttributionProvider(key));
    return true;
  }
}

final novelVoiceWriterProvider = Provider<NovelVoiceWriter>(
  NovelVoiceWriter.new,
);
