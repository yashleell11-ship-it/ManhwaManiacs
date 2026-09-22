import 'package:dio/dio.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';
import 'package:manhwamaniacs/features/novels/models/novel_cast.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter_window.dart';
import 'package:manhwamaniacs/features/novels/repositories/novels_repository.dart';

class NovelsRepositoryImpl implements NovelsRepository {
  const NovelsRepositoryImpl(this._dio);

  final Dio _dio;

  @override
  Future<Result<NovelChapter>> chapter({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/novels/chapter',
        queryParameters: {
          'source': sourceId,
          'series': seriesKey,
          'chapter': chapterKey,
        },
      );
      return Ok(NovelChapter.fromJson(r.data ?? const {}));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<NovelAudio>> audio({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/novels/audio',
        queryParameters: {
          'source': sourceId,
          'series': seriesKey,
          'chapter': chapterKey,
        },
      );
      return Ok(NovelAudio.fromJson(r.data ?? const {}));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<NovelAttribution>> attribution({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/novels/attribution',
        queryParameters: {
          'source': sourceId,
          'series': seriesKey,
          'chapter': chapterKey,
        },
      );
      return Ok(NovelAttribution.fromJson(r.data ?? const {}));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<List<int>>> audioBytes({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async {
    try {
      final r = await _dio.get<List<int>>(
        '/novels/audio/file',
        queryParameters: {
          'source': sourceId,
          'series': seriesKey,
          'chapter': chapterKey,
        },
        options: Options(responseType: ResponseType.bytes),
      );
      return Ok(r.data ?? const <int>[]);
    } on DioException catch (e) {
      // 404 is "not narrated", which is the ordinary answer for almost the
      // whole library and not an error worth a message.
      if (e.response?.statusCode == 404) return const Ok(<int>[]);
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<NovelSeriesAudio>> seriesAudio({
    required String sourceId,
    required String seriesKey,
  }) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/novels/audio/series',
        queryParameters: {'source': sourceId, 'series': seriesKey},
      );
      final data = r.data ?? const {};
      final raw = data['chapters'];
      final cached = data['narratable'];
      return Ok((
        rendered: raw is List
            ? {
                for (final e in raw.whereType<Map<String, dynamic>>())
                  if ((e['chapter_key'] as String?)?.isNotEmpty ?? false)
                    e['chapter_key'] as String,
              }
            : <String>{},
        narratable: cached is List
            ? cached.whereType<String>().toSet()
            : <String>{},
        // Absent on a server from before the flag existed. None of those has
        // a render worker, so "no" is the honest reading, not a guess.
        canRender: data['can_render'] == true,
      ),);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<NovelAudioRequest>> requestAudio({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/novels/audio/render',
        data: {
          'source_id': sourceId,
          'series_key': seriesKey,
          'chapter_keys': chapterKeys,
        },
      );
      return Ok(NovelAudioRequest.fromJson(r.data ?? const {}));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<List<NovelAudioJob>>> audioJobs({
    required String sourceId,
    required String seriesKey,
  }) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/novels/audio/jobs',
        queryParameters: {'source': sourceId, 'series': seriesKey},
      );
      final raw = (r.data ?? const {})['jobs'];
      return Ok(
        raw is List
            ? raw
                  .whereType<Map<String, dynamic>>()
                  .map(NovelAudioJob.fromJson)
                  .where((j) => j.jobId.isNotEmpty)
                  .toList(growable: false)
            : const <NovelAudioJob>[],
      );
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<void>> cancelAudioJob(String jobId) async {
    try {
      await _dio.delete<void>('/novels/audio/jobs/$jobId');
      return const Ok(null);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<List<NovelVoice>>> voices() async {
    try {
      final r = await _dio.get<Map<String, dynamic>>('/novels/voices');
      final raw = (r.data ?? const {})['voices'];
      return Ok(
        raw is List
            ? raw
                  .whereType<Map<String, dynamic>>()
                  .map(NovelVoice.fromJson)
                  .where((v) => v.voiceId.isNotEmpty)
                  .toList(growable: false)
            : const <NovelVoice>[],
      );
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<void>> setCastVoice({
    required String sourceId,
    required String seriesKey,
    required String name,
    required String? voiceId,
  }) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        '/novels/cast',
        data: {
          'source_id': sourceId,
          'series_key': seriesKey,
          'name': name,
          'voice_id': voiceId,
        },
      );
      return const Ok(null);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<void>> setNarratorVoice({
    required String sourceId,
    required String seriesKey,
    required String? voiceId,
  }) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        '/novels/narrator',
        data: {
          'source_id': sourceId,
          'series_key': seriesKey,
          'voice_id': voiceId,
        },
      );
      return const Ok(null);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<NovelChapterWindow>> chapterWindow({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/novels/chapters',
        data: {
          'source_id': sourceId,
          'series_key': seriesKey,
          'chapter_keys': chapterKeys,
        },
      );
      return Ok(NovelChapterWindow.fromJson(r.data ?? const {}));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  AppError _err(DioException e) {
    if (e.error is AppError) return e.error! as AppError;
    return UnknownError(message: e.message ?? 'Dio error', cause: e);
  }
}
