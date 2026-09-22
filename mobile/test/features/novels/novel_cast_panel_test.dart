/// The Voices sheet: what an unpinned character is called, what un-pinning
/// sends, and what a refused change says.
///
/// Unpinned characters are NOT read by the narrator — the renderer gives each
/// one an automatic voice — so the sheet must never call them "narrator". And
/// changing a voice is an owner's decision: a reader who is refused has to be
/// told so, in the server's words, rather than watching nothing happen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/app/theme/app_theme.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/novels/models/novel_cast.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_cast_provider.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_cast_panel.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_chapter_view.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

import 'support/fake_novels_repository.dart';

const _chapter = (sourceId: 'novelbin', seriesKey: 'tbate', chapterKey: 'c1');

const _atlas = NovelVoice(
  voiceId: 'libritts-2803',
  name: 'Atlas',
  character: 'deep, steady',
  gender: 'male',
  pitchHz: 103,
  seconds: 19,
);

const _surface = NovelSurfaceColors(
  bg: Colors.white,
  ink: Colors.black,
  muted: Colors.grey,
  isDark: false,
);

Future<FakeNovelsRepository> _pump(
  WidgetTester tester, {
  required List<NovelCastMember> cast,
  FakeNovelsRepository? repository,
}) async {
  final repo = repository ?? FakeNovelsRepository();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        novelsRepositoryProvider.overrideWithValue(repo),
        novelVoicesProvider.overrideWith((ref) async => const [_atlas]),
        novelAttributionProvider(_chapter).overrideWith(
          (ref) async => NovelAttribution(
            attributed: true,
            narrator: null,
            narratorVoiceId: null,
            cast: cast,
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.fromPalette(AppPalettes.defaultPalette),
        home: const Scaffold(
          body: NovelCastPanel(chapter: _chapter, surface: _surface),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('an unpinned character reads as Automatic, never narrator',
      (tester) async {
    await _pump(
      tester,
      cast: const [
        NovelCastMember(name: 'Arthur', gender: 'male', voiceId: null),
      ],
    );

    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('narrator'), findsNothing);
  });

  testWidgets('choosing Automatic voice sends an explicit null for that name',
      (tester) async {
    final repo = await _pump(
      tester,
      cast: const [
        NovelCastMember(
          name: 'Arthur',
          gender: 'male',
          voiceId: 'libritts-2803',
        ),
      ],
    );
    // Pinned, so the row names the voice rather than "Automatic".
    expect(find.text('Atlas'), findsOneWidget);

    await tester.tap(find.text('Arthur'));
    await tester.pumpAndSettle();
    expect(find.text('Automatic voice'), findsOneWidget);
    expect(find.text('Read as narrator'), findsNothing);

    // The first "Use" is the Automatic row: Atlas is already chosen.
    await tester.tap(find.text('Use').first);
    await tester.pumpAndSettle();

    expect(repo.castWrites, [(name: 'Arthur', voiceId: null)]);
  });

  testWidgets("a refused change shows the server's message", (tester) async {
    final repo = FakeNovelsRepository()
      ..setCastVoiceResult = const Err(adminRequired);
    await _pump(
      tester,
      repository: repo,
      cast: const [
        NovelCastMember(name: 'Arthur', gender: 'male', voiceId: null),
      ],
    );

    await tester.tap(find.text('Arthur'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use').first); // Atlas
    await tester.pumpAndSettle();

    expect(repo.castWrites, [(name: 'Arthur', voiceId: 'libritts-2803')]);
    expect(
      find.text(
        'That voice could not be saved. Administrator access required.',
      ),
      findsOneWidget,
    );
    // Still open on the choice that did not stick, not closed as if it had.
    expect(find.text('Automatic voice'), findsOneWidget);
  });

  test('the writer answers with the error, and null when it stuck', () async {
    final repo = FakeNovelsRepository()
      ..setCastVoiceResult = const Err(adminRequired);
    final container = ProviderContainer(
      overrides: [novelsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    final writer = container.read(novelVoiceWriterProvider);

    final refused = await writer.setCharacter(_chapter, 'Arthur', null);
    expect(refused?.userMessage, 'Administrator access required.');

    repo.setCastVoiceResult = const Ok(null);
    expect(await writer.setCharacter(_chapter, 'Arthur', null), isNull);
  });
}
