/// Which container a chapter's narration travels in, and which one this phone
/// can play.
///
/// The server stores every render as Ogg Opus, and that is all it served
/// until iPhones were found to play none of it: AVPlayer — what just_audio
/// drives on iOS — cannot read the Ogg container at all, whatever the codec
/// inside. `GET /novels/audio/file?format=m4a` answers the same render as
/// AAC in an MP4 container, which every Apple player reads. Android's
/// ExoPlayer reads both, so it keeps the smaller, original Opus.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

enum NovelAudioFormat {
  /// Ogg Opus, as rendered. The server's default.
  ogg('ogg', '.ogg'),

  /// AAC-LC in an MP4 container, made from the Opus on the server.
  m4a('m4a', '.m4a');

  const NovelAudioFormat(this.wire, this.extension);

  /// The `format` query value `GET /novels/audio/file` takes.
  final String wire;

  /// What a file holding this format must be named with on a player that
  /// goes by the name rather than the bytes.
  final String extension;
}

/// The format to ask the server for on [platform].
///
/// Takes the platform rather than reading it, so a test can ask for both;
/// callers pass `defaultTargetPlatform`, which is what the rest of the app
/// decides platform behaviour by.
NovelAudioFormat novelAudioFormatFor(TargetPlatform platform) =>
    platform == TargetPlatform.iOS ? NovelAudioFormat.m4a : NovelAudioFormat.ogg;

/// Whether a player on [platform] can play [format] at all. `null` — bytes
/// that are neither — plays nowhere.
///
/// Separate from [novelAudioFormatFor] because it is asked of bytes already
/// on the phone: a narration saved on an iPhone before the server could
/// convert is Ogg, and has to be recognised as unplayable there rather than
/// handed to a player that fails with no explanation.
bool canPlayNovelAudio(NovelAudioFormat? format, TargetPlatform platform) {
  if (format == null) return false;
  if (platform == TargetPlatform.iOS) return format == NovelAudioFormat.m4a;
  return true;
}

/// Whether the player on [platform] decides what a local file is from its
/// NAME. AVPlayer infers the type from the path's extension, and a saved
/// blob is named by its hash with none, so on iOS it has to be played from
/// a path that says what it is. ExoPlayer sniffs the bytes.
bool playsByExtension(TargetPlatform platform) =>
    platform == TargetPlatform.iOS;

/// What [head] — the first bytes of a narration — actually is.
///
/// Read from the bytes rather than trusted from the request: a server from
/// before `format` existed ignores the parameter and answers Ogg, and a file
/// saved before this check existed carries no record of what it is. Both
/// containers announce themselves in their first twelve bytes: an Ogg page
/// starts `OggS`, and an MP4 file's first box is `ftyp` at offset 4.
NovelAudioFormat? sniffNovelAudioFormat(List<int> head) {
  bool at(int offset, String tag) {
    if (head.length < offset + tag.length) return false;
    for (var i = 0; i < tag.length; i++) {
      if (head[offset + i] != tag.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (at(0, 'OggS')) return NovelAudioFormat.ogg;
  if (at(4, 'ftyp')) return NovelAudioFormat.m4a;
  return null;
}

/// [sniffNovelAudioFormat] on a file, reading only its first twelve bytes.
/// A file that cannot be read is `null`, the same as one that is neither.
Future<NovelAudioFormat?> sniffNovelAudioFile(File file) async {
  try {
    final head = <int>[];
    await for (final chunk in file.openRead(0, 12)) {
      head.addAll(chunk);
    }
    return sniffNovelAudioFormat(head);
  } catch (_) {
    return null;
  }
}

/// The query `GET /novels/audio/file` is asked with, for streaming and for
/// saving alike, so the two cannot drift apart.
///
/// Query parameters, never path segments: connector keys are opaque and
/// routinely contain slashes. `format` is sent only when it is not the
/// server's default, so what Android asks for is exactly what it always did.
Map<String, String> novelAudioFileQuery({
  required String sourceId,
  required String seriesKey,
  required String chapterKey,
  required NovelAudioFormat format,
}) =>
    {
      'source': sourceId,
      'series': seriesKey,
      'chapter': chapterKey,
      if (format != NovelAudioFormat.ogg) 'format': format.wire,
    };
