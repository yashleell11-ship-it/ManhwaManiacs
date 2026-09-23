/// Search and suggestion cards paint the backend's RELATIVE cover path
/// resolved against the app's own API base.
///
/// The backend used to hand these back absolute, built from the host it was
/// reached on — which behind Caddy is plain http, so every cover request
/// carried the bearer token in clear text before the redirect to https.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/network/interceptors/auth_interceptor.dart';
import 'package:manhwamaniacs/features/library/models/global_search_result.dart';
import 'package:manhwamaniacs/features/library/widgets/search/global_search_result_card.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';

import '../../support/test_overrides.dart';

const _apiBase = 'https://app.example.test';
const _relative = '/sources/asurascans/series/nano-machine/cover';

GlobalSearchItem _item(String? coverUrl) => GlobalSearchItem(
      kind: 'source',
      source: 'asurascans',
      seriesId: 'nano-machine',
      title: 'Nano Machine',
      coverUrl: coverUrl,
    );

Future<String> _paintedUrl(WidgetTester tester, Widget card) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiBaseUrlOverride(_apiBase),
        authTokenStoreProvider
            .overrideWithValue(AuthTokenStore()..token = 'secret-token'),
        activeProfileOverride(),
      ],
      child: MaterialApp(
        home: Scaffold(body: SizedBox(width: 400, height: 260, child: card)),
      ),
    ),
  );
  await tester.pump();
  return tester
      .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
      .imageUrl;
}

void main() {
  testWidgets('list card resolves a relative cover against the API base',
      (tester) async {
    final url = await _paintedUrl(
      tester,
      GlobalSearchResultCard(item: _item(_relative), onTap: () {}),
    );

    expect(url, startsWith('$_apiBase$_relative'));
  });

  testWidgets('grid card resolves a relative cover against the API base',
      (tester) async {
    final url = await _paintedUrl(
      tester,
      GlobalSearchResultGridCard(
        item: _item(_relative),
        coverWidth: 120,
        onTap: () {},
      ),
    );

    expect(url, startsWith('$_apiBase$_relative'));
  });

  testWidgets('an already-absolute cover is not resolved twice',
      (tester) async {
    // What a retried section carries: the source listing resolves its own.
    const absolute = '$_apiBase$_relative';
    final url = await _paintedUrl(
      tester,
      GlobalSearchResultCard(item: _item(absolute), onTap: () {}),
    );

    expect(url, startsWith(absolute));
    expect(url, isNot(contains('$_apiBase$_apiBase')));
  });
}
