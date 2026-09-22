import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';
import 'package:manhwamaniacs/features/novels/models/novel_cast.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter_window.dart';

/// The novel side's one network call.
///
/// Browse, search and series detail need no repository of their own: a novel
/// source is a source, so `SourcesRepository` already serves them the moment
/// the registry gate lets the connectors through. Only chapter *text* has no
/// manga equivalent, because a manga chapter's payload is a list of image
/// URLs and a novel chapter's is the prose itself.
/// What one book's audio looks like: what exists, and what could.
///
/// `canRender` is whether this server can make NEW audio at all — true only
/// when a render worker is configured. Without one a request queues and
/// never runs, so the app must not offer it, and a queued job must not be
/// polled or shown as in progress forever.
typedef NovelSeriesAudio = ({
  Set<String> rendered,
  Set<String> narratable,
  bool canRender,
});

abstract class NovelsRepository {
  /// One chapter as sanitized plain-text paragraphs.
  ///
  /// Query-param identity, like every other source-native endpoint: connector
  /// keys are opaque and routinely contain `/`, so they are never path
  /// segments. 404s when `MM_NOVELS_ENABLED` is off — the whole router is
  /// unmounted, so an off feature is indistinguishable from one that was
  /// never built.
  Future<Result<NovelChapter>> chapter({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  });

  /// Whether this chapter has been rendered, and where each sentence sits.
  ///
  /// Rendering is bought by a deliberate REQUEST — see [requestAudio] — and
  /// never as a side effect of somebody opening a chapter. That distinction
  /// is the whole cost model: a chapter is about nine minutes on a GPU shared
  /// with a training run, so turning a page must never spend one.
  ///
  /// An unrendered chapter answers `available: false` rather than 404,
  /// because that is the ordinary state for almost the whole library and a
  /// reader should not be walking error paths for it.
  Future<Result<NovelAudio>> audio({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  });

  /// Who speaks each line in this chapter, and in whose voice.
  ///
  /// A separate call from the chapter text, and never awaited in front of it:
  /// attribution exists for a fraction of the library, so folding it in would
  /// make every reader wait on a lookup that usually answers nothing.
  Future<Result<NovelAttribution>> attribution({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  });

  /// One chapter's narration, as bytes, for storing on the phone.
  ///
  /// Separate from streaming it: the player sets a URL and lets the platform
  /// pull ranges, which is right for listening and useless for saving.
  /// Answers empty when the chapter has not been narrated.
  Future<Result<List<int>>> audioBytes({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  });

  /// Which chapters of this book already have audio, and which COULD.
  ///
  /// One call so a table of contents can mark them. Asking per chapter is
  /// several hundred round trips for a long novel, and all but a handful
  /// answer no.
  ///
  /// `narratable` is the chapters whose text is on the server. Rendering
  /// reads the chapter, so one that is not cached cannot be asked for — the
  /// picker greys those rather than offering them and being refused.
  Future<Result<NovelSeriesAudio>> seriesAudio({
    required String sourceId,
    required String seriesKey,
  });

  /// Ask for these chapters to be narrated.
  ///
  /// Answers for EVERY chapter — queued, or skipped with a reason. Partial
  /// success is the ordinary outcome when somebody asks for a whole book, and
  /// showing it as a failure would be wrong.
  Future<Result<NovelAudioRequest>> requestAudio({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  });

  /// What has been asked for on this book, and where each one got to.
  Future<Result<List<NovelAudioJob>>> audioJobs({
    required String sourceId,
    required String seriesKey,
  });

  /// Stop a render. A job already on the card learns of it on its next
  /// heartbeat — nothing on the phone can reach the render box.
  Future<Result<void>> cancelAudioJob(String jobId);

  /// Every voice a character can be given.
  ///
  /// Server-side data rather than a list compiled into the app: a client
  /// carrying its own roster would offer a voice the renderer does not have
  /// the moment somebody drops a clip on the box.
  Future<Result<List<NovelVoice>>> voices();

  /// Pin a character's voice, and lock the row against the next recast.
  ///
  /// `voiceId` null is sent as an explicit JSON null, which CLEARS the pin:
  /// the character goes back to an automatically assigned voice. Changing a
  /// voice is an owner's decision, so a non-admin gets a 403 whose message
  /// the caller shows.
  Future<Result<void>> setCastVoice({
    required String sourceId,
    required String seriesKey,
    required String name,
    required String? voiceId,
  });

  /// Pin the voice that reads narration for the whole series.
  ///
  /// Separate from a cast member because the narrator is a property of the
  /// BOOK. A chapter narrated by somebody in the cast still reads in that
  /// character's own voice — they are the same person.
  Future<Result<void>> setNarratorVoice({
    required String sourceId,
    required String seriesKey,
    required String? voiceId,
  });

  /// A bounded WINDOW of one book's chapters in a single round trip —
  /// `POST /novels/chapters` (spec R5).
  ///
  /// POST rather than GET because the body is a list of opaque connector keys
  /// that routinely contain slashes and percent-encoding; twenty of those do
  /// not belong in a query string. It is still a read.
  ///
  /// This is what makes "download a whole novel" reasonable: chapter text is
  /// kilobytes, so hundreds of separate requests are almost entirely
  /// round-trip overhead. The result is per-item, never all-or-nothing —
  /// see [NovelChapterWindow].
  ///
  /// Over the server's cap the call fails with a `batch_too_large` [ApiError]
  /// naming it; every success echoes `max_chapters`, so a caller paces itself
  /// by the server's stride rather than a number compiled into the app.
  Future<Result<NovelChapterWindow>> chapterWindow({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  });
}
