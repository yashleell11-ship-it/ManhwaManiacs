import 'dart:async';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Request header naming the build that sent a request.
const String appVersionHeader = 'X-App-Version';

/// `"<version>+<build>"`, the same spelling as `pubspec.yaml`'s `version:`,
/// or just the version when the platform reports no build number. `null`
/// with no version at all.
String? appVersionHeaderValue({
  required String version,
  required String buildNumber,
}) {
  final name = version.trim();
  final build = buildNumber.trim();
  if (name.isEmpty) return null;
  return build.isEmpty ? name : '$name+$build';
}

Future<String?>? _installedVersion;

/// This install's [appVersionHeaderValue], looked up once per process.
/// `null` when the platform cannot say.
Future<String?> installedAppVersion() =>
    _installedVersion ??= _lookUpInstalledVersion();

Future<String?> _lookUpInstalledVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return appVersionHeaderValue(
      version: info.version,
      buildNumber: info.buildNumber,
    );
  } catch (_) {
    return null;
  }
}

/// Stamps [appVersionHeader] on every request.
///
/// The server's access log is the only place a phone's build shows up after
/// the fact, and without this the only way to tell which build sent a request
/// was matching the size of the IPA it last downloaded — which is how a phone
/// still on a build without the Sources-reader push went unnoticed.
///
/// The lookup starts when the client is built, at app start, and a request is
/// never held for it: one sent before the platform has answered goes out
/// unstamped, as does every request if the platform never answers. A label
/// is worth a lot less than the request it would delay, and a platform
/// channel with nothing behind it would otherwise hold every request forever.
class AppVersionInterceptor extends Interceptor {
  AppVersionInterceptor({Future<String?> Function()? lookUpVersion}) {
    unawaited(_resolve(lookUpVersion ?? installedAppVersion));
  }

  String? _version;

  Future<void> _resolve(Future<String?> Function() lookUp) async {
    try {
      _version = await lookUp();
    } catch (_) {
      _version = null;
    }
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final version = _version;
    if (version != null) {
      options.headers.putIfAbsent(appVersionHeader, () => version);
    }
    handler.next(options);
  }
}
