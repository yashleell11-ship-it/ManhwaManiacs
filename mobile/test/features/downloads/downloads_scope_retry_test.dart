import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/services/blob_store.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite/sqflite.dart';

class _Db extends Mock implements Database {}

/// The database and blob tree are opened by keep-alive providers. A failed
/// open used to be cached for the whole process — every save after one slow
/// cold start threw before reaching the network. It must be retried instead.
void main() {
  group('downloadsDatabaseProvider', () {
    test('a failed open is not kept: the next read opens again', () async {
      final db = _Db();
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          downloadsDatabaseOpenerProvider.overrideWithValue(() async {
            attempts++;
            if (attempts == 1) throw StateError('disk not ready');
            return db;
          }),
        ],
      );
      addTearDown(container.dispose);

      final first = container.read(downloadsDatabaseProvider);
      await expectLater(first, throwsStateError);
      await pumpEventQueue();

      final second = container.read(downloadsDatabaseProvider);
      expect(second, isNot(same(first)));
      expect(await second, same(db));
      expect(attempts, 2);
    });

    test('a successful open is kept for the life of the process', () async {
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          downloadsDatabaseOpenerProvider.overrideWithValue(() async {
            attempts++;
            return _Db();
          }),
        ],
      );
      addTearDown(container.dispose);

      final first = container.read(downloadsDatabaseProvider);
      await first;
      await pumpEventQueue();

      expect(container.read(downloadsDatabaseProvider), same(first));
      expect(attempts, 1);
    });

    testWidgets('an open that times out is retried on the next read',
        (tester) async {
      final hung = Completer<Database>();
      final db = _Db();
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          downloadsDatabaseOpenerProvider.overrideWithValue(() {
            attempts++;
            return attempts == 1 ? hung.future : Future.value(db);
          }),
        ],
      );
      addTearDown(container.dispose);

      final first = container.read(downloadsDatabaseProvider);
      Object? error;
      unawaited(first.then<void>((_) {}, onError: (Object e) => error = e));
      await tester.pump(const Duration(seconds: 4));
      expect(error, isA<TimeoutException>());

      final second = container.read(downloadsDatabaseProvider);
      expect(second, isNot(same(first)));
      expect(await second, same(db));
    });

    testWidgets('an open that keeps failing backs off instead of retrying '
        'on every read', (tester) async {
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          downloadsDatabaseOpenerProvider.overrideWithValue(() {
            attempts++;
            return Future.error(StateError('corrupt'));
          }),
        ],
      );

      Future<void> readAndFail() async {
        final opening = container.read(downloadsDatabaseProvider);
        unawaited(opening.then<void>((_) {}, onError: (Object _) {}));
        await tester.pump();
      }

      await readAndFail(); // attempt 1, retried at once
      await readAndFail(); // attempt 2, next retry in 1 s
      await readAndFail();
      await readAndFail();
      expect(attempts, 2);

      await tester.pump(const Duration(seconds: 1));
      await readAndFail(); // attempt 3, next retry in 2 s
      expect(attempts, 3);
      await tester.pump(const Duration(seconds: 1));
      await readAndFail();
      expect(attempts, 3);
      await tester.pump(const Duration(seconds: 1));
      await readAndFail();
      expect(attempts, 4);

      // Disposing cancels the retry still scheduled.
      container.dispose();
    });

    test('a store built on a failed open is rebuilt on the retried one',
        () async {
      final db = _Db();
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          activeDownloadsScopeIdProvider.overrideWithValue('u1p1'),
          downloadsDatabaseOpenerProvider.overrideWithValue(() async {
            attempts++;
            if (attempts == 1) throw StateError('disk not ready');
            return db;
          }),
          blobStoreOpenerProvider.overrideWithValue(
            () async => BlobStore(rootDirectory: Directory.systemTemp),
          ),
        ],
      );
      addTearDown(container.dispose);

      final broken = container.read(downloadsStoreProvider)!;
      await expectLater(broken.database, throwsStateError);
      await pumpEventQueue();

      final rebuilt = container.read(downloadsStoreProvider)!;
      expect(rebuilt, isNot(same(broken)));
      expect(await rebuilt.database, same(db));
    });
  });

  group('blobStoreProvider', () {
    test('a failed lookup is not kept: the next read looks again', () async {
      final blobs = BlobStore(rootDirectory: Directory.systemTemp);
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          blobStoreOpenerProvider.overrideWithValue(() async {
            attempts++;
            if (attempts == 1) throw const FileSystemException('no documents');
            return blobs;
          }),
        ],
      );
      addTearDown(container.dispose);

      final first = container.read(blobStoreProvider);
      await expectLater(first, throwsA(isA<FileSystemException>()));
      await pumpEventQueue();

      expect(await container.read(blobStoreProvider), same(blobs));
      expect(attempts, 2);
    });
  });
}
