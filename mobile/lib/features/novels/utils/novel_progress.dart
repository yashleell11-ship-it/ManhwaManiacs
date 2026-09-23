/// Reading position for a novel chapter, expressed in the fields the server
/// already merges.
///
/// `chapter_progress` stores `(chapter_number, last_page, page_count)` and
/// merges **furthest-wins** — a stale client replaying an old position can
/// never rewind a reader. A novel has no pages, so rather than inventing a
/// parallel progress model (and a second merge rule to keep correct), a
/// chapter's paragraphs are bucketed and the bucket index rides in `last_page`
/// with the bucket count in `page_count`. The server's merge, the library's
/// "continue reading", the progress outbox and the statistics service all keep
/// working with no change at all.
///
/// Buckets, not raw paragraph indices, because `page_count` is also what the
/// UI divides by: one bucket per paragraph turns a 900-paragraph chapter into
/// "page 412 of 900", and a chapter whose paragraph count shifts upstream (an
/// aggregator re-splitting a wall of text) would move a stored position by
/// hundreds. Capping at [kMaxProgressBuckets] makes a bucket ≈1% of the
/// chapter, which is stable across a re-split and reads sensibly as a percent.
///
/// Short chapters get one bucket per paragraph, so resuming a 30-paragraph
/// chapter lands on the exact paragraph.
///
/// Ported from `frontend/src/features/novels/progress.ts` — the two clients
/// write into the same column and must bucket identically, or the same
/// position would mean two different places.
library;

/// A bucket is at worst ~1% of a chapter.
const int kMaxProgressBuckets = 100;

/// How many buckets a chapter of [paragraphCount] paragraphs is divided into.
int bucketCount(int paragraphCount) {
  if (paragraphCount <= 0) return 1;
  return paragraphCount < kMaxProgressBuckets
      ? paragraphCount
      : kMaxProgressBuckets;
}

/// The 1-based bucket a paragraph falls in. [paragraphIndex] is 0-based.
///
/// 1-based because `last_page` is 1-based everywhere else in the app, and a
/// stored `0` already means "no progress" to the library and the series page.
int bucketForParagraph(int paragraphIndex, int paragraphCount) {
  final buckets = bucketCount(paragraphCount);
  if (paragraphCount <= 0) return 1;
  final index = paragraphIndex.clamp(0, paragraphCount - 1);
  final bucket = (index * buckets) ~/ paragraphCount + 1;
  return bucket < buckets ? bucket : buckets;
}

/// The 0-based index of the FIRST paragraph in a bucket — where resuming that
/// bucket lands the reader. Deliberately the first and not the last:
/// re-reading a paragraph you already read is free, skipping one is not.
int paragraphForBucket(int bucket, int paragraphCount) {
  if (paragraphCount <= 0) return 0;
  final buckets = bucketCount(paragraphCount);
  final clamped = bucket.clamp(1, buckets);
  final first = ((clamped - 1) * paragraphCount + buckets - 1) ~/ buckets;
  return first < paragraphCount - 1 ? first : paragraphCount - 1;
}

/// The reading position to report, ready to push as progress.
class NovelProgressPosition {
  const NovelProgressPosition({
    required this.bucket,
    required this.buckets,
    required this.completed,
  });

  /// 1-based bucket index — goes in `last_page`.
  final int bucket;

  /// Total buckets — goes in `page_count`.
  final int buckets;

  /// Whether the reader reached the end of the chapter.
  final bool completed;
}

NovelProgressPosition progressForParagraph(
  int paragraphIndex,
  int paragraphCount,
) {
  final buckets = bucketCount(paragraphCount);
  final bucket = bucketForParagraph(paragraphIndex, paragraphCount);
  return NovelProgressPosition(
    bucket: bucket,
    buckets: buckets,
    completed: bucket >= buckets,
  );
}

/// The position to report for the paragraph under the reading line, given
/// whether the scroll has bottomed out.
///
/// The end of the scroll counts as the last paragraph. The reading line sits
/// a quarter of the way down the screen and the chapter's foot is only a
/// couple of hundred pixels tall, so at the bottom the last paragraph's top is
/// still below the line unless that one paragraph is most of a screen long —
/// which almost none is. Measured literally, a 45-paragraph chapter read to
/// its final word reported bucket 40 and was never complete.
NovelProgressPosition progressAtReadingLine(
  int paragraphIndex,
  int paragraphCount, {
  required bool atEnd,
}) =>
    progressForParagraph(
      atEnd ? paragraphCount - 1 : paragraphIndex,
      paragraphCount,
    );

/// A finished chapter: the last bucket, completed.
///
/// What moving on to the NEXT chapter reports, wherever the scroll last was,
/// the same as the web's `advanceToNextChapter`. A reader who taps Next is
/// done with this one, and a chapter short enough to fit on one screen never
/// scrolls at all, so nothing else would ever say so.
NovelProgressPosition completedProgress(int paragraphCount) {
  final buckets = bucketCount(paragraphCount);
  return NovelProgressPosition(
    bucket: buckets,
    buckets: buckets,
    completed: true,
  );
}

/// The position actually worth sending, given what has already been sent for
/// this chapter.
///
/// Never rewinds: scrolling back up to re-read a line must not tell the server
/// the reader is earlier in the chapter than they got to. The server would
/// refuse it anyway (furthest-wins), but sending it is a pointless write and
/// would rewind the OPTIMISTIC local state the series screen reads back.
/// `null` means "nothing new to say".
NovelProgressPosition? nextProgressPush(
  NovelProgressPosition position,
  int furthestSent,
) {
  if (position.bucket <= furthestSent) return null;
  return position;
}

/// Percentage through a chapter, for the reader's own progress read-out.
int chapterPercent(int bucket, int buckets) {
  if (buckets <= 0) return 0;
  final clamped = bucket.clamp(0, buckets);
  return (clamped * 100 / buckets).round();
}

/// Which paragraph is at the top of the viewport, given each paragraph's
/// offset from the top of the scroll extent.
///
/// [offsets] is ascending; the answer is the last paragraph that starts at or
/// above the reading line. Extracted as a pure function of measured offsets so
/// the mapping is testable without a laid-out widget tree — the reader's only
/// job is to measure.
int activeParagraphIndex(List<double> offsets, double readingLine) {
  if (offsets.isEmpty) return 0;
  var low = 0;
  var high = offsets.length - 1;
  var answer = 0;
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (offsets[mid] <= readingLine) {
      answer = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return answer;
}
