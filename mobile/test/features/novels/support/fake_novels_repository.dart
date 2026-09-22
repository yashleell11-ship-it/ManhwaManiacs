import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';
import 'package:manhwamaniacs/features/novels/models/novel_cast.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter_window.dart';
import 'package:manhwamaniacs/features/novels/repositories/novels_repository.dart';

/// A [NovelsRepository] with every answer scripted and every request
/// recorded, for the narration tests: what the phone asked the server for is
/// usually the thing under test, not just what it did with the answer.
class FakeNovelsRepository implements NovelsRepository {
  /// What `GET /novels/audio` answers, per chapter key.
  Map<String, NovelAudio> audioByChapter = {};

  /// What `GET /novels/audio/file` answers, per chapter key. A key that is
  /// absent answers empty, exactly as the real client maps a 404.
  Map<String, List<int>> audioBytesByChapter = {};

  Result<NovelSeriesAudio> seriesAudioResult = const Ok(
    (rendered: <String>{}, narratable: <String>{}),
  );

  /// Answers for successive `GET /novels/audio/jobs` calls, in order. The
  /// last one repeats once the list runs out.
  List<Result<List<NovelAudioJob>>> audioJobsResults = [
    const Ok(<NovelAudioJob>[]),
  ];

  Result<NovelAudioRequest> requestAudioResult = const Ok(
    NovelAudioRequest(queued: <String>[], skipped: <String, String>{}),
  );

  Result<void> setCastVoiceResult = const Ok(null);

  final List<String> audioRequests = [];
  final List<String> audioBytesRequests = [];
  int seriesAudioCalls = 0;
  int audioJobsCalls = 0;
  final List<List<String>> renderRequests = [];
  final List<({String name, String? voiceId})> castWrites = [];

  @override
  Future<Result<NovelAudio>> audio({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async {
    audioRequests.add(chapterKey);
    return Ok(audioByChapter[chapterKey] ?? NovelAudio.none);
  }

  @override
  Future<Result<List<int>>> audioBytes({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async {
    audioBytesRequests.add(chapterKey);
    return Ok(audioBytesByChapter[chapterKey] ?? const <int>[]);
  }

  @override
  Future<Result<NovelSeriesAudio>> seriesAudio({
    required String sourceId,
    required String seriesKey,
  }) async {
    seriesAudioCalls++;
    return seriesAudioResult;
  }

  @override
  Future<Result<NovelAudioRequest>> requestAudio({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) async {
    renderRequests.add(chapterKeys);
    return requestAudioResult;
  }

  @override
  Future<Result<List<NovelAudioJob>>> audioJobs({
    required String sourceId,
    required String seriesKey,
  }) async {
    final index = audioJobsCalls < audioJobsResults.length
        ? audioJobsCalls
        : audioJobsResults.length - 1;
    audioJobsCalls++;
    return audioJobsResults[index];
  }

  @override
  Future<Result<void>> cancelAudioJob(String jobId) async => const Ok(null);

  @override
  Future<Result<NovelAttribution>> attribution({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async =>
      const Ok(NovelAttribution.none);

  @override
  Future<Result<List<NovelVoice>>> voices() async => const Ok(<NovelVoice>[]);

  @override
  Future<Result<void>> setCastVoice({
    required String sourceId,
    required String seriesKey,
    required String name,
    required String? voiceId,
  }) async {
    castWrites.add((name: name, voiceId: voiceId));
    return setCastVoiceResult;
  }

  @override
  Future<Result<void>> setNarratorVoice({
    required String sourceId,
    required String seriesKey,
    required String? voiceId,
  }) async =>
      const Ok(null);

  @override
  Future<Result<NovelChapter>> chapter({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async =>
      const Err(NetworkError(message: 'no chapters in this test'));

  @override
  Future<Result<NovelChapterWindow>> chapterWindow({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) async =>
      const Err(NetworkError(message: 'no window in this test'));
}

/// The 403 the server gives a non-admin who tries to change a voice.
const adminRequired = ApiError(
  statusCode: 403,
  code: 'forbidden',
  message: 'Administrator access required.',
);
