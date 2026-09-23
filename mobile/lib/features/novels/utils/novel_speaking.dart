/// Which words the voice is on, and how to light them without repainting the
/// chapter.
///
/// Kept out of the widgets for the same reason [activeParagraphIndex] and
/// [splitDropCap] are: what gets highlighted is a decision about offsets, and
/// offsets are testable without a render tree.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';

/// The words being spoken right now: which paragraph, and the character range
/// within it.
///
/// A range rather than a segment index, because this renderer is a [TextSpan]
/// tree and not a DOM that can be queried by attribute — the web finds a
/// `[data-segment]` node, this has to split the string itself.
typedef NovelSpeakingRange = ({int paragraph, int start, int end});

/// A stretch of paragraph text and the style it is set in.
typedef NovelRun = ({String text, TextStyle? style});

/// What the voice has done with a stretch of text.
enum NovelSpeechMark {
  /// Not reached yet.
  none,

  /// Already read. It stays marked for the rest of the chapter, so the page
  /// shows how far the voice has got at a glance — the reason a reader can
  /// look away and find their place again without scrubbing.
  done,

  /// Being read right now.
  speaking,
}

/// A run after the playhead has been laid over it.
typedef NovelSpokenRun = ({String text, TextStyle? style, NovelSpeechMark mark});

/// Mark [runs] up: everything before [doneEnd] read, `[start, end)` speaking.
///
/// The three regions are ordered and non-overlapping — `doneEnd <= start` —
/// because that is what the timing map is: contiguous, monotonic, one sentence
/// after another. A paragraph the voice has passed entirely is `doneEnd =
/// length` with no spoken range; one it has not reached is all zeroes.
///
/// Refuses rather than guesses. A range that does not fit the text comes back
/// unmarked, because a highlight on the wrong words is worse than no highlight
/// at all: it tells the reader the app has lost track of its own book.
/// [NovelAudio.matchesText] is the first line of defence; this is the second,
/// and it is what makes the drop-cap path — whose text is TRIMMED, so every
/// offset shifts — safe to hand a raw server range.
List<NovelSpokenRun> markSpokenRuns(
  List<NovelRun> runs, {
  required int doneEnd,
  required int start,
  required int end,
}) {
  final length = runs.fold<int>(0, (sum, run) => sum + run.text.length);
  final speaks = end > start;
  final valid = doneEnd >= 0 &&
      doneEnd <= length &&
      (!speaks || (start >= doneEnd && start >= 0 && end <= length));
  if (!valid) return _unmarked(runs);
  if (doneEnd == 0 && !speaks) return _unmarked(runs);

  NovelSpeechMark markAt(int offset) {
    if (offset < doneEnd) return NovelSpeechMark.done;
    if (speaks && offset >= start && offset < end) {
      return NovelSpeechMark.speaking;
    }
    return NovelSpeechMark.none;
  }

  // Cut points, in order: every place the mark can change.
  final cuts = <int>{0, doneEnd, length};
  if (speaks) cuts.addAll([start, end]);
  final ordered = cuts.where((c) => c >= 0 && c <= length).toList()..sort();

  final out = <NovelSpokenRun>[];
  var cursor = 0;
  for (final run in runs) {
    final runStart = cursor;
    final runEnd = cursor + run.text.length;
    cursor = runEnd;
    var piece = runStart;
    for (final cut in ordered) {
      if (cut <= piece || cut >= runEnd) continue;
      out.add(
        (
          text: run.text.substring(piece - runStart, cut - runStart),
          style: run.style,
          mark: markAt(piece),
        ),
      );
      piece = cut;
    }
    // Empty pieces are never emitted: an empty TextSpan is still a node
    // RenderParagraph has to walk, once per paragraph per frame.
    if (piece < runEnd) {
      out.add(
        (
          text: run.text.substring(piece - runStart),
          style: run.style,
          mark: markAt(piece),
        ),
      );
    }
  }
  return out;
}

List<NovelSpokenRun> _unmarked(List<NovelRun> runs) => [
      for (final run in runs)
        (text: run.text, style: run.style, mark: NovelSpeechMark.none),
    ];

