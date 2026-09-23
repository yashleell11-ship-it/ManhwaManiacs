import 'package:dio/dio.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/reader/models/reader_chapter.dart';
import 'package:manhwamaniacs/features/sources/models/source.dart';
import 'package:manhwamaniacs/features/sources/models/source_pin.dart';
import 'package:manhwamaniacs/features/sources/models/source_search_group.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/repositories/sources_repository.dart';

class SourcesRepositoryImpl implements SourcesRepository {
  SourcesRepositoryImpl(this._dio, this._apiBaseUrl);

  final Dio _dio;
  final String _apiBaseUrl;

  @override
  Future<Result<List<SourceSummary>>> listSources() async {
    try {
      final r = await _dio.get<List<dynamic>>('/sources');
      final items = (r.data ?? [])
          .map((e) => SourceSummary.fromJson(e as Map<String, dynamic>))
          .toList();
      return Ok(items);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<GroupedSearchResult>> searchGrouped(
    String query, {
    int page = 1,
    int perPage = 40,
  }) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/sources/search',
        queryParameters: {'q': query, 'page': page, 'per_page': perPage},
      );
      // cover_url comes back relative, like /sources/{id}/series; the result
      // cards resolve it against the API base (searchResultCoverUrl).
      return Ok(GroupedSearchResult.fromJson(r.data ?? const {}));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<List<SourcePin>>> listPins() async {
    try {
      final r = await _dio.get<List<dynamic>>('/sources/pins');
      return Ok(_parsePins(r.data));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<List<SourcePin>>> replacePins(List<String> sourceIds) async {
    try {
      final r = await _dio.put<List<dynamic>>(
        '/sources/pins',
        data: {'source_ids': sourceIds},
      );
      return Ok(_parsePins(r.data));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  List<SourcePin> _parsePins(List<dynamic>? data) => (data ?? const [])
      .map((e) => SourcePin.fromJson(e as Map<String, dynamic>))
      .toList();

  @override
  Future<Result<List<SourceBrowseMode>>> listBrowseModes(String sourceId) async {
    try {
      final r = await _dio.get<List<dynamic>>('/sources/$sourceId/browse-modes');
      final items = (r.data ?? [])
          .map((e) => SourceBrowseMode.fromJson(e as Map<String, dynamic>))
          .toList();
      return Ok(items);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<PagedResult<SourceSeriesSummary>>> listSeries(
    String sourceId, {
    int page = 1,
    String? query,
    String? sort,
  }) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/sources/$sourceId/series',
        queryParameters: {
          'page': page,
          if (query != null) 'query': query,
          if (sort != null) 'sort': sort,
        },
      );
      final paged = PagedResult<SourceSeriesSummary>(
        items: (r.data!['items'] as List<dynamic>)
            .map(
              (e) => SourceSeriesSummary.fromJson(
                e as Map<String, dynamic>,
                _apiBaseUrl,
              ),
            )
            .toList(),
        total: r.data!['total'] as int,
        page: r.data!['page'] as int,
        perPage: r.data!['page_size'] as int,
        hasNext: r.data!['has_more'] as bool,
      );
      return Ok(paged);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<SourceSeriesSummary>> getSeries(
    String sourceId,
    String seriesId,
  ) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/sources/$sourceId/series/${Uri.encodeComponent(seriesId)}',
      );
      return Ok(SourceSeriesSummary.fromJson(r.data!, _apiBaseUrl));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<List<SourceChapterSummary>>> getChapters(
    String sourceId,
    String seriesId,
  ) async {
    try {
      final r = await _dio.get<List<dynamic>>(
        '/sources/$sourceId/series/${Uri.encodeComponent(seriesId)}/chapters',
      );
      final items = (r.data ?? [])
          .map((e) => SourceChapterSummary.fromJson(e as Map<String, dynamic>))
          .toList();
      return Ok(items);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<ReaderChapter>> getReaderChapter(
    String sourceId,
    String seriesId,
    String chapterId,
  ) async {
    try {
      // chapterId is appended raw so slash-bearing ids (e.g. toonily's
      // ``series/chapter-1``) match the backend ``:path`` route converter.
      final r = await _dio.get<Map<String, dynamic>>(
        '/sources/$sourceId/series/${Uri.encodeComponent(seriesId)}/chapters/$chapterId/reader',
      );
      return Ok(ReaderChapter.fromJson(r.data!, _apiBaseUrl));
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