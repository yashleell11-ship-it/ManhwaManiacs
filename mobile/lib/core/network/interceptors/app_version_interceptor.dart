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

/// [installedAppVersion]'s answer, readable without waiting once it is in.
String? _installedVersionAnswer;

/// This install's [appVersionHeaderValue], looked up once per process.
/// `null` when the platform cannot say.
Future<String?> installedAppVersion() =>
    _installedVersion ??= _lookUpInstalledVersion();

/// Starts [installedAppVersion] without waiting for it.
///
/// Called from `main` before the first request can be made: the lookup is a
/// platform round trip, and a client built before it answers sends its first
/// requests unlabelled. Never throws, and never holds anything up.
void startAppVersionLookup() {
  unawaited(installedAppVersion());
}

Future<String?> _lookUpInstalledVersion() async {
  String? version;
  try {
    final info = await PackageInfo.fromPlatform();
    version = appVersionHeaderValue(
      version: info.version,
      buildNumber: info.buildNumber,
    );
  } catch (_) {
    // The platform cannot say: requests go out unlabelled.
  }
  return _installedVersionAnswer = version;
}

/// Stamps [appVersionHeader] on every request.
///
/// The server's access log is the only place a phone's build shows up after
/// the fact, and without this the only way to tell which build sent a request
/// was matching the size of the IPA it last downloaded — which is how a phone
/// still on a build without the Sources-reader push went unnoticed.
///
/// `main` starts the lookup ([startAppVersionLookup]) before the first
/// request can be made, and a client built after it has answered stamps its
/// very first request. A request is never held for it: one sent before the
/// platform has answered goes out unstamped, as does every request if the
/// platform never answers. A label is worth a lot less than the request it
/// would delay, and a platform channel with nothing behind it would otherwise
/// hold every request forever.
class AppVersionInterceptor extends Interceptor {
  AppVersionInterceptor({Future<String?> Function()? lookUpVersion})
      : _version = lookUpVersion == null ? _installedVersionAnswer : null {
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
