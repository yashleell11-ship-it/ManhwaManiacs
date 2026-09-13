import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/settings/providers/settings_provider.dart';

/// Which client caches each 18+-gated backend service feeds.
///
/// This is the map the audit kept finding broken: the toggle dropped sources,
/// browse and search, and left the library shelf, bookmarks, updates and OCR
/// holding adult rows — on a `StatefulShellRoute.indexedStack` the Library tab
/// is never torn down while the reader is in Settings, so `autoDispose` does
/// not save it. Flipping the switch and handing over the phone showed the same
/// covers as before.
///
/// Every key must be in [kMatureGatedBackendServices] and every value must
/// appear in `matureScopedInvalidators`, so a new gated endpoint cannot be
/// added without deciding what it invalidates on the client.
const Map<String, List<String>> _providersByService = {
  'bookmark_service': ['bookmarksProvider'],
  'browse_service': [
    'sourceBrowseProvider',
    'sourceBrowseModesProvider',
    'searchListProvider',
  ],
  'followed_series_service': [
    'libraryListProvider',
    'seriesDetailProvider',
    'continueReadingProvider',
    'collectionsProvider',
    'collectionDetailProvider',
  ],
  'ocr_ingest_service': ['ocrSearchProvider', 'ocrCoverageProvider'],
  // Progress is written through the gate but never listed from it: every
  // screen that shows a reading position reads one of the other services.
  'progress_service': [],
  'reading_stats_service': [
    'statisticsProvider',
    'recommendationsProvider',
    'readingHistoryProvider',
  ],
  'source_cache_service': ['sourcesListProvider'],
  'source_pin_service': ['sourcePinsProvider'],
  'update_service': ['updatesProvider'],
};

/// The providers `matureScopedInvalidators` actually drops, read out of the
/// source: a `void Function(Ref)` cannot be asked what it invalidates.
Set<String> _declaredInvalidations() {
  final source =
      File('lib/features/settings/providers/settings_provider.dart')
          .readAsStringSync();
  final start = source.indexOf('matureScopedInvalidators = [');
  expect(start, isNot(-1), reason: 'the invalidator list was renamed');
  final end = source.indexOf('\n];', start);
  expect(end, isNot(-1), reason: 'the invalidator list is unterminated');
  final body = source.substring(start, end);
  return RegExp(r'ref\.invalidate\((\w+)\)')
      .allMatches(body)
      .map((match) => match.group(1)!)
      .toSet();
}

void main() {
  group('mature-gated invalidation', () {
    test('every gated backend service names the caches it feeds', () {
      expect(_providersByService.keys.toSet(), kMatureGatedBackendServices);
    });

    test('every named cache is actually invalidated on a toggle', () {
      final declared = _declaredInvalidations();
      for (final entry in _providersByService.entries) {
        for (final provider in entry.value) {
          expect(
            declared,
            contains(provider),
            reason: '${entry.key} is 18+-gated but $provider survives the '
                'toggle, so its screen keeps rendering the old answer',
          );
        }
      }
    });

    test('the invalidator list has no providers nobody claimed', () {
      final claimed = _providersByService.values.expand((e) => e).toSet();
      expect(
        _declaredInvalidations().difference(claimed),
        isEmpty,
        reason: 'an invalidator with no gated service behind it is either '
            'unnecessary or the service map is out of date',
      );
    });

    test('the audited service list still matches the backend', () {
      // Runs from `mobile/`; skipped in a checkout that has no backend.
      final services = Directory('../backend/services');
      if (!services.existsSync()) return;

      final gated = <String>{
        for (final entity in services.listSync())
          if (entity is File && entity.path.endsWith('.py'))
            if (entity.readAsStringSync().contains('content_rating'))
              entity.uri.pathSegments.last.replaceAll('.py', ''),
      };

      expect(
        gated,
        kMatureGatedBackendServices,
        reason: 'a service started (or stopped) filtering on the 18+ gate; '
            'decide which client caches it feeds before shipping it',
      );
    });
  });
}
