import 'package:flutter/material.dart';
import 'package:manhwamaniacs/features/novels/models/novel_palette.dart';
import 'package:manhwamaniacs/features/novels/models/novel_typography.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_preferences_provider.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_book.dart';

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
  });

  final List<String> paragraphs;

  /// The reading surface, already resolved — `null` is not a state here; the
  /// screen resolves "follow app theme" into concrete colours before this.
  final NovelSurfaceColors palette;
  final NovelPreferences preferences;

  /// One key per paragraph, owned by the screen so it can measure where the
  /// reader is without this widget holding state.
  final List<GlobalKey> paragraphKeys;

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
    required this.text,
    required this.flush,
    required this.dropCap,
    required this.palette,
    required this.preferences,
  });

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

    if (dropCap != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: dropCap!.initial,
                style: style.copyWith(
                  fontSize: preferences.fontSize * 2.6,
                  height: 1.0,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(text: dropCap!.rest),
            ],
          ),
          style: style,
          textAlign: TextAlign.left,
        ),
      );
    }

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
                text: '\u200B',
                style: TextStyle(letterSpacing: indent),
              ),
            TextSpan(text: text),
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
