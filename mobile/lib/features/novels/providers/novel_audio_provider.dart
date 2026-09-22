import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
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

/// A chapter's narration as it is saved on this phone: the file to play and
/// the timing map it was rendered with.
typedef SavedNarration = ({File file, NovelAudio audio});

/// This chapter's saved narration, or null when there is none — not saved,
/// still downloading, no active profile, or a file deleted by hand.
///
/// Re-reads whenever a download finishes (the queue's revision moves), so a
/// narration that lands while its chapter is open is picked up for the next
/// press of play without leaving the reader.
final savedNarrationProvider = FutureProvider.autoDispose
    .family<SavedNarration?, NovelChapterKey>((ref, key) async {
  final store = ref.watch(downloadsStoreProvider);
  ref.watch(downloadQueueControllerProvider.select((s) => s.queueRevision));
  if (store == null) return null;
  final saved = await store.readSavedNarration(key);
  if (saved == null) return null;
  try {
    final audio = NovelAudio.fromJson(saved.timing);
    return audio.available ? (file: saved.audio, audio: audio) : null;
  } catch (_) {
    // A map that will not parse is not a narration anyone can follow; the
    // reader falls back to streaming rather than to an error.
    return null;
  }
});

/// What the reader can play for this chapter, preferring the phone's copy.
///
/// [file] is set when the narration is saved: it plays with no network and
/// its own timing map keeps the highlight on the words being spoken. Only
/// when nothing is saved is the server asked — the same lookup the reader
/// always made, still never awaited in front of the prose.
typedef PlayableNovelAudio = ({NovelAudio audio, File? file});

final playableNovelAudioProvider = FutureProvider.autoDispose
    .family<PlayableNovelAudio?, NovelChapterKey>((ref, key) async {
  final saved = await ref.watch(savedNarrationProvider(key).future);
  if (saved != null) return (audio: saved.audio, file: saved.file);
  final remote = await ref.watch(novelAudioProvider(key).future);
  return remote.available ? (audio: remote, file: null) : null;
});
