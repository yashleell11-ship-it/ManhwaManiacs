import 'package:dio/dio.dart';
import 'package:manhwamaniacs/core/config/env.dart';
import 'package:manhwamaniacs/core/network/interceptors/app_version_interceptor.dart';
import 'package:manhwamaniacs/core/network/interceptors/auth_interceptor.dart';
import 'package:manhwamaniacs/core/network/interceptors/error_interceptor.dart';
import 'package:manhwamaniacs/core/network/interceptors/logging_interceptor.dart';

/// Factory that constructs a fully-configured Dio instance.
///
/// [baseUrl] defaults to the compile-time default from [Env.defaultApiUrl]
/// but can be overridden at runtime (user sets their server address).
///
/// [authInterceptor], when supplied, attaches the bearer token and reacts to
/// session-expiry (401). It is added first so it can inspect the 401 before
/// [ErrorInterceptor] maps and rejects the error. The throwaway client used to
/// validate a server URL omits it (that probe only hits the public `/health`).
///
/// Every request carries the app's build as `X-App-Version`
/// ([AppVersionInterceptor]); [lookUpAppVersion] replaces the platform lookup
/// in tests.
Dio createDioClient({
  String? baseUrl,
  AuthInterceptor? authInterceptor,
  Future<String?> Function()? lookUpAppVersion,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl ?? Env.defaultApiUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 15),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    ),
  );

  dio.interceptors.addAll([
    AppVersionInterceptor(lookUpVersion: lookUpAppVersion),
    if (authInterceptor != null) authInterceptor,
    if (Env.isDev) LoggingInterceptor(),
    ErrorInterceptor(),
  ]);

  return dio;
}
