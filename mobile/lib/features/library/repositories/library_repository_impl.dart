import 'package:dio/dio.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/models/collection.dart';
import 'package:manhwamaniacs/features/library/models/collection_detail.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/library_statistics.dart';
import 'package:manhwamaniacs/features/library/models/reading_history_item.dart';
import 'package:manhwamaniacs/features/library/models/recommendation.dart';
import 'package:manhwamaniacs/features/library/models/series_detail.dart';
import 'package:manhwamaniacs/features/library/models/suggestion.dart';
import 'package:manhwamaniacs/features/library/models/tag.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';

class LibraryRepositoryImpl implements LibraryRepository {
  const LibraryRepositoryImpl(this._dio);

  final Dio _dio;

  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? sort,
    String? search,
    String? readingStatus,
    bool? isFavorite,
  }) =>
      _request(
        () => _dio.get<Map<String, dynamic>>(
          '/library/series',
          queryParameters: {
            'page': page,
            'per_page': perPage,
            if (sort != null) 'sort': sort,
            if (search != null && search.isNotEmpty) 'search': search,
            if (readingStatus != null) 'reading_status': readingStatus,
            if (isFavorite != null) 'is_favorite': isFavorite,
          },
        ),
        (data) => PagedResult.fromJson(data, FollowedSeries.fromJson),
      );

  @override
  Future<Result<SeriesDetail>> getSeries(int followedId) => _request(
        () => _dio.get<Map<String, dynamic>>('/library/series/$followedId'),
        SeriesDetail.fromJson,
      );

  @override
  Future<Result<FollowedSeries>> follow({
    required String sourceId,
    required String seriesKey,
  }) =>
      _request(
        () => _dio.post<Map<String, dynamic>>(
          '/library/follow',
          data: {'source_id': sourceId, 'series_key': seriesKey},
        ),
        FollowedSeries.fromJson,
      );

  @override
  Future<Result<void>> unfollow(int followedId) async {
    try {
      await _dio.delete<void>('/library/follow/$followedId');
      return const Ok(null);
    } on DioException catch (e) {
      return Err(_extractError(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<FollowedSeries>> patchSeries(
    int followedId, {
    bool? isFavorite,
    String? readingStatus,
    bool? notify,
    bool? matureOverride,
    int? sortOrder,
  }) =>
      _request(
        () => _dio.patch<Map<String, dynamic>>(
          '/library/series/$followedId',
          data: {
            if (isFavorite != null) 'is_favorite': isFavorite,
            if (readingStatus != null) 'reading_status': readingStatus,
            if (notify != null) 'notify': notify,
            if (matureOverride != null) 'mature_override': matureOverride,
            if (sortOrder != null) 'sort_order': sortOrder,
          },
        ),
        FollowedSeries.fromJson,
      );

  @override
  Future<Result<List<ContinueReadingItem>>> continueReading({int limit = 10}) =>
      _requestList(
        () => _dio.get<List<dynamic>>(
          '/library/continue-reading',
          queryParameters: {'limit': limit},
        ),
        ContinueReadingItem.fromJson,
      );

  @override
  Future<Result<List<FollowedSeries>>> recentlyUpdated({int limit = 10}) =>
      _requestList(
        () => _dio.get<List<dynamic>>(
          '/library/recently-updated',
          queryParameters: {'limit': limit},
        ),
        FollowedSeries.fromJson,
      );

  @override
  Future<Result<List<RecommendationGenre>>> recommendations({int limit = 10}) =>
      _requestList(
        () => _dio.get<List<dynamic>>(
          '/library/recommendations',
          queryParameters: {'limit': limit},
        ),
        RecommendationGenre.fromJson,
      );

  @override
  Future<Result<SuggestionResult>> suggest(String prompt, {int limit = 6}) =>
      _request(
        () => _dio.post<Map<String, dynamic>>(
          '/library/suggest',
          data: {'prompt': prompt, 'limit': limit},
          // The server's own timeout is 180s (suggestion_service.TIMEOUT_
          // SECONDS — deepseek-flash bills its reasoning as output tokens
          // before any visible answer, so this is a genuinely slow call, not
          // a stuck one). This has to sit above that: a client timeout that
          // fires first wastes a request that was already paid for and still
          // running on the server.
          options: Options(receiveTimeout: const Duration(seconds: 210)),
        ),
        SuggestionResult.fromJson,
      );

  @override
  Future<Result<SuggestionAvailability>> suggestAvailability() => _request(
        () => _dio.get<Map<String, dynamic>>('/library/suggest/availability'),
        SuggestionAvailability.fromJson,
      );

  @override
  Future<Result<PagedResult<FollowedSeries>>> search(
    String query, {
    int page = 1,
    int perPage = 20,
  }) =>
      _request(
        () => _dio.get<Map<String, dynamic>>(
          '/library/search',
          queryParameters: {'q': query, 'page': page, 'per_page': perPage},
        ),
        (data) => PagedResult.fromJson(data, FollowedSeries.fromJson),
      );

  @override
  Future<Result<LibraryStatistics>> statistics() => _request(
        () => _dio.get<Map<String, dynamic>>(
          '/library/statistics',
          queryParameters: {
            // The server stores naive UTC and refuses to guess where a day
            // starts (`routes/library.py`); daily buckets, the hour histogram
            // and the streak are all cut at this offset. Without it a chapter
            // read at 11 PM IST lands on "tomorrow" and the streak breaks at
            // 05:30 instead of midnight. Clamped to the API's accepted range
            // (UTC-12:00..UTC+14:00, the range of real offsets) so a
            // mis-zoned device degrades to UTC-ish bucketing, not a 422.
            'tz_offset_minutes':
                DateTime.now().timeZoneOffset.inMinutes.clamp(-720, 840),
          },
        ),
        LibraryStatistics.fromJson,
      );

  @override
  Future<Result<List<ReadingHistoryItem>>> readingHistory({
    int limit = 50,
    int offset = 0,
    bool bySeries = true,
  }) =>
      _requestList(
        () => _dio.get<List<dynamic>>(
          '/reader/history',
          queryParameters: {
            'limit': limit,
            'offset': offset,
            // One row per BOOK. Forty chapters of one book is forty rows
            // otherwise, and the book before it lands on page two.
            if (bySeries) 'collapse': 'series',
          },
        ),
        ReadingHistoryItem.fromJson,
      );

  @override
  Future<Result<List<Collection>>> listCollections() => _requestList(
        () => _dio.get<List<dynamic>>('/library/collections'),
        Collection.fromJson,
      );

  @override
  Future<Result<CollectionDetail>> getCollection(int collectionId) => _request(
        () => _dio.get<Map<String, dynamic>>('/library/collections/$collectionId'),
        CollectionDetail.fromJson,
      );

  @override
  Future<Result<Collection>> createCollection({
    required String name,
    String? description,
  }) =>
      _request(
        () => _dio.post<Map<String, dynamic>>(
          '/library/collections',
          data: {
            'name': name,
            if (description != null && description.isNotEmpty) 'description': description,
          },
        ),
        Collection.fromJson,
      );

  @override
  Future<Result<Collection>> updateCollection(
    int collectionId, {
    String? name,
    String? description,
    int? sortOrder,
  }) =>
      _request(
        () => _dio.patch<Map<String, dynamic>>(
          '/library/collections/$collectionId',
          data: {
            if (name != null) 'name': name,
            if (description != null) 'description': description,
            if (sortOrder != null) 'sort_order': sortOrder,
          },
        ),
        Collection.fromJson,
      );

  @override
  Future<Result<void>> deleteCollection(int collectionId) async {
    try {
      await _dio.delete<void>('/library/collections/$collectionId');
      return const Ok(null);
    } on DioException catch (e) {
      return Err(_extractError(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<CollectionDetail>> addSeriesToCollection(
    int collectionId, {
    required String sourceId,
    required String seriesKey,
  }) =>
      _request(
        () => _dio.post<Map<String, dynamic>>(
          '/library/collections/$collectionId/series',
          data: {'source_id': sourceId, 'series_key': seriesKey},
        ),
        CollectionDetail.fromJson,
      );

  @override
  Future<Result<void>> removeSeriesFromCollection(
    int collectionId, {
    required String sourceId,
    required String seriesKey,
  }) async {
    try {
      await _dio.delete<void>(
        '/library/collections/$collectionId/series',
        data: {'source_id': sourceId, 'series_key': seriesKey},
      );
      return const Ok(null);
    } on DioException catch (e) {
      return Err(_extractError(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<List<Tag>>> listTags({String? category}) => _requestList(
        () => _dio.get<List<dynamic>>(
          '/library/tags',
          queryParameters: {if (category != null) 'category': category},
        ),
        Tag.fromJson,
      );

  @override
  Future<Result<Tag>> createTag({
    required String name,
    String category = 'custom',
    String? color,
  }) =>
      _request(
        () => _dio.post<Map<String, dynamic>>(
          '/library/tags',
          data: {
            'name': name,
            'category': category,
            if (color != null) 'color': color,
          },
        ),
        Tag.fromJson,
      );

  @override
  Future<Result<void>> deleteTag(int tagId) async {
    try {
      await _dio.delete<void>('/library/tags/$tagId');
      return const Ok(null);
    } on DioException catch (e) {
      return Err(_extractError(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<void>> addTagToSeries({
    required String sourceId,
    required String seriesKey,
    required int tagId,
  }) async {
    try {
      await _dio.post<void>(
        '/library/series-tags',
        data: {'source_id': sourceId, 'series_key': seriesKey, 'tag_id': tagId},
      );
      return const Ok(null);
    } on DioException catch (e) {
      return Err(_extractError(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<void>> removeTagFromSeries({
    required String sourceId,
    required String seriesKey,
    required int tagId,
  }) async {
    try {
      await _dio.delete<void>(
        '/library/series-tags',
        data: {'source_id': sourceId, 'series_key': seriesKey, 'tag_id': tagId},
      );
      return const Ok(null);
    } on DioException catch (e) {
      return Err(_extractError(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<Result<T>> _request<T>(
    Future<Response<Map<String, dynamic>>> Function() call,
    T Function(Map<String, dynamic>) fromJson,
  ) async {
    try {
      final response = await call();
      return Ok(fromJson(response.data!));
    } on DioException catch (e) {
      return Err(_extractError(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  Future<Result<List<T>>> _requestList<T>(
    Future<Response<List<dynamic>>> Function() call,
    T Function(Map<String, dynamic>) fromJson,
  ) async {
    try {
      final response = await call();
      final items = (response.data ?? [])
          .map((e) => fromJson(e as Map<String, dynamic>))
          .toList();
      return Ok(items);
    } on DioException catch (e) {
      return Err(_extractError(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  AppError _extractError(DioException e) {
    if (e.error is AppError) return e.error! as AppError;
    return UnknownError(message: e.message ?? 'Dio error', cause: e);
  }
}
