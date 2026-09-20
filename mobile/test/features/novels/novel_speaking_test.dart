/// The follow-along highlight: which words are lit, and when it refuses.
///
/// The refusals matter more than the successes here. A highlight on the wrong
/// words is worse than no highlight — it tells the reader the app has lost
/// track of its own book — so every path that cannot prove the offsets fit
/// must come back with nothing marked rather than with a guess.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_speaking.dart';

const _style = TextStyle(fontSize: 42);

List<NovelRun> _plain(String text) => [(text: text, style: null)];

String _spoken(List<NovelSpokenRun> runs) => runs
    .where((run) => run.mark == NovelSpeechMark.speaking)
    .map((run) => run.text)
    .join();

String _done(List<NovelSpokenRun> runs) => runs
    .where((run) => run.mark == NovelSpeechMark.done)
    .map((run) => run.text)
    .join();

String _all(List<NovelSpokenRun> runs) => runs.map((run) => run.text).join();

NovelAudioSegment _segment({
  required int index,
  required int startMs,
  required int endMs,
  required int paragraph,
  required int start,
  required int end,
}) {
  return NovelAudioSegment(
    index: index,
    startMs: startMs,
    endMs: endMs,
    paragraph: paragraph,
    start: start,
    end: end,
    isSpeech: true,
  );
}

