import 'package:dio/dio.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/models/update_settings.dart';
import 'package:manhwamaniacs/features/updates/repositories/updates_repository.dart';

class UpdatesRepositoryImpl implements UpdatesRepository {
  const UpdatesRepositoryImpl(this._dio);

  final Dio _dio;

  @override
  Future<Result<UpdateSettings>> getSettings() async {
    try {
      final r = await _dio.get<Map<String, dynamic>>('/updates/settings');
      return Ok(UpdateSettings.fromJson(r.data!));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<UpdateSettings>> updateSettings({
    bool? enabled,
    int? checkIntervalMinutes,
    bool? notifyEnabled,
    bool? checkOnStartup,
  }) async {
    try {
      final r = await _dio.put<Map<String, dynamic>>(
        '/updates/settings',
        data: {
          if (enabled != null) 'enabled': enabled,
          if (checkIntervalMinutes != null)
            'check_interval_minutes': checkIntervalMinutes,
          if (notifyEnabled != null) 'notify_enabled': notifyEnabled,
          if (checkOnStartup != null) 'check_on_startup': checkOnStartup,
        },
      );
      return Ok(UpdateSettings.fromJson(r.data!));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<List<UpdateNotification>>> listNotifications({
    bool unreadOnly = false,
    int limit = 100,
  }) async {
    try {
      final r = await _dio.get<List<dynamic>>(
        '/updates/notifications',
        queryParameters: {
          if (unreadOnly) 'unread_only': true,
          'limit': limit,
        },
      );
      final items = (r.data ?? [])
          .map((e) => UpdateNotification.fromJson(e as Map<String, dynamic>))
          .toList();
      return Ok(items);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<int>> getUnreadCount() async {
    try {
      final r = await _dio.get<Map<String, dynamic>>('/updates/notifications/unread-count');
      return Ok(r.data!['count'] as int);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<void>> markRead(int notificationId) async {
    try {
      await _dio.patch<void>('/updates/notifications/$notificationId/read');
      return const Ok(null);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<void>> markAllRead({String? contentKind}) async {
    try {
      await _dio.post<void>(
        '/updates/notifications/read-all',
        data: contentKind == null ? null : {'content_kind': contentKind},
      );
      return const Ok(null);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<List<UpdateRun>>> listRuns({int limit = 20}) async {
    try {
      final r = await _dio.get<List<dynamic>>(
        '/updates/runs',
        queryParameters: {'limit': limit},
      );
      final items = (r.data ?? [])
          .map((e) => UpdateRun.fromJson(e as Map<String, dynamic>))
          .toList();
      return Ok(items);
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<UpdateCheckOutcome>> triggerCheck({List<int>? followedIds}) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/updates/check',
        data: {if (followedIds != null) 'followed_ids': followedIds},
      );
      final data = r.data!;
      if (data['queued'] == true) {
        return const Ok(UpdateCheckOutcome(queued: true));
      }
      return Ok(UpdateCheckOutcome(queued: false, run: UpdateRun.fromJson(data)));
    } on DioException catch (e) {
      return Err(_err(e));
    } catch (e) {
      return Err(UnknownError(message: e.toString(), cause: e));
    }
  }

  @override
  Future<Result<UpdateRun>> checkFollowed(int followedId) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/updates/followed/$followedId/check',
      );
      return Ok(UpdateRun.fromJson(r.data!));
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
