import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:manhwamaniacs/features/novels/models/novel_palette.dart';
import 'package:manhwamaniacs/features/novels/models/novel_typography.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_preferences_provider.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_book.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_speaking.dart';

/// The prose itself: a chapter set as a book sets one.
///
/// Four decisions do almost all the work of making this read as a novel rather
/// than as a chat log with a serif font, and they are the same four the web
/// made today:
///
/// 1. **Paragraphs are INDENTED, not spaced.** This is most of it. A blank
///    line between every paragraph is a messaging app; a first-line indent
///    with no gap is a book. The exceptions are the ones books make: the first
///    paragraph of a chapter, and the first after a scene break, are set flush
///    — an indent there marks a break from something that is not there.
/// 2. **Scene breaks are centred ornaments**, with air above and below, rather
///    than an indented paragraph of asterisks.
/// 3. **A drop cap opens the chapter** — except on a dialogue opener, where a
///    raised quotation mark reads as an error (see [splitDropCap]).
/// 4. **No page curl, no paper texture, no fake spine.** The richness is the
///    typography and the spacing. Anything else is a costume.
///
/// Rendering is one [SliverList] of paragraphs rather than a single giant
/// [Text]: a 900-paragraph chapter must not lay out all at once, and progress
/// needs to know where each paragraph starts.
class NovelChapterView extends StatelessWidget {
  const NovelChapterView({
    super.key,
    required this.paragraphs,
    required this.palette,
    required this.preferences,
    required this.paragraphKeys,
    this.speaking,
  });

  final List<String> paragraphs;

  /// The reading surface, already resolved — `null` is not a state here; the
  /// screen resolves "follow app theme" into concrete colours before this.
  final NovelSurfaceColors palette;
  final NovelPreferences preferences;

  /// One key per paragraph, owned by the screen so it can measure where the
  /// reader is without this widget holding state.
  final List<GlobalKey> paragraphKeys;

  /// The words being spoken, when a chapter's audio is playing and its timing
  /// map has been proven to match this text.
  ///
  /// A listenable rather than a value: the playhead ticks many times a second
  /// and neither this widget nor the paragraphs that are not speaking may be
  /// rebuilt by it. Null when there is nothing to follow, which is almost
  /// every chapter in the library — and that path renders exactly what it
  /// rendered before this existed.
  final ValueListenable<NovelSpeakingRange?>? speaking;

  @override
  Widget build(BuildContext context) {
    final dropCap = splitDropCap(paragraphs.isEmpty ? null : paragraphs.first);
    return SliverList.builder(
      itemCount: paragraphs.length,
      itemBuilder: (context, index) {
        final text = paragraphs[index];
        if (isSceneBreak(text)) {
          return _SceneBreak(
            key: paragraphKeys[index],
            ornament: text.trim(),
            palette: palette,
            preferences: preferences,
          );
        }
        return _Paragraph(
          key: paragraphKeys[index],
          index: index,
          speaking: speaking,
          text: text,
          // Flush when it opens the chapter, or when the line above it was an
          // ornament: books do not indent the paragraph that starts a scene.
          flush: index == 0 ||
              (index > 0 && isSceneBreak(paragraphs[index - 1])),
          dropCap: index == 0 ? dropCap : null,
          palette: palette,
          preferences: preferences,
        );
      },
    );
  }
}

/// The four colours a novel surface is painted with, resolved.
///
/// A record rather than a [NovelPalette] because "Follow app theme" is a real
/// choice that resolves to the app's own tokens — one rendering path covers
/// both cases, and the reader never needs a second branch that swaps colours
/// for theme lookups.
class NovelSurfaceColors {
  const NovelSurfaceColors({
    required this.bg,
    required this.ink,
    required this.muted,
    required this.isDark,
  });

  factory NovelSurfaceColors.fromPalette(NovelPalette palette) =>
      NovelSurfaceColors(
        bg: palette.bg,
        ink: palette.ink,
        muted: palette.muted,
        isDark: palette.isDark,
      );

  final Color bg;
  final Color ink;
  final Color muted;
  final bool isDark;

  /// Hairlines and the quiet furniture.
  Color get rule => muted.withValues(alpha: 0.28);
}

class _Paragraph extends StatelessWidget {
  const _Paragraph({
    super.key,
    required this.index,
    required this.speaking,
    required this.text,
    required this.flush,
    required this.dropCap,
    required this.palette,
    required this.preferences,
  });

  final int index;
  final ValueListenable<NovelSpeakingRange?>? speaking;
  final String text;
  final bool flush;
  final DropCap? dropCap;
  final NovelSurfaceColors palette;
  final NovelPreferences preferences;

