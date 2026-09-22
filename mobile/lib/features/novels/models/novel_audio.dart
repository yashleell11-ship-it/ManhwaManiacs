/// A rendered chapter's audio, and the map that follows along with it.
///
/// Built from `GET /novels/audio?source=&series=&chapter=`. Almost nothing in
/// the library is rendered, so [available] false is the ordinary answer and
/// never an error.
library;

/// One rendered sentence.
///
/// The timings are MEASURED, not estimated: each segment was rendered on its
/// own, so its duration is the length of the samples that came back. That is
/// why the map is contiguous and why the highlight cannot drift from the
/// voice — there is nothing here for an estimate to be wrong about.
class NovelAudioSegment {
  const NovelAudioSegment({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.paragraph,
    required this.start,
    required this.end,
    required this.isSpeech,
    this.speaker,
  });

  factory NovelAudioSegment.fromJson(Map<String, dynamic> json) {
    return NovelAudioSegment(
      index: (json['i'] as num?)?.toInt() ?? 0,
      startMs: (json['start_ms'] as num?)?.toInt() ?? 0,
      endMs: (json['end_ms'] as num?)?.toInt() ?? 0,
      paragraph: (json['p'] as num?)?.toInt() ?? 0,
      start: (json['s'] as num?)?.toInt() ?? 0,
      end: (json['e'] as num?)?.toInt() ?? 0,
      isSpeech: json['speech'] == true,
      speaker: json['speaker'] as String?,
    );
  }

  /// The wire shape [NovelAudioSegment.fromJson] reads, so a map saved with
  /// the audio on the phone reads back exactly as the server sent it.
  Map<String, dynamic> toJson() => {
        'i': index,
        'start_ms': startMs,
        'end_ms': endMs,
        'p': paragraph,
        's': start,
        'e': end,
        'speech': isSpeech,
        if (speaker != null) 'speaker': speaker,
      };

  final int index;
  final int startMs;
  final int endMs;

  /// Paragraph index, and offsets within it, so a reader can highlight exactly
  /// the words being spoken.
  final int paragraph;
  final int start;
  final int end;

  final bool isSpeech;
  final String? speaker;
}

class NovelAudio {
  const NovelAudio({
    required this.available,
    required this.totalMs,
    required this.bytes,
    required this.segments,
  });

  factory NovelAudio.fromJson(Map<String, dynamic> json) {
    final raw = json['segments'];
    return NovelAudio(
      available: json['available'] == true,
      totalMs: (json['total_ms'] as num?)?.toInt() ?? 0,
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      segments: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(NovelAudioSegment.fromJson)
              .toList(growable: false)
          : const <NovelAudioSegment>[],
    );
  }

  /// What is saved beside a chapter's audio on the phone.
  ///
  /// The timing map belongs to ONE render, and the server's copy is replaced
  /// when a chapter is re-rendered. Keeping the map the saved audio was made
  /// with, rather than asking the server again at play time, is what keeps
  /// the highlight on the words being spoken — and what makes it work with
  /// no network at all.
  Map<String, dynamic> toJson() => {
        'available': available,
        'total_ms': totalMs,
        'bytes': bytes,
        'segments': [for (final segment in segments) segment.toJson()],
      };

  static const NovelAudio none = NovelAudio(
    available: false,
    totalMs: 0,
    bytes: 0,
    segments: <NovelAudioSegment>[],
  );

  final bool available;
  final int totalMs;
  final int bytes;
  final List<NovelAudioSegment> segments;

  /// Index into [segments] of the sentence being spoken at [positionMs], or
  /// -1 for none.
  ///
  /// A binary search, because this runs on every position tick against a
  /// chapter of several hundred segments. It is only safe because the map is
  /// contiguous and monotonic, which is a property of how it was rendered
  /// rather than an assumption — see the tests.
  ///
  /// Half-open: a segment owns `[startMs, endMs)`. At an exact boundary the
  /// LATER segment wins, which is what stops the highlight sitting a beat
  /// behind the voice at every sentence break.
  int segmentAt(int positionMs) {
    if (segments.isEmpty) return -1;
    if (positionMs < segments.first.startMs) return -1;
    if (positionMs >= segments.last.endMs) return -1;

    var low = 0;
    var high = segments.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final segment = segments[mid];
      if (positionMs < segment.startMs) {
        high = mid - 1;
      } else if (positionMs >= segment.endMs) {
        low = mid + 1;
      } else {
        return mid;
      }
    }
    // A gap. Contiguous maps have none, but landing in one is not an error —
    // it means "highlight nothing", which is always a safe answer.
    return -1;
  }

  /// Whether this map still describes [paragraphs].
  ///
  /// The chapter cache refetches, so the text a render was made from will
  /// eventually be replaced. Highlighting against offsets that no longer fit
  /// would light up the wrong words, which is worse than not highlighting:
  /// it tells the reader the app is confused about its own book.
  bool matchesText(List<String> paragraphs) {
    if (segments.isEmpty) return false;
    for (final segment in segments) {
      if (segment.paragraph < 0 || segment.paragraph >= paragraphs.length) {
        return false;
      }
      final text = paragraphs[segment.paragraph];
      if (segment.start < 0 ||
          segment.end > text.length ||
          segment.end <= segment.start) {
        return false;
      }
    }
    return true;
  }
}
