/// Where a chapter's saved narration stands, in the terms a chapter list
/// shows it.
///
/// The store knows a row's download state and nothing about what the bytes
/// are. An Ogg narration saved on an iPhone before the server could send
/// anything else is a COMPLETE row that plays nothing there, and a list that
/// read "complete" as "saved" said so under every one of them, with no way
/// to replace them but one chapter at a time from the reader.
library;

import 'package:flutter/foundation.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/providers/series_download_status_provider.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio_format.dart';

enum NarrationSaveState {
  /// Nothing on the phone.
  none,

  /// Queued or being fetched.
  saving,

  /// On the phone, and this phone can play it.
  saved,

  /// The last attempt failed.
  failed,

  /// On the phone, complete, and unplayable here. Offered for saving again,
  /// which replaces it.
  unplayable,
}

/// [status] as a chapter list should show it. [unplayable] is whether the
/// chapter's complete copy is one this phone cannot play.
NarrationSaveState narrationSaveState(
  ChapterDownloadStatus? status, {
  required bool unplayable,
}) =>
    switch (status?.state) {
      null => NarrationSaveState.none,
      DownloadChapterState.queued ||
      DownloadChapterState.downloading =>
        NarrationSaveState.saving,
      DownloadChapterState.failed => NarrationSaveState.failed,
      DownloadChapterState.complete => unplayable
          ? NarrationSaveState.unplayable
          : NarrationSaveState.saved,
    };

/// Whether a chapter in [state] is offered for saving: never saved, a
/// failed save to retry, or a copy to replace. One that is saved or on its
/// way is not asked for twice.
bool offersNarrationSave(NarrationSaveState state) => switch (state) {
      NarrationSaveState.none ||
      NarrationSaveState.failed ||
      NarrationSaveState.unplayable =>
        true,
      NarrationSaveState.saving || NarrationSaveState.saved => false,
    };

/// Whether a saved narration on [platform] could be one it cannot play, and
/// so is worth opening to look.
///
/// Only where some format is refused — an iPhone. Everywhere else every
/// container the server sends plays, and reading the head of every saved
/// chapter each time the queue moves would be work that can only ever
/// answer "fine".
bool savedNarrationMayBeUnplayable(TargetPlatform platform) =>
    NovelAudioFormat.values.any((format) => !canPlayNovelAudio(format, platform));