  @override
  Widget build(BuildContext context) {
    final stack = novelFontStack(preferences.fontFamily);
    final style = TextStyle(
      fontFamily: stack.first,
      fontFamilyFallback: stack.sublist(1),
      fontSize: preferences.fontSize,
      height: preferences.lineHeight,
      color: palette.ink,
      // Long-form prose wants a hair of extra letter tracking at small sizes
      // on a phone, where the panel is dense and the face is small.
      letterSpacing: 0.1,
    );

    // The indent is a first-LINE indent, not a paragraph inset: `text-indent`
    // in CSS, and in Flutter a zero-width spacer placed inline ahead of the
    // first word, which is the only way to indent one line of a wrapped
    // paragraph without indenting all of them.
    final indent = flush ? 0.0 : preferences.fontSize * kNovelParagraphIndentEm;

    final runs = _runs(style);

    // Null when nothing is being read aloud — which is the whole library, and
    // every chapter in it before this feature existed. That path has to render
    // exactly what it rendered then, down to the span tree, so it is its own
    // return rather than a degenerate case of the speaking one.
    final listenable = speaking;
    if (listenable == null) {
      return _body(runs, style, indent, const []);
    }
    return ValueListenableBuilder<NovelSpeakingRange?>(
      valueListenable: listenable,
      builder: (context, range, _) {
        if (range == null) return _body(runs, style, indent, const []);
        final length = text.length - _leading;
        // Three cases, and the map's order is what makes them exhaustive:
        // the voice has passed this paragraph entirely, is inside it, or has
        // not reached it.
        if (range.paragraph > index) {
          return _body(
            runs,
            style,
            indent,
            markSpokenRuns(runs, doneEnd: length, start: 0, end: 0),
          );
        }
        if (range.paragraph < index) {
          return _body(runs, style, indent, const []);
        }
        final start = range.start - _leading;
        return _body(
          runs,
          style,
          indent,
          markSpokenRuns(
            runs,
            doneEnd: start,
            start: start,
            end: range.end - _leading,
          ),
        );
      },
    );
  }

  /// How far the rendered runs sit from the offsets the server measured.
  ///
  /// [splitDropCap] trims its input, so a drop-capped paragraph's runs
  /// concatenate to `text.trim()` while the timing map was measured against
  /// `text`. Every other paragraph renders verbatim. A paragraph whose
  /// leading whitespace does not account for the whole shift falls out of
  /// range in [splitSpokenRuns] and loses its highlight rather than lighting
  /// the wrong words.
  int get _leading =>
      dropCap == null ? 0 : text.length - text.trimLeft().length;

  /// The paragraph as the runs the playhead is laid over.
  ///
  /// The drop cap is a styled first run rather than a second rendering path:
  /// paragraph 0 is where a chapter's audio starts, so a branch that skipped
  /// it would mean the highlight never appears until the second paragraph.
  /// The indent spacer is deliberately NOT a run — it is not part of the
  /// paragraph's text, and counting it would shift every offset by one.
  List<NovelRun> _runs(TextStyle style) {
    if (dropCap != null) {
      return [
        (
          text: dropCap!.initial,
          style: style.copyWith(
            fontSize: preferences.fontSize * 2.6,
            height: 1.0,
            fontWeight: FontWeight.w600,
          ),
        ),
        (text: dropCap!.rest, style: null),
      ];
    }
    return [(text: text, style: null)];
  }

  Widget _body(
    List<NovelRun> runs,
    TextStyle style,
    double indent,
    List<NovelSpokenRun> marked,
  ) {
    // Both washes are drawn from the ink, so they are right in both themes by
    // construction rather than by palette entries that can drift from this
    // one. The trail is deliberately near the threshold of noticing — it is
    // there to be seen out of the corner of the eye when you look back up, not
    // to compete with the line actually being read.
    final done = TextStyle(
      backgroundColor: palette.ink.withValues(alpha: 0.05),
    );
    final speaking = TextStyle(
      backgroundColor: palette.ink.withValues(alpha: 0.15),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text.rich(
        TextSpan(
          children: [
            // A zero-width space carrying the indent as letter spacing, NOT a
            // WidgetSpan. A WidgetSpan turns RenderParagraph from a leaf into a
            // render object with children: it has to lay out each placeholder
            // box, feed the dimensions back in and lay the text out a second
            // time — per paragraph, per frame it is rebuilt. The pen advances
            // by exactly `indent` either way, so this renders identically.
            if (indent > 0)
              TextSpan(
                text: '​',
                style: TextStyle(letterSpacing: indent),
              ),
            if (marked.isEmpty)
              for (final run in runs)
                TextSpan(text: run.text, style: run.style)
            else
              for (final run in marked)
                TextSpan(
                  text: run.text,
                  style: switch (run.mark) {
                    NovelSpeechMark.none => run.style,
                    NovelSpeechMark.done =>
                      (run.style ?? const TextStyle()).merge(done),
                    NovelSpeechMark.speaking =>
                      (run.style ?? const TextStyle()).merge(speaking),
                  },
                ),
          ],
        ),
        style: style,
        textAlign: TextAlign.left,
      ),
    );
  }
}

/// A scene change, set the way a book sets one: centred, in the muted ink,
/// with air on both sides. The ornament the source actually used is kept
/// rather than normalised to `***` — translators pick them deliberately.
class _SceneBreak extends StatelessWidget {
  const _SceneBreak({
    super.key,
    required this.ornament,
    required this.palette,
    required this.preferences,
  });

  final String ornament;
  final NovelSurfaceColors palette;
  final NovelPreferences preferences;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: preferences.fontSize * 1.6),
      child: Center(
        child: Text(
          ornament,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: preferences.fontSize * 0.9,
            color: palette.muted,
            letterSpacing: preferences.fontSize * 0.35,
          ),
        ),
      ),
    );
  }
}