/// What the chapter says under "Listen" when the page will NOT follow the
/// voice, or null when it will.
///
/// The highlight is the feature a reader has learned to expect from a
/// narrated chapter, so its absence is said out loud rather than left to
/// look like a bug the moment play is pressed.
String? novelFollowAlongNote(NovelAudio audio, List<String> paragraphs) =>
    audio.followsText(paragraphs)
        ? null
        : 'Audio only: this narration may not match the text on the page, '
            'so the page will not follow along.';

/// Turns a stream of playhead positions into "these words, in this paragraph".
///
/// Deliberately not a widget and deliberately not `setState`: `just_audio`'s
/// position stream ticks far more often than the web's ~4 Hz `timeupdate`, and
/// the one performance bug this reader has already had to be fixed for was
/// rebuilding the prose on a high-frequency value.
class NovelAudioFollower {
  NovelAudioFollower(this._paragraphs);

  final List<String> _paragraphs;

  /// The words being spoken, for whichever paragraph is rendering them.
  final ValueNotifier<NovelSpeakingRange?> range =
      ValueNotifier<NovelSpeakingRange?>(null);

  /// Whether a voice is reading this chapter — playing, or paused part way —
  /// whether or not anything on the page is lit.
  ///
  /// Not the same question as [range]. Audio the page cannot follow (see
  /// [NovelAudio.followsText]) plays with no range at all, and a reader that
  /// took "nothing lit" for "nothing playing" would continue to the next
  /// chapter under a listener who is mid-sentence.
  final ValueNotifier<bool> voicing = ValueNotifier<bool>(false);

  /// The last segment published. The cheapest possible no-op: the playhead
  /// reports the same sentence many times before it moves on, and every one of
  /// those ticks would otherwise notify a paragraph into rebuilding.
  int _segment = -1;

  /// [NovelAudio.followsText] walks every segment — several hundred on a long
  /// chapter — so it is answered once per map instance rather than once per
  /// tick. The provider hands out the same instance until it refetches, and a
  /// refetch is exactly when the answer can change.
  NovelAudio? _checked;
  bool _follows = false;

  void onPosition(int? positionMs, NovelAudio audio) {
    voicing.value = positionMs != null && !_atEnd(positionMs, audio);
    if (positionMs == null || !_canFollow(audio)) {
      _publish(-1, audio);
      return;
    }
    _publish(audio.segmentAt(positionMs), audio);
  }

  /// Whether [positionMs] is the end of the audio rather than a place in it.
  ///
  /// The player reports the finish as a position too — just_audio's position
  /// stream fires on the completion event with the full duration — and it
  /// can arrive AFTER the null the player bar sends for the same finish: the
  /// two come through different streams, with no order between them. Taken
  /// for a voice still reading, it would leave [voicing] true for good, and
  /// auto-next would never fire on a chapter listened to the end. [range]
  /// never had this problem because [NovelAudio.segmentAt] already answers
  /// -1 from the last segment's end on.
  ///
  /// The later of the two ends the map knows: a map with no total, or one
  /// whose last sentence runs past it, still has an end.
  static bool _atEnd(int positionMs, NovelAudio audio) {
    final lastEnd = audio.segments.isEmpty ? 0 : audio.segments.last.endMs;
    final end = audio.totalMs > lastEnd ? audio.totalMs : lastEnd;
    return end > 0 && positionMs >= end;
  }

  bool _canFollow(NovelAudio audio) {
    if (!identical(audio, _checked)) {
      _checked = audio;
      _follows = audio.followsText(_paragraphs);
    }
    return _follows;
  }

  void _publish(int segment, NovelAudio audio) {
    if (segment == _segment) return;
    _segment = segment;
    if (segment < 0 || segment >= audio.segments.length) {
      range.value = null;
      return;
    }
    final spoken = audio.segments[segment];
    range.value = (
      paragraph: spoken.paragraph,
      start: spoken.start,
      end: spoken.end,
    );
  }

  void dispose() {
    range.dispose();
    voicing.dispose();
  }
}
