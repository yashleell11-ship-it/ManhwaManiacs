/// AI suggestions on the Recommendations screen.
///
/// Two behaviours here are load-bearing and neither is obvious from the code:
///
/// * **Nothing is ever asked for on mount.** One suggestion is one paid API
///   call on the server. A `FutureProvider` here — the shape every other
///   provider on this screen uses — would spend money every time the screen
///   rebuilt, and again on every pull-to-refresh.
/// * **An unconfigured server hides the box** rather than offering a button
///   that fails when somebody finally types a sentence into it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/models/global_search_result.dart';
import 'package:manhwamaniacs/features/library/models/recommendation.dart';
import 'package:manhwamaniacs/features/library/models/suggestion.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/library/screens/recommendations_screen.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:manhwamaniacs/shared/widgets/premium/primary_pill_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

class _SuggestRepository implements LibraryRepository {
  _SuggestRepository({this.available = true, this.dropped = 0});

  final bool available;
  final int dropped;

  int suggestCalls = 0;
  int availabilityCalls = 0;
  String? lastPrompt;

  /// Set by a test that needs to act WHILE a suggest() is still in flight —
  /// the disposal race only exists in that window.
  Completer<void>? holdUntil;

  @override
  Future<Result<SuggestionResult>> suggest(String prompt, {int limit = 6}) async {
    suggestCalls++;
    lastPrompt = prompt;
    if (holdUntil != null) await holdUntil!.future;
    return Ok(
      SuggestionResult(
        items: [
          Suggestion(
            item: const GlobalSearchItem(
              kind: 'source',
              source: 'asurascans',
              seriesId: 'nano-machine',
              title: 'Nano Machine',
            ),
            why: 'Murim and a weak-to-strong lead, like the ones you finished.',
          ),
        ],
        dropped: dropped,
        remainingToday: 41,
        model: 'deepseek-flash',
      ),
    );
  }

  @override
  Future<Result<SuggestionAvailability>> suggestAvailability() async {
    availabilityCalls++;
    return Ok(
      SuggestionAvailability(
        available: available,
        reason: available ? 'ok' : 'not_configured',
        remainingToday: available ? 42 : 0,
      ),
    );
  }

  @override
  Future<Result<List<RecommendationGenre>>> recommendations({int limit = 10}) async =>
      const Ok([RecommendationGenre(genre: 'martial arts', weight: 9)]);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

Future<Widget> _wrap(LibraryRepository repo) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      apiBaseUrlOverride('http://127.0.0.1:8000'),
      sharedPrefsProvider.overrideWithValue(prefs),
      libraryRepositoryProvider.overrideWithValue(repo),
      ...contentModeOverrides(),
    ],
    child: const MaterialApp(home: RecommendationsScreen()),
  );
}

void main() {
  testWidgets('nothing is suggested until the reader asks', (tester) async {
    // The money test. Mounting the screen must cost nothing.
    final repo = _SuggestRepository();
    await tester.pumpWidget(await _wrap(repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(repo.availabilityCalls, 1, reason: 'availability is free');
    expect(repo.suggestCalls, 0, reason: 'a suggestion is a paid API call');
  });

  testWidgets('describing something asks for it once', (tester) async {
    final repo = _SuggestRepository();
    await tester.pumpWidget(await _wrap(repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), 'murim regressor');
    // The screen is a ListView and the button sits below the fold in a
    // test viewport; tapping an off-screen widget silently misses.
    await tester.ensureVisible(find.text('SUGGEST SOMETHING'));
    await tester.pump();
    await tester.tap(find.text('SUGGEST SOMETHING'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(repo.suggestCalls, 1);
    expect(repo.lastPrompt, 'murim regressor');
    expect(find.text('Nano Machine'), findsOneWidget);
  });

  testWidgets('the reason is shown, not just the title', (tester) async {
    // A card that only names a book is a search result. The reason is the
    // entire difference between a suggestion and a list.
    final repo = _SuggestRepository();
    await tester.pumpWidget(await _wrap(repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), 'murim');
    // The screen is a ListView and the button sits below the fold in a
    // test viewport; tapping an off-screen widget silently misses.
    await tester.ensureVisible(find.text('SUGGEST SOMETHING'));
    await tester.pump();
    await tester.tap(find.text('SUGGEST SOMETHING'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('Murim and a weak-to-strong lead, like the ones you finished.'),
      findsOneWidget,
    );
  });

  testWidgets('titles nothing carries are reported, never rendered',
      (tester) async {
    final repo = _SuggestRepository(dropped: 2);
    await tester.pumpWidget(await _wrap(repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), 'murim');
    // The screen is a ListView and the button sits below the fold in a
    // test viewport; tapping an off-screen widget silently misses.
    await tester.ensureVisible(find.text('SUGGEST SOMETHING'));
    await tester.pump();
    await tester.tap(find.text('SUGGEST SOMETHING'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.textContaining('2 more suggestions skipped'),
      findsOneWidget,
    );
  });

  testWidgets('an unconfigured server hides the box instead of failing',
      (tester) async {
    final repo = _SuggestRepository(available: false);
    await tester.pumpWidget(await _wrap(repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(TextField), findsNothing);
    // PrimaryPillButton uppercases its label.
    expect(find.text('SUGGEST SOMETHING'), findsNothing);
    // The genre chips are the fallback, and they still work.
    expect(find.text('martial arts'), findsOneWidget);
  });

  testWidgets('the button is dead for a prompt too short to spend on',
      (tester) async {
    // The notifier silently refuses anything under 3 characters -- no state
    // change, no error. A live-looking button over that silence is a tap
    // that does nothing and explains nothing, so this asserts the button is
    // actually non-interactive, not merely that nothing happens when pressed.
    final repo = _SuggestRepository();
    await tester.pumpWidget(await _wrap(repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final button = find.byType(PrimaryPillButton);
    await tester.ensureVisible(button);

    expect(tester.widget<PrimaryPillButton>(button).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'ok');
    await tester.pump();
    expect(tester.widget<PrimaryPillButton>(button).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'murim');
    await tester.pump();
    expect(tester.widget<PrimaryPillButton>(button).onPressed, isNotNull);
  });

  testWidgets(
      'leaving the screen mid-request does not throw when the answer lands',
      (tester) async {
    // The longest request in the app (the model reasons before it answers),
    // held by a provider whose only listener is this screen. Popping while
    // it is in flight must not crash when the future finally resolves.
    final repo = _SuggestRepository()..holdUntil = Completer<void>();
    await tester.pumpWidget(await _wrap(repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), 'murim regressor');
    final button = find.byType(PrimaryPillButton);
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await tester.pump();
    expect(repo.suggestCalls, 1);

    // Tear the screen down while suggest() is still awaiting holdUntil.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    // Now let the held request resolve. If SuggestionsNotifier writes to
    // `state` or calls `ref.invalidate` after disposal, this throws.
    repo.holdUntil!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
  });
}
