import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/novels/models/novel_palette.dart';
import 'package:manhwamaniacs/features/novels/models/novel_typography.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_preferences_provider.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_chapter_view.dart';

/// The four decisions that make prose read as a novel rather than a chat log,
/// asserted on the widget tree rather than trusted to survive a refactor.
///
/// The most load-bearing of them is the first: paragraphs are INDENTED, not
/// separated by blank lines. It is easy to "clean up" an indent into a gap and
/// impossible to notice from a diff, so it is pinned here.
const _prose =
    'The gate had stood shut for four hundred years, and nobody living could '
    'remember who had closed it or why they had bothered to.';

const _second =
    'She put her hand flat against it anyway, the way her mother had told '
    'her never to, and felt the cold go all the way up her arm.';

NovelSurfaceColors get _surface =>
    NovelSurfaceColors.fromPalette(NovelPalettes.paper);

Future<void> _pump(
  WidgetTester tester,
  List<String> paragraphs, {
  NovelPreferences preferences = const NovelPreferences(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            NovelChapterView(
              paragraphs: paragraphs,
              palette: _surface,
              preferences: preferences,
              paragraphKeys: [
                for (var i = 0; i < paragraphs.length; i++) GlobalKey(),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Every rendered paragraph, in order, as its root [InlineSpan].
List<InlineSpan> _spans(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.textSpan)
    .whereType<InlineSpan>()
    .toList();

/// The first-line indent a paragraph carries, in logical pixels; 0 when flush.
///
/// Reads the ADVANCE, not the mechanism. The indent used to be a WidgetSpan
/// holding a SizedBox, which made RenderParagraph lay every paragraph out
/// twice; it is now a zero-width space carrying the advance as letterSpacing.
/// Asserting the width rather than the widget type is what lets the mechanism
/// change without the guarantee changing.
double _indentOf(InlineSpan span) {
  var indent = 0.0;
  span.visitChildren((child) {
    if (child is TextSpan && child.text == '\u200B') {
      indent = child.style?.letterSpacing ?? 0;
    }
    return true;
  });
  return indent;
}

bool _isIndented(InlineSpan span) => _indentOf(span) > 0;

void main() {
  group('paragraphs are indented, not spaced', () {
    testWidgets('the chapter opener is flush, as books set it', (tester) async {
      await _pump(tester, const [_prose, _second]);
      final spans = _spans(tester);
      expect(_isIndented(spans.first), isFalse);
    });

    testWidgets('every following paragraph carries a first-line indent',
        (tester) async {
      await _pump(tester, const [_prose, _second, _second]);
      final spans = _spans(tester);
      expect(_isIndented(spans[1]), isTrue);
      expect(_isIndented(spans[2]), isTrue);
    });

    testWidgets('the indent scales with the chosen text size', (tester) async {
      await _pump(
        tester,
        const [_prose, _second],
        preferences: const NovelPreferences(fontSize: 24),
      );
      expect(
        _indentOf(_spans(tester)[1]),
        closeTo(24 * kNovelParagraphIndentEm, 0.01),
      );
    });
  });

  group('the drop cap', () {
    testWidgets('opens a prose chapter', (tester) async {
      await _pump(tester, const [_prose, _second]);
      final opener = _spans(tester).first as TextSpan;
      final initial = opener.children!.first as TextSpan;
      expect(initial.text, 'T');
      expect(initial.style!.fontSize, greaterThan(30));
    });

    testWidgets('declines a dialogue opener — a raised quote reads as an error',
        (tester) async {
      const dialogue =
          '"Wait," she said, and the whole corridor went quiet around her, '
          'which was somehow worse than any answer she could have given.';
      await _pump(tester, const [dialogue, _second]);
      final opener = _spans(tester).first as TextSpan;
      // The whole paragraph in one run, at the body size — no raised initial.
      final sizes = <double?>[];
      opener.visitChildren((child) {
        if (child is TextSpan) sizes.add(child.style?.fontSize);
        return true;
      });
      expect(sizes.whereType<double>().where((s) => s > 30), isEmpty);
      expect(find.textContaining('"Wait,"', findRichText: true), findsOneWidget);
    });
  });

  group('scene breaks', () {
    testWidgets('are centred ornaments, not indented punctuation',
        (tester) async {
      await _pump(tester, const [_prose, '***', _second]);
      final ornament = find.text('***');
      expect(ornament, findsOneWidget);
      expect(
        tester.widget<Text>(ornament).textAlign,
        TextAlign.center,
      );
      // And it sits in a Center, not in the prose column's flow.
      expect(
        find.ancestor(of: ornament, matching: find.byType(Center)),
        findsWidgets,
      );
    });

    testWidgets('the paragraph after a break is flush, like a new scene',
        (tester) async {
      await _pump(tester, const [_prose, '***', _second]);
      final spans = _spans(tester);
      // spans: [opener, ornament, paragraph-after-break]
      expect(_isIndented(spans.last), isFalse);
    });

    testWidgets('the source ornament is kept, never normalised', (tester) async {
      await _pump(tester, const [_prose, '◇◇◇', _second]);
      expect(find.text('◇◇◇'), findsOneWidget);
      expect(find.text('***'), findsNothing);
    });
  });

  group('the surface', () {
    testWidgets('paints body text in the palette ink, not the app theme',
        (tester) async {
      await _pump(tester, const [_prose, _second]);
      final body = tester.widgetList<Text>(find.byType(Text)).last;
      expect(body.style!.color, NovelPalettes.paper.ink);
    });

    testWidgets('sets prose in the serif stack by default', (tester) async {
      await _pump(tester, const [_prose, _second]);
      final body = tester.widgetList<Text>(find.byType(Text)).last;
      expect(body.style!.fontFamily, kNovelSerifStack.first);
      expect(body.style!.fontFamilyFallback, kNovelSerifStack.sublist(1));
    });

    testWidgets('honours a sans choice', (tester) async {
      await _pump(
        tester,
        const [_prose, _second],
        preferences: const NovelPreferences(fontFamily: NovelFontFamily.sans),
      );
      final body = tester.widgetList<Text>(find.byType(Text)).last;
      expect(body.style!.fontFamily, kNovelSansStack.first);
    });
  });
}
