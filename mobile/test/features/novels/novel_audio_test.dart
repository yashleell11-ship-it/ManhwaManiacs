import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';

/// Follow-along runs on every position tick against a chapter of several
/// hundred segments, and its failure mode is a highlight on the wrong words —
/// which tells the reader the app is confused about its own book. So most of
/// this is about refusing rather than guessing.
NovelAudioSegment seg(int i, int start, int end, {int p = 0, int s = 0, int e = 10}) {
  return NovelAudioSegment(
    index: i,
    startMs: start,
    endMs: end,
    paragraph: p,
    start: s,
    end: e,
    isSpeech: false,
  );
}

NovelAudio mapOf(List<NovelAudioSegment> segments) {
  return NovelAudio(
    available: true,
    totalMs: segments.isEmpty ? 0 : segments.last.endMs,
    bytes: 1,
    segments: segments,
    highlightSafe: true,
  );
}

void main() {
  // Contiguous and monotonic, exactly as the renderer emits it.
  final audio = mapOf([
    seg(0, 0, 1200),
    seg(1, 1200, 3400, p: 1),
    seg(2, 3400, 3900, p: 2),
    seg(3, 3900, 9000, p: 3),
  ]);

  group('segmentAt', () {
    test('finds the sentence being spoken', () {
      expect(audio.segmentAt(2000), 1);
    });

    test('a segment owns its start instant', () {
      expect(audio.segmentAt(1200), 1);
    });

    test('a boundary belongs to the LATER segment', () {
      // Otherwise the highlight sits a beat behind the voice at every
      // sentence break.
      expect(audio.segmentAt(3400), 2);
      expect(audio.segmentAt(3399), 1);
    });

    test('covers the very start', () {
      expect(audio.segmentAt(0), 0);
    });

    test('highlights nothing past the end', () {
      expect(audio.segmentAt(9000), -1);
      expect(audio.segmentAt(99999), -1);
    });

    test('highlights nothing before the first segment', () {
      expect(mapOf([seg(0, 500, 1000)]).segmentAt(0), -1);
    });

    test('survives an empty map', () {
      expect(NovelAudio.none.segmentAt(100), -1);
    });

    test('lands in a gap without inventing a segment', () {
      expect(mapOf([seg(0, 0, 1000), seg(1, 2000, 3000)]).segmentAt(1500), -1);
    });

    test('agrees with a linear scan across the whole map', () {
      // The binary search is only safe because the map is monotonic; this is
      // the property test for that.
      for (var t = 0; t < 9000; t += 37) {
        var expected = -1;
        for (var i = 0; i < audio.segments.length; i++) {
          final s = audio.segments[i];
          if (t >= s.startMs && t < s.endMs) {
            expected = i;
            break;
          }
        }
        expect(audio.segmentAt(t), expected, reason: 'at ${t}ms');
      }
    });
  });

  group('matchesText', () {
    final paragraphs = List.filled(4, '0123456789abc');

    test('accepts a map whose ranges all exist', () {
      expect(audio.matchesText(paragraphs), isTrue);
    });

    test('rejects a range past the end of a paragraph', () {
      // The chapter cache refetched and the text got shorter.
      expect(mapOf([seg(0, 0, 100, e: 999)]).matchesText(paragraphs), isFalse);
    });

    test('rejects a paragraph that is gone', () {
      expect(mapOf([seg(0, 0, 100, p: 42)]).matchesText(paragraphs), isFalse);
    });

    test('rejects an inverted or empty range', () {
      expect(mapOf([seg(0, 0, 100, s: 5, e: 5)]).matchesText(paragraphs), isFalse);
      expect(mapOf([seg(0, 0, 100, s: 9, e: 3)]).matchesText(paragraphs), isFalse);
    });

    test('an empty map matches nothing', () {
      // Nothing to follow along with is not the same as following along fine.
      expect(NovelAudio.none.matchesText(paragraphs), isFalse);
    });
  });

  group('parsing', () {
    test('reads the server payload', () {
      final parsed = NovelAudio.fromJson(const {
        'available': true,
        'total_ms': 737263,
        'bytes': 2232490,
        'segments': [
          {
            'i': 0,
            'start_ms': 0,
            'end_ms': 1200,
            'p': 1,
            's': 4,
            'e': 20,
            'voice': 'libritts-2428',
            'speaker': 'Myre',
            'speech': true,
          },
        ],
      });

      expect(parsed.available, isTrue);
      expect(parsed.totalMs, 737263);
      expect(parsed.segments.single.speaker, 'Myre');
      expect(parsed.segments.single.isSpeech, isTrue);
    });

    test('an unrendered chapter is not an error', () {
      // Almost the whole library.
      final parsed = NovelAudio.fromJson(const {
        'available': false,
        'bytes': 0,
        'total_ms': 0,
        'segments': <dynamic>[],
      });

      expect(parsed.available, isFalse);
      expect(parsed.segments, isEmpty);
    });

    test('follows along only when the server vouches for the text', () {
      Map<String, dynamic> payload(Object? safe) => {
            'available': true,
            'total_ms': 1200,
            'bytes': 10,
            if (safe != null) 'highlight_safe': safe,
            'segments': [
              {'i': 0, 'start_ms': 0, 'end_ms': 1200, 'p': 0, 's': 0, 'e': 5},
            ],
          };

      expect(NovelAudio.fromJson(payload(true)).highlightSafe, isTrue);
      expect(NovelAudio.fromJson(payload(false)).highlightSafe, isFalse);
      // A server — or a map saved on the phone — from before the flag cannot
      // say, and "cannot be known" is not "yes".
      expect(NovelAudio.fromJson(payload(null)).highlightSafe, isFalse);
      expect(NovelAudio.fromJson(payload('true')).highlightSafe, isFalse);

      const text = ['Hello there.'];
      expect(NovelAudio.fromJson(payload(true)).followsText(text), isTrue);
      expect(NovelAudio.fromJson(payload(false)).followsText(text), isFalse);
    });

    test('a saved map keeps its verdict', () {
      // The map is saved beside offline audio and read back with no server
      // to ask again.
      final saved = NovelAudio.fromJson(
        NovelAudio.fromJson(const {
          'available': true,
          'highlight_safe': true,
          'segments': <dynamic>[],
        }).toJson(),
      );
      expect(saved.highlightSafe, isTrue);
      expect(NovelAudio.none.highlightSafe, isFalse);
    });

    test('a malformed payload degrades to no audio rather than throwing', () {
      // Audio is an addition to the page; it must never break the reader.
      final parsed = NovelAudio.fromJson(const {'segments': 'not a list'});

      expect(parsed.available, isFalse);
      expect(parsed.segments, isEmpty);
    });
  });
}
