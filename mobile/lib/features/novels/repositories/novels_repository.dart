import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter_window.dart';

/// The novel side's one network call.
///
/// Browse, search and series detail need no repository of their own: a novel
/// source is a source, so `SourcesRepository` already serves them the moment
/// the registry gate lets the connectors through. Only chapter *text* has no
/// manga equivalent, because a manga chapter's payload is a list of image
/// URLs and a novel chapter's is the prose itself.
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
  /// READ-ONLY on the server: attribution and rendering are bought by a
  /// deliberate pass, never by somebody opening a chapter. An unrendered
  /// chapter answers `available: false` rather than 404, because that is the
  /// ordinary state for almost the whole library and a reader should not be
  /// walking error paths for it.
  Future<Result<NovelAudio>> audio({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
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
