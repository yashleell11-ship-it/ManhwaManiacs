import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_progress.dart';

/// The bucket mapping is a wire contract, not an internal detail: the web
/// reader and this one write the same `(last_page, page_count)` columns and
/// the server merges them furthest-wins. If the two clients bucket
/// differently, the same paragraph means two different positions and one of
/// them silently wins.
void main() {
  group('bucket count', () {
    test('short chapters get one bucket per paragraph', () {
      expect(bucketCount(1), 1);
      expect(bucketCount(30), 30);
      expect(bucketCount(99), 99);
    });

    test('long chapters cap at ~1% a bucket', () {
      expect(bucketCount(100), 100);
      expect(bucketCount(900), kMaxProgressBuckets);
    });

    test('a chapter with no paragraphs still has one bucket to be in', () {
      expect(bucketCount(0), 1);
      expect(bucketCount(-4), 1);
    });
  });

  group('paragraph → bucket', () {
    test('is 1-based, because last_page 0 already means "no progress"', () {
      expect(bucketForParagraph(0, 30), 1);
      expect(bucketForParagraph(29, 30), 30);
    });

    test('never exceeds the bucket count, however the maths rounds', () {
      for (final count in [1, 7, 99, 100, 101, 512, 900]) {
        final buckets = bucketCount(count);
        for (var i = 0; i < count; i++) {
          final bucket = bucketForParagraph(i, count);
          expect(bucket, inInclusiveRange(1, buckets));
        }
      }
    });

    test('is monotonic — scrolling forward never reports an earlier bucket',
        () {
      var previous = 0;
      for (var i = 0; i < 900; i++) {
        final bucket = bucketForParagraph(i, 900);
        expect(bucket, greaterThanOrEqualTo(previous));
        previous = bucket;
      }
      expect(previous, kMaxProgressBuckets);
    });

    test('an out-of-range index is clamped rather than throwing', () {
      expect(bucketForParagraph(-5, 30), 1);
      expect(bucketForParagraph(500, 30), 30);
    });
  });

  group('bucket → paragraph', () {
    test('lands on the FIRST paragraph of the bucket, never the last', () {
      // Re-reading a paragraph is free; skipping one is not.
      expect(paragraphForBucket(1, 900), 0);
      expect(paragraphForBucket(2, 900), 9);
      expect(paragraphForBucket(kMaxProgressBuckets, 900), 891);
    });

    test('round-trips within its own bucket for every paragraph', () {
      for (final count in [1, 30, 100, 457, 900]) {
        for (var i = 0; i < count; i++) {
          final bucket = bucketForParagraph(i, count);
          final resumed = paragraphForBucket(bucket, count);
          // Resuming lands at or before where the reader was — never after it.
          expect(resumed, lessThanOrEqualTo(i));
          expect(bucketForParagraph(resumed, count), bucket);
        }
      }
    });

    test('clamps a stored bucket from a chapter that has since been re-split',
        () {
      expect(paragraphForBucket(100, 12), 11);
      expect(paragraphForBucket(0, 12), 0);
      expect(paragraphForBucket(5, 0), 0);
    });
  });

  group('what to push', () {
    test('reports completion only at the last bucket', () {
      expect(progressForParagraph(0, 30).completed, isFalse);
      expect(progressForParagraph(29, 30).completed, isTrue);
      expect(progressForParagraph(899, 900).completed, isTrue);
    });

    test('scrolling back up sends nothing at all', () {
      final back = progressForParagraph(10, 900);
      expect(nextProgressPush(back, 40), isNull);
      expect(nextProgressPush(back, back.bucket), isNull);
    });

    test('moving forward sends the new position', () {
      final forward = progressForParagraph(500, 900);
      final push = nextProgressPush(forward, 40);
      expect(push, isNotNull);
      expect(push!.bucket, forward.bucket);
      expect(push.buckets, kMaxProgressBuckets);
    });

    test('percent read-out is bounded at both ends', () {
      expect(chapterPercent(0, 100), 0);
      expect(chapterPercent(50, 100), 50);
      expect(chapterPercent(140, 100), 100);
      expect(chapterPercent(3, 0), 0);
    });
  });

  group('finishing a chapter', () {
    test('the bottom of the scroll is the last paragraph, not the one under '
        'the reading line', () {
      // The shape of the stuck production row: 45 paragraphs, and the reading
      // line could reach no further than index 39 with the scroll bottomed out.
      final measured = progressAtReadingLine(39, 45, atEnd: false);
      expect(measured.bucket, 40);
      expect(measured.completed, isFalse);

      final bottomedOut = progressAtReadingLine(39, 45, atEnd: true);
      expect(bottomedOut.bucket, 45);
      expect(bottomedOut.buckets, 45);
      expect(bottomedOut.completed, isTrue);
    });

    test('a long chapter bottomed out lands in its final bucket', () {
      final position = progressAtReadingLine(830, 900, atEnd: true);
      expect(position.bucket, kMaxProgressBuckets);
      expect(position.completed, isTrue);
    });

    test('moving on reports the chapter complete from anywhere in it', () {
      final done = completedProgress(45);
      expect(done.bucket, 45);
      expect(done.buckets, 45);
      expect(done.completed, isTrue);
      // Sent once: a second Next, or the close after it, has nothing to add.
      expect(nextProgressPush(done, 12), isNotNull);
      expect(nextProgressPush(done, 45), isNull);
    });

    test('a chapter of one screen can still be finished', () {
      final done = completedProgress(3);
      expect(done.bucket, 3);
      expect(done.completed, isTrue);
    });
  });

  group('active paragraph', () {
    test('is the last paragraph starting at or above the reading line', () {
      final offsets = [0.0, 100.0, 200.0, 300.0, 400.0];
      expect(activeParagraphIndex(offsets, -10), 0);
      expect(activeParagraphIndex(offsets, 0), 0);
      expect(activeParagraphIndex(offsets, 150), 1);
      expect(activeParagraphIndex(offsets, 200), 2);
      expect(activeParagraphIndex(offsets, 9999), 4);
    });

    test('an unmeasured chapter reports the opening paragraph', () {
      expect(activeParagraphIndex(const [], 500), 0);
    });
  });
}