void main() {
  group('markSpokenRuns', () {
    test('marks exactly the range, and everything before it as read', () {
      final runs = markSpokenRuns(
        _plain('He turned and ran.'),
        doneEnd: 3,
        start: 3,
        end: 9,
      );

      expect(_spoken(runs), 'turned');
      expect(_done(runs), 'He ');
      expect(_all(runs), 'He turned and ran.');
    });

    test('a paragraph the voice has passed is marked read end to end', () {
      final runs = markSpokenRuns(
        _plain('He turned and ran.'),
        doneEnd: 18,
        start: 0,
        end: 0,
      );

      expect(_done(runs), 'He turned and ran.');
      expect(_spoken(runs), isEmpty);
    });

    test('a paragraph the voice has not reached is untouched', () {
      final runs = markSpokenRuns(
        _plain('He turned and ran.'),
        doneEnd: 0,
        start: 0,
        end: 0,
      );

      expect(_done(runs), isEmpty);
      expect(_spoken(runs), isEmpty);
      expect(_all(runs), 'He turned and ran.');
    });

    test('the trail never overlaps the line being spoken', () {
      // They are adjacent regions of one contiguous map, so a character is
      // read OR being read, never both — otherwise the two washes composite
      // and the current line stops standing out.
      const text = 'A quiet word, and then the door.';
      for (var cut = 0; cut < text.length - 4; cut++) {
        final runs = markSpokenRuns(
          _plain(text),
          doneEnd: cut,
          start: cut,
          end: cut + 4,
        );
        expect(_done(runs), text.substring(0, cut), reason: 'cut $cut');
        expect(_spoken(runs), text.substring(cut, cut + 4), reason: 'cut $cut');
      }
    });

    test('never loses or duplicates a character', () {
      const text = 'A quiet word, and then the door.';
      for (var start = 0; start < text.length; start++) {
        for (var end = start + 1; end <= text.length; end++) {
          final runs = markSpokenRuns(
            _plain(text),
            doneEnd: start,
            start: start,
            end: end,
          );
          expect(_all(runs), text, reason: 'range $start..$end');
          expect(_spoken(runs), text.substring(start, end));
        }
      }
    });

    test('a range spanning two runs lights both halves', () {
      // The drop-cap paragraph: a big initial, then the rest. A sentence that
      // opens the chapter crosses the boundary between them.
      final runs = markSpokenRuns(
        [
          (text: 'T', style: _style),
          (text: 'he sky was grey.', style: null),
        ],
        doneEnd: 0,
        start: 0,
        end: 7,
      );

      expect(_spoken(runs), 'The sky');
      // The initial keeps its own style; the highlight does not flatten it.
      expect(runs.first.style, _style);
      expect(runs.first.mark, NovelSpeechMark.speaking);
    });

    test('emits no empty runs', () {
      // An empty TextSpan is still a node RenderParagraph walks every frame.
      for (final range in [(0, 4), (4, 17), (0, 17)]) {
        final runs = markSpokenRuns(
          _plain('He turned and ran'),
          doneEnd: range.$1,
          start: range.$1,
          end: range.$2,
        );
        expect(runs.any((run) => run.text.isEmpty), isFalse, reason: '$range');
      }
    });

    test('refuses a range past the end rather than clamping it', () {
      // The chapter text was refetched and is now shorter. Lighting the last
      // few words because they happen to be in bounds would be a confident
      // wrong answer.
      final runs = markSpokenRuns(
        _plain('Short.'),
        doneEnd: 2,
        start: 2,
        end: 99,
      );

      expect(_spoken(runs), isEmpty);
      expect(_done(runs), isEmpty);
      expect(_all(runs), 'Short.');
    });

    test('refuses a negative or empty range', () {
      const text = 'Text here';
      expect(
        _spoken(markSpokenRuns(_plain(text), doneEnd: -1, start: -1, end: 4)),
        isEmpty,
      );
      expect(
        _spoken(markSpokenRuns(_plain(text), doneEnd: 4, start: 4, end: 4)),
        isEmpty,
      );
      expect(
        _spoken(markSpokenRuns(_plain(text), doneEnd: 6, start: 6, end: 2)),
        isEmpty,
      );
    });
  });

  group('NovelAudioFollower', () {
    final paragraphs = ['He turned and ran.', 'The door was open.'];

    NovelAudio audioFor(List<NovelAudioSegment> segments) => NovelAudio(
          available: true,
          totalMs: 4000,
          bytes: 1024,
          segments: segments,
        );

    final good = audioFor([
      _segment(index: 0, startMs: 0, endMs: 2000, paragraph: 0, start: 0, end: 18),
      _segment(
        index: 1,
        startMs: 2000,
        endMs: 4000,
        paragraph: 1,
        start: 0,
        end: 18,
      ),
    ]);

    test('publishes the paragraph and offsets being spoken', () {
      final follower = NovelAudioFollower(paragraphs);
      addTearDown(follower.dispose);

      follower.onPosition(500, good);

      expect(follower.range.value, (paragraph: 0, start: 0, end: 18));
    });

    test('does not notify while the playhead stays in one sentence', () {
      // The reason this class exists: just_audio ticks many times a second,
      // and every notification is a paragraph rebuild.
      final follower = NovelAudioFollower(paragraphs);
      addTearDown(follower.dispose);
      var notifications = 0;
      follower.range.addListener(() => notifications++);

      for (var ms = 0; ms < 2000; ms += 50) {
        follower.onPosition(ms, good);
      }

      expect(notifications, 1);
    });

    test('notifies once more when the voice reaches the next sentence', () {
      final follower = NovelAudioFollower(paragraphs);
      addTearDown(follower.dispose);
      var notifications = 0;
      follower.range.addListener(() => notifications++);

      follower.onPosition(100, good);
      follower.onPosition(2500, good);

      expect(notifications, 2);
      expect(follower.range.value?.paragraph, 1);
    });

    test('clears when the playhead is null', () {
      final follower = NovelAudioFollower(paragraphs);
      addTearDown(follower.dispose);

      follower.onPosition(500, good);
      follower.onPosition(null, good);

      expect(follower.range.value, isNull);
    });

    test('stays lit while paused', () {
      // Mobile's player emits nothing on pause, and that is deliberate:
      // pausing to re-read the line you just heard and finding the app has
      // forgotten it is the wrong behaviour. Written down so nobody "fixes"
      // it to match the web, which clears.
      final follower = NovelAudioFollower(paragraphs);
      addTearDown(follower.dispose);

      follower.onPosition(500, good);
      final lit = follower.range.value;
      // No further ticks arrive while paused.

      expect(follower.range.value, lit);
      expect(lit, isNotNull);
    });

    test('refuses to follow a map that does not fit the text', () {
      // The chapter cache refetched and the text changed underneath a render.
      final stale = audioFor([
        _segment(
          index: 0,
          startMs: 0,
          endMs: 2000,
          paragraph: 0,
          start: 0,
          end: 900,
        ),
      ]);
      final follower = NovelAudioFollower(paragraphs);
      addTearDown(follower.dispose);

      follower.onPosition(500, stale);

      expect(follower.range.value, isNull);
    });

    test('rechecks when the map instance changes, not on every tick', () {
      // matchesText walks every segment, so it is answered once per instance.
      // The instance changing is exactly when the answer can change.
      final follower = NovelAudioFollower(paragraphs);
      addTearDown(follower.dispose);
      final stale = audioFor([
        _segment(
          index: 0,
          startMs: 0,
          endMs: 2000,
          paragraph: 9,
          start: 0,
          end: 4,
        ),
      ]);

      follower.onPosition(500, good);
      expect(follower.range.value, isNotNull);

      follower.onPosition(600, stale);
      expect(follower.range.value, isNull);
    });

    test('a gap in the map highlights nothing rather than the nearest line', () {
      final follower = NovelAudioFollower(paragraphs);
      addTearDown(follower.dispose);

      follower.onPosition(500, good);
      follower.onPosition(99999, good);

      expect(follower.range.value, isNull);
    });
  });
}
