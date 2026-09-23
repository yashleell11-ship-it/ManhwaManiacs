import 'dart:async';
import 'dart:io' show File;
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

  group('startAppVersionLookup', () {
    test('a client built after the lookup has answered labels its very first '
        'request', () async {
      PackageInfo.setMockInitialValues(
        appName: 'ManhwaManiacs',
        packageName: 'xyz.manhwamaniacs.app',
        version: '3.4.2',
        buildNumber: '55',
        buildSignature: '',
      );
      startAppVersionLookup();
      await installedAppVersion();

      // Straight into the interceptor, with no turn of the event loop in
      // between for its own copy of the lookup to land.
      final options = RequestOptions(path: '/auth/me');
      AppVersionInterceptor().onRequest(options, RequestInterceptorHandler());

      expect(options.headers[appVersionHeader], '3.4.2+55');
    });

    test('main starts it before it awaits anything or runs the app', () {
      // Read relative to mobile/, where `flutter test` runs.
      final source = File('lib/main.dart').readAsStringSync();
      final body = source.substring(source.indexOf('Future<void> main()'));
      final started = body.indexOf('startAppVersionLookup();');

      expect(started, isNonNegative);
      expect(started, lessThan(body.indexOf('await ')));
      expect(started, lessThan(body.indexOf('runApp(')));
    });
  });

  testWidgets('a lookup that never answers leaves no timer behind in a '
      'fake-async test', (tester) async {
    final options = RequestOptions(path: '/auth/me');
    AppVersionInterceptor(lookUpVersion: () => Completer<String?>().future)
        .onRequest(options, RequestInterceptorHandler());
    await tester.pump();

    expect(options.headers.containsKey(appVersionHeader), isFalse);
    // testWidgets itself fails a test that ends with a timer still pending.
  });
}
