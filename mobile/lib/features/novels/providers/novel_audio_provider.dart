import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/series_download_status_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';
import 'package:manhwamaniacs/features/novels/models/narration_save_state.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio_format.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_chapter_provider.dart';
import 'package:manhwamaniacs/features/novels/utils/narration_playback.dart';
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
///
/// [playable] false is a save this phone's player cannot open — an Ogg file
/// saved on an iPhone before the server could send anything else. It is
/// still reported, rather than read as "not saved", so the chapter can say
/// it needs saving again instead of claiming a copy that plays nothing.
typedef SavedNarration = ({File file, NovelAudio audio, bool playable});

/// This chapter's saved narration, or null when there is none — not saved,
/// still downloading, no active profile, or a file deleted by hand.
///
/// Re-reads whenever a download finishes (the queue's revision moves), so a
/// narration that lands while its chapter is open is picked up for the next
/// press of play without leaving the reader.
///
/// What the file IS is read from its first bytes, not assumed: nothing
/// recorded the format of a save made before formats existed. On an iPhone
/// the file is then handed over as a copy named `.m4a`, because AVPlayer
/// takes a local file's type from its name and a saved blob has none.
final savedNarrationProvider = FutureProvider.autoDispose
    .family<SavedNarration?, NovelChapterKey>((ref, key) async {
  final store = ref.watch(downloadsStoreProvider);
  ref.watch(downloadQueueControllerProvider.select((s) => s.queueRevision));
  if (store == null) return null;
  final saved = await store.readSavedNarration(key);
  if (saved == null) return null;
  final NovelAudio audio;
  try {
    audio = NovelAudio.fromJson(saved.timing);
  } catch (_) {
    // A map that will not parse is not a narration anyone can follow; the
    // reader falls back to streaming rather than to an error.
    return null;
  }
  if (!audio.available) return null;

  final platform = defaultTargetPlatform;
  final format = await sniffNovelAudioFile(saved.audio);
  if (format == null || !canPlayNovelAudio(format, platform)) {
    return (file: saved.audio, audio: audio, playable: false);
  }
  if (!playsByExtension(platform)) {
    return (file: saved.audio, audio: audio, playable: true);
  }
  try {
    final cache = await ref.watch(narrationPlaybackCacheProvider.future);
    final file = await narrationPlaybackFile(
      blob: saved.audio,
      format: format,
      cache: cache,
    );
    return (file: file, audio: audio, playable: true);
  } catch (_) {
    // No copy, no way to hand AVPlayer the file. Streaming still works, and
    // the save is still good — it is this play that could not use it.
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
  // A save this phone cannot play is passed over for the stream, which asks
  // for a format it can.
  if (saved != null && saved.playable) {
    return (audio: saved.audio, file: saved.file);
  }
  final remote = await ref.watch(novelAudioProvider(key).future);
  return remote.available ? (audio: remote, file: null) : null;
});

/// What each saved narration's bytes are, by blob path.
///
/// Blobs are named by their content hash, so a path always holds the same
/// bytes and one look lasts. Kept alive for that reason: a chapter list
/// re-asks every time the queue moves, and on a long book that is hundreds
/// of files opened again for an answer that cannot have changed. A read that
/// failed is not remembered, so it is tried again next time.
final _savedNarrationFormatsProvider =
    Provider<Map<String, NovelAudioFormat>>((ref) => {});

/// The chapters of [series] whose narration is saved, complete, and cannot
/// play on this phone — keyed by the CHAPTER's key, as
/// [seriesNarrationStatusProvider] is.
///
/// An Ogg narration saved on an iPhone before the server could convert is a
/// complete row like any other, and that row is all the status provider
/// knows. Without this a chapter list calls it saved, and a bulk save passes
/// it over as already done — so the only way to replace a book's worth of
/// them was the reader's button, one chapter at a time.
///
/// Empty wherever every format plays (see [savedNarrationMayBeUnplayable]).
final unplayableNarrationSavesProvider = FutureProvider.autoDispose
    .family<Set<String>, SeriesIdentity>((ref, series) async {
  final platform = defaultTargetPlatform;
  if (!savedNarrationMayBeUnplayable(platform)) return const {};
  final store = ref.watch(downloadsStoreProvider);
  if (store == null) return const {};
  final statuses =
      await ref.watch(seriesNarrationStatusProvider(series).future);
  final formats = ref.read(_savedNarrationFormatsProvider);

  final unplayable = <String>{};
  for (final entry in statuses.entries) {
    if (entry.value.state != DownloadChapterState.complete) continue;
    final ChapterIdentity chapter = (
      sourceId: series.sourceId,
      seriesKey: series.seriesKey,
      chapterKey: entry.key,
    );
    final Map<int, File> blobs;
    try {
      blobs = await store.localPagePaths(audioIdentity(chapter));
    } catch (_) {
      continue;
    }
    final blob = blobs[DownloadsStore.audioBlobNumber];
    // No file is not a copy that fails to play: the reader streams for a
    // save it cannot find, exactly as it would with none.
    if (blob == null) continue;
    final format =
        formats[blob.path] ?? await sniffNovelAudioFile(blob);
    if (format != null) formats[blob.path] = format;
    if (!canPlayNovelAudio(format, platform)) unplayable.add(entry.key);
  }
  return unplayable;
});
