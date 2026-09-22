import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_colors.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/features/library/models/global_search_result.dart';
import 'package:manhwamaniacs/features/library/models/recommendation.dart';
import 'package:manhwamaniacs/features/library/models/suggestion.dart';
import 'package:manhwamaniacs/features/library/providers/intelligence_providers.dart';
import 'package:manhwamaniacs/features/library/providers/library_list_provider.dart';
import 'package:manhwamaniacs/features/library/widgets/search/global_search_result_card.dart';
import 'package:manhwamaniacs/shared/widgets/premium/hero_heading.dart';
import 'package:manhwamaniacs/shared/widgets/premium/primary_pill_button.dart';
import 'package:manhwamaniacs/shared/widgets/skeleton_box.dart';

/// "Describe what you feel like reading" → series this server can open.
///
/// The suggestions are grounded twice over. The server only ever picks from
/// its own catalog cache, so every card opens — a model asked to recall titles
/// answers with excellent books nothing here carries. And the prompt carries
/// what this profile has actually read, deepest first, so the answer is this
/// reader's rather than a generic list of the same famous seven.
///
/// The genre chips below are the old feature, kept: they are the cheapest way
/// to start when you do not feel like typing a sentence.
class RecommendationsScreen extends ConsumerStatefulWidget {
  const RecommendationsScreen({super.key});

  @override
  ConsumerState<RecommendationsScreen> createState() =>
      _RecommendationsScreenState();
}

class _RecommendationsScreenState extends ConsumerState<RecommendationsScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    ref.read(suggestionsProvider.notifier).submit(_controller.text);
  }

  void _openItem(GlobalSearchItem item) {
    final source = item.source;
    if (source != null && source.isNotEmpty) {
      context.push(RoutePaths.sourceSeriesDetail(source, item.seriesId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final availability = ref.watch(suggestAvailabilityProvider);
    final suggestions = ref.watch(suggestionsProvider);
    final genresAsync = ref.watch(recommendationsProvider);

    // An unconfigured server is a deployment state, not an error to put in
    // front of a reader: the box is simply absent and the genre chips remain.
    final state = availability.asData?.value;
    final canAsk = state?.available ?? false;
    // "not_configured" and "budget_exhausted" both hide the box, but only one
    // of them is worth a sentence: a server with no key was never going to
    // offer this, while a reader who just spent the 60th request of the day
    // watched the box vanish out from under them and deserves to be told it
    // comes back rather than silently reading as broken or removed.
    final budgetExhausted = state?.isBudgetExhausted ?? false;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go(Routes.library),
        ),
        title: const Text('Find something to read'),
      ),
      body: ListView(
        padding: EdgeInsets.all(context.space.xl2),
        children: [
          const HeroHeading(text: 'What do you feel like?'),
          SizedBox(height: context.space.xs),
          Text(
            canAsk
                ? 'Describe it in your own words. Suggestions are weighed '
                    'against what you already read.'
                : budgetExhausted
                    ? "You've used today's AI suggestions. They reset at "
                        'midnight UTC — pick a genre below meanwhile.'
                    : 'Pick a genre you read a lot of.',
            style: context.text.body.copyWith(color: context.colors.muted),
          ),
          if (canAsk) ...[
            SizedBox(height: context.space.xl),
            _PromptBox(
              controller: _controller,
              onSubmit: _submit,
              busy: suggestions.isLoading,
              remainingToday: state?.remainingToday,
            ),
          ],
          SizedBox(height: context.space.xl2),
          _SuggestionsSection(
            suggestions: suggestions,
            onOpen: _openItem,
            onRetry: _submit,
          ),
          _GenreSection(genresAsync: genresAsync),
        ],
      ),
    );
  }
}

