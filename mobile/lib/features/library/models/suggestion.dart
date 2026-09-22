import 'package:manhwamaniacs/features/library/models/global_search_result.dart';

/// One AI suggestion: a series this server can actually open, plus why.
///
/// [item] is a plain [GlobalSearchItem], deliberately — the server picks every
/// suggestion out of its own catalog cache, so a suggestion is the same kind of
/// handle a search hit is and opens through the same route. Titles the model
/// named that are not in that cache never reach here; the server counts them
/// in [SuggestionResult.dropped] and drops them, because a card that cannot be
/// opened is worse than one fewer card.
class Suggestion {
  const Suggestion({required this.item, required this.why});

  final GlobalSearchItem item;

  /// The model's one line about why this fits. May be empty.
  final String why;

  factory Suggestion.fromJson(Map<String, dynamic> json) => Suggestion(
        item: GlobalSearchItem.fromJson(json),
        why: (json['why'] as String? ?? '').trim(),
      );
}

class SuggestionResult {
  const SuggestionResult({
    this.items = const [],
    this.dropped = 0,
    this.remainingToday = 0,
    this.model = '',
  });

  final List<Suggestion> items;

  /// How many titles the model named that no configured source carries.
  /// Shown as a quiet footnote; never as a title.
  final int dropped;

  /// Requests left in today's allowance, after this one.
  final int remainingToday;
  final String model;

  bool get isEmpty => items.isEmpty;

  factory SuggestionResult.fromJson(Map<String, dynamic> json) => SuggestionResult(
        items: [
          for (final raw in (json['items'] as List<dynamic>? ?? const []))
            Suggestion.fromJson(raw as Map<String, dynamic>),
        ],
        dropped: (json['dropped'] as num?)?.toInt() ?? 0,
        remainingToday: (json['remaining_today'] as num?)?.toInt() ?? 0,
        model: json['model'] as String? ?? '',
      );
}

/// Whether the feature can run at all, answered without running it.
///
/// A missing API key is a deployment state, not an error — so the screen hides
/// the prompt box rather than offering a button that fails on tap.
class SuggestionAvailability {
  const SuggestionAvailability({
    required this.available,
    required this.reason,
    required this.remainingToday,
  });

  final bool available;

  /// `ok` · `not_configured` · `budget_exhausted`.
  final String reason;
  final int remainingToday;

  bool get isBudgetExhausted => reason == 'budget_exhausted';

  factory SuggestionAvailability.fromJson(Map<String, dynamic> json) =>
      SuggestionAvailability(
        available: json['available'] as bool? ?? false,
        reason: json['reason'] as String? ?? 'not_configured',
        remainingToday: (json['remaining_today'] as num?)?.toInt() ?? 0,
      );
}
