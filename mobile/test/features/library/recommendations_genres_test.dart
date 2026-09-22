/// The genre half of the Recommendations screen: every state its request can
/// be in, and pull-to-refresh.
///
/// The suggestions rewrite drew only the data case and nothing for the rest,
/// so loading, a failed request and an empty answer were all a blank space —
/// offline, the screen was a heading pointing at a section that never came,
/// with no error and no retry.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/models/recommendation.dart';
import 'package:manhwamaniacs/features/library/models/suggestion.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/library/screens/recommendations_screen.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

/// Answers `recommendations` from a queue, one entry per call, so a test can
/// script "fails, then works". The last entry repeats.
class _GenresRepository implements LibraryRepository {
  _GenresRepository(this.answers);

  final List<Result<List<RecommendationGenre>>> answers;
  int recommendationCalls = 0;
  int availabilityCalls = 0;
  int suggestCalls = 0;

  /// Set by a test that needs to see the loading state.
  Completer<void>? holdUntil;

  @override
  Future<Result<List<RecommendationGenre>>> recommendations({
    int limit = 10,
  }) async {
    final answer =
        answers[recommendationCalls.clamp(0, answers.length - 1)];
    recommendationCalls++;
    if (holdUntil != null) await holdUntil!.future;
    return answer;
  }

  // The box stays hidden, as it is offline or once the day's allowance is
  // spent — the case where the genres are the only thing on the screen.
  @override
  Future<Result<SuggestionAvailability>> suggestAvailability() async {
    availabilityCalls++;
    return const Ok(
      SuggestionAvailability(
        available: false,
        reason: 'budget_exhausted',
        remainingToday: 0,
      ),
    );
  }

  @override
  Future<Result<SuggestionResult>> suggest(String prompt, {int limit = 6}) {
    suggestCalls++;
    throw UnimplementedError('a pull must never ask for suggestions');
  }

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

const _offline = Err<List<RecommendationGenre>>(
  NetworkError(message: 'connection refused'),
);

/// What the reader is shown for [_offline] — `NetworkError.userMessage`.
const _offlineMessage = 'Network error — check your connection.';

void main() {
  testWidgets('shows chip placeholders while the genres load', (tester) async {
    final repo = _GenresRepository([
      const Ok([RecommendationGenre(genre: 'Action', weight: 5)]),
    ])
      ..holdUntil = Completer<void>();
    await tester.pumpWidget(await _wrap(repo));
    await tester.pump();

    expect(find.byKey(const Key('genres-loading')), findsOneWidget);

    repo.holdUntil!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('genres-loading')), findsNothing);
    expect(find.text('Action'), findsOneWidget);
  });

  testWidgets('a failed request says so and Retry loads the genres',
      (tester) async {
    final repo = _GenresRepository([
      _offline,
      const Ok([RecommendationGenre(genre: 'Murim', weight: 4)]),
    ]);
    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text(_offlineMessage), findsOneWidget);
    expect(find.text('Murim'), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Murim'), findsOneWidget);
    expect(find.text(_offlineMessage), findsNothing);
    expect(repo.recommendationCalls, 2);
  });

  testWidgets('no genres is an empty state with somewhere to go',
      (tester) async {
    final repo = _GenresRepository([const Ok(<RecommendationGenre>[])]);
    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('No recommendations yet'), findsOneWidget);
    // PrimaryPillButton uppercases its label.
    expect(find.text('BROWSE SOURCES'), findsOneWidget);
  });

  testWidgets('pull-to-refresh reloads genres and availability, never suggests',
      (tester) async {
    final repo = _GenresRepository([
      _offline,
      const Ok([RecommendationGenre(genre: 'Regression', weight: 3)]),
    ]);
    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();
    expect(find.text(_offlineMessage), findsOneWidget);
    final availabilityBefore = repo.availabilityCalls;

    await tester.fling(
      find.byType(ListView),
      const Offset(0, 400),
      1000,
    );
    await tester.pumpAndSettle();

    expect(find.text('Regression'), findsOneWidget);
    expect(repo.recommendationCalls, 2);
    expect(repo.availabilityCalls, greaterThan(availabilityBefore));
    expect(repo.suggestCalls, 0);
  });
}
