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
