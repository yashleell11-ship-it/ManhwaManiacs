import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/network/dio_client.dart';
import 'package:manhwamaniacs/core/network/interceptors/app_version_interceptor.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Records every outgoing request and answers each with an empty 200.
class _CapturingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Server logs are the only record of which build a phone was on when it
/// made a request, so every request says.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('appVersionHeaderValue', () {
    test('is version+build, like pubspec', () {
      expect(
        appVersionHeaderValue(version: '3.4.2', buildNumber: '55'),
        '3.4.2+55',
      );
    });

    test('drops a missing build, and is null with no version', () {
      expect(appVersionHeaderValue(version: '3.4.2', buildNumber: ' '), '3.4.2');
      expect(appVersionHeaderValue(version: '', buildNumber: '55'), isNull);
    });
  });

  group('createDioClient', () {
    test('stamps X-App-Version on every request, looking it up once',
        () async {
      var lookups = 0;
      final adapter = _CapturingAdapter();
      final dio = createDioClient(
        baseUrl: 'https://example.test',
        lookUpAppVersion: () async {
          lookups++;
          return '3.4.2+55';
        },
      )..httpClientAdapter = adapter;
      await pumpEventQueue();

      await Future.wait([
        dio.get<dynamic>('/auth/me'),
        dio.get<dynamic>('/library/series'),
      ]);
      await dio.post<dynamic>('/reader/progress/batch', data: <Object>[]);

      expect(adapter.requests, hasLength(3));
      for (final request in adapter.requests) {
        expect(request.headers[appVersionHeader], '3.4.2+55');
      }
      expect(lookups, 1);
    });

    test('a lookup that fails still lets the request through, unlabelled',
        () async {
      final adapter = _CapturingAdapter();
      final dio = createDioClient(
        baseUrl: 'https://example.test',
        lookUpAppVersion: () async => throw StateError('no plugin'),
      )..httpClientAdapter = adapter;
      await pumpEventQueue();

      await dio.get<dynamic>('/health');

      expect(
        adapter.requests.single.headers.containsKey(appVersionHeader),
        isFalse,
      );
    });

    test('a lookup still pending never holds a request back', () async {
      final answer = Completer<String?>();
      final adapter = _CapturingAdapter();
      final dio = createDioClient(
        baseUrl: 'https://example.test',
        lookUpAppVersion: () => answer.future,
      )..httpClientAdapter = adapter;

      await dio.get<dynamic>('/auth/me');
      expect(
        adapter.requests.single.headers.containsKey(appVersionHeader),
        isFalse,
      );

      answer.complete('3.4.2+55');
      await pumpEventQueue();
      await dio.get<dynamic>('/library/series');
      expect(adapter.requests.last.headers[appVersionHeader], '3.4.2+55');
    });

    test('by default the installed build is what is sent', () async {
      PackageInfo.setMockInitialValues(
        appName: 'ManhwaManiacs',
        packageName: 'xyz.manhwamaniacs.app',
        version: '3.4.2',
        buildNumber: '55',
        buildSignature: '',
      );
      final adapter = _CapturingAdapter();
      final dio = createDioClient(baseUrl: 'https://example.test')
        ..httpClientAdapter = adapter;
      await pumpEventQueue();

      await dio.get<dynamic>('/auth/me');

      expect(adapter.requests.single.headers[appVersionHeader], '3.4.2+55');
    });
  });
}
