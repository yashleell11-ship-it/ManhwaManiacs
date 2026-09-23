import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/sources/models/source.dart';
import 'package:manhwamaniacs/features/sources/models/source_pin.dart';
import 'package:manhwamaniacs/features/sources/providers/source_pins_provider.dart';
import 'package:manhwamaniacs/features/sources/repositories/sources_repository.dart';
import 'package:manhwamaniacs/features/sources/utils/source_pins_cache.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

/// Behaves like `PUT /sources/pins` on a scope with no rows yet: a new id the
/// server cannot resolve refuses the whole set with a 422.
class _FakePinServer implements SourcesRepository {
  _FakePinServer(this.installed);

  final Set<String> installed;
  List<SourcePin> stored = const [];
  bool listSourcesFails = false;
  bool refuseWrites = false;
  final List<List<String>> writes = [];

  @override
  Future<Result<List<SourceSummary>>> listSources() async {
    if (listSourcesFails) {
      return const Err(NetworkError(message: 'offline'));
    }
    return Ok([
      for (final id in installed)
        SourceSummary(
          id: id,
          name: id,
          description: '',
          browsable: true,
          supportsImport: false,
        ),
    ]);
  }

  @override
  Future<Result<List<SourcePin>>> listPins() async => Ok(stored);

  @override
  Future<Result<List<SourcePin>>> replacePins(List<String> sourceIds) async {
    writes.add(List.of(sourceIds));
    final unknown = sourceIds.where((id) => !installed.contains(id)).toList();
    if (refuseWrites || unknown.isNotEmpty) {
      return const Err(
        ApiError(statusCode: 422, code: 'unknown_source', message: 'Unknown source.'),
      );
    }
    stored = [
      for (var i = 0; i < sourceIds.length; i++)
        SourcePin(sourceId: sourceIds[i], sortOrder: i, name: sourceIds[i]),
    ];
    return Ok(stored);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ProviderContainer, SharedPreferences)> makeContainer(
    _FakePinServer server, {
    required List<String> legacy,
  }) async {
    SharedPreferences.setMockInitialValues({legacyPinnedSourcesKey: legacy});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        sourcesRepositoryProvider.overrideWithValue(server),
        authenticatedAuthOverride(),
        activeProfileOverride(),
      ],
    );
    addTearDown(container.dispose);
    return (container, prefs);
  }

  group('legacy device pin migration', () {
    test('a removed connector in the old list does not lose the other pins',
        () async {
      final server = _FakePinServer({'asura', 'mangadex', 'toonily'});
      final (container, prefs) = await makeContainer(
        server,
        legacy: ['asura', 'weebcentral', 'mangadex', 'coffeemanga'],
      );

      final state = await container.read(sourcePinsProvider.future);

      expect(server.writes, [
        ['asura', 'mangadex'],
      ]);
      expect(state.ids, ['asura', 'mangadex']);
      expect(state.synced, isTrue);
      expect(sourcePinsMigrated(prefs), isTrue);
      expect(readLegacyPinnedSources(prefs), isEmpty);
    });

    test('a refused list leaves the migration open for the next launch',
        () async {
      final server = _FakePinServer({'asura', 'mangadex'})..refuseWrites = true;
      final (container, prefs) = await makeContainer(
        server,
        legacy: ['asura', 'mangadex'],
      );

      final first = await container.read(sourcePinsProvider.future);

      expect(first.ids, isEmpty);
      expect(sourcePinsMigrated(prefs), isFalse);
      expect(readLegacyPinnedSources(prefs), ['asura', 'mangadex']);

      // Next launch, the server accepts: the pins arrive after all.
      server.refuseWrites = false;
      container.invalidate(sourcePinsProvider);
      final second = await container.read(sourcePinsProvider.future);

      expect(second.ids, ['asura', 'mangadex']);
      expect(sourcePinsMigrated(prefs), isTrue);
    });

    test('an unreachable source list does not burn the migration', () async {
      final server = _FakePinServer({'asura'})..listSourcesFails = true;
      final (container, prefs) = await makeContainer(server, legacy: ['asura']);

      await container.read(sourcePinsProvider.future);

      expect(server.writes, isEmpty);
      expect(sourcePinsMigrated(prefs), isFalse);
      expect(readLegacyPinnedSources(prefs), ['asura']);
    });

    test('an old list of only removed connectors closes without a write',
        () async {
      final server = _FakePinServer({'asura'});
      final (container, prefs) = await makeContainer(
        server,
        legacy: ['weebcentral', 'coffeemanga'],
      );

      final state = await container.read(sourcePinsProvider.future);

      expect(server.writes, isEmpty);
      expect(state.ids, isEmpty);
      expect(sourcePinsMigrated(prefs), isTrue);
    });
  });
}