class _PromptBox extends StatefulWidget {
  const _PromptBox({
    required this.controller,
    required this.onSubmit,
    required this.busy,
    this.remainingToday,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;
  final bool busy;

  /// Requests left in today's allowance. Null while availability is still
  /// loading — nothing renders for that, rather than a flash of "0 left".
  final int? remainingToday;

  /// Concrete enough to show the box takes a sentence, not a keyword. A reader
  /// shown "action, fantasy" types "action, fantasy" and gets a search.
  static const _examples = <String>[
    'A murim regressor who comes back stronger',
    'Magic academy, but the lead is already strong',
    'Something slow and political, not a power fantasy',
  ];

  @override
  State<_PromptBox> createState() => _PromptBoxState();
}

class _PromptBoxState extends State<_PromptBox> {
  @override
  void initState() {
    super.initState();
    // The button's enabled state depends on the text, so it has to rebuild on
    // every keystroke. Without this listener the CTA stays permanently live —
    // pressable, unresponsive to an empty box, and silent about why: the
    // notifier refuses anything under 3 characters with no state change at
    // all, so a tap on a dead button looked identical to a tap on a working
    // one. The web client gets this for free from `disabled={...}` re-running
    // on every render; a StatelessWidget here cannot.
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  bool get _canSubmit =>
      !widget.busy && widget.controller.text.trim().length >= 3;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: widget.controller,
          minLines: 2,
          maxLines: 4,
          maxLength: 600,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(
            hintText: 'e.g. a revenge story with a competent lead, no harem',
            filled: true,
            fillColor: context.colors.panel,
            counterText: '',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(context.radii.lg),
              borderSide: BorderSide(color: context.colors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(context.radii.lg),
              borderSide: BorderSide(color: context.colors.border),
            ),
          ),
        ),
        SizedBox(height: context.space.md),
        Wrap(
          spacing: context.space.sm,
          runSpacing: context.space.sm,
          children: [
            for (final example in _PromptBox._examples)
              ActionChip(
                label: Text(example, style: context.text.caption),
                backgroundColor: context.colors.panel,
                onPressed: widget.busy
                    ? null
                    : () {
                        widget.controller.text = example;
                        widget.onSubmit();
                      },
              ),
          ],
        ),
        SizedBox(height: context.space.lg),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PrimaryPillButton(
              label: widget.busy ? 'Thinking' : 'Suggest something',
              onPressed: _canSubmit ? widget.onSubmit : null,
            ),
            // Matches the web client's threshold: silent above 10 remaining,
            // shown once the day's allowance is close enough to matter.
            if (widget.remainingToday != null && widget.remainingToday! <= 10) ...[
              SizedBox(width: context.space.md),
              Text(
                '${widget.remainingToday} left today',
                style: context.text.caption.copyWith(color: context.colors.muted),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _SuggestionsSection extends StatelessWidget {
  const _SuggestionsSection({
    required this.suggestions,
    required this.onOpen,
    required this.onRetry,
  });

  final AsyncValue<SuggestionResult?> suggestions;
  final void Function(GlobalSearchItem) onOpen;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return suggestions.when(
      loading: () => Column(
        children: [
          for (var i = 0; i < 3; i++) ...[
            const SkeletonBox(width: double.infinity, height: 124),
            SizedBox(height: context.space.md),
          ],
        ],
      ),
      error: (error, _) => Padding(
        padding: EdgeInsets.only(bottom: context.space.xl2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              error is AppError
                  ? error.userMessage
                  : "That didn't work. Try describing it differently.",
              style: context.text.body.copyWith(color: context.colors.danger),
            ),
            SizedBox(height: context.space.md),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
      data: (result) {
        if (result == null || result.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(bottom: context.space.xl2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final suggestion in result.items) ...[
                GlobalSearchResultCard(
                  item: suggestion.item,
                  footnote: suggestion.why,
                  onTap: () => onOpen(suggestion.item),
                ),
                SizedBox(height: context.space.md),
              ],
              if (result.dropped > 0)
                Text(
                  // Said plainly rather than hidden: the model named things
                  // no source here carries, and those were thrown away rather
                  // than shown as cards that go nowhere.
                  '${result.dropped} more suggestion'
                  '${result.dropped == 1 ? '' : 's'} skipped — no source here '
                  'carries them.',
                  style: context.text.caption
                      .copyWith(color: context.colors.muted),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _GenreSection extends ConsumerWidget {
  const _GenreSection({required this.genresAsync});

  final AsyncValue<List<RecommendationGenre>> genresAsync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return genresAsync.maybeWhen(
      data: (genres) {
        if (genres.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Or start from a genre',
              style: context.text.labelLg,
            ),
            SizedBox(height: context.space.md),
            Wrap(
              spacing: context.space.sm,
              runSpacing: context.space.sm,
              children: [
                for (final genre in genres)
                  _GenreChip(
                    genre: genre.genre,
                    weight: genre.weight,
                    onTap: () {
                      ref.read(searchQueryProvider.notifier).state = genre.genre;
                      context.go(Routes.search);
                    },
                  ),
              ],
            ),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _GenreChip extends StatelessWidget {
  const _GenreChip({
    required this.genre,
    required this.weight,
    required this.onTap,
  });

  final String genre;
  final int weight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.panel,
      borderRadius: BorderRadius.circular(context.radii.full),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radii.full),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.space.lg,
            vertical: context.space.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(genre, style: context.text.label),
              SizedBox(width: context.space.xs),
              Text(
                '$weight',
                style: context.text.caption.copyWith(color: context.colors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
