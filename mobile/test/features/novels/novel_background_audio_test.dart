/// Narration has to keep playing with the phone in a pocket.
///
/// Nothing a widget test renders can see this: iOS suspends the process when
/// the screen locks unless Info.plist declares the `audio` background mode,
/// and the audio session only decides what an interruption does. So these
/// check the two declarations themselves — the plist is read as the build
/// will read it, and the session recipe is the one main.dart applies.
library;

import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_audio_session.dart';

/// The `<array>` under [key] in a plist, as its `<string>` values.
List<String> _plistArray(String plist, String key) {
  final match = RegExp(
    '<key>${RegExp.escape(key)}</key>\\s*<array>(.*?)</array>',
    dotAll: true,
  ).firstMatch(plist);
  if (match == null) return const [];
  return RegExp('<string>(.*?)</string>')
      .allMatches(match.group(1)!)
      .map((m) => m.group(1)!)
      .toList();
}

void main() {
  test('Info.plist declares the audio background mode', () {
    // Without it the voice stops within a second of the screen locking, and
    // the highlight freezes on the last sentence.
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(_plistArray(plist, 'UIBackgroundModes'), contains('audio'));
  });

  test('the session plays in the background, as spoken word', () {
    const config = novelAudioSessionConfiguration;

    // Playback is the category that keeps sounding with the ringer switch
    // off and the screen locked.
    expect(config.avAudioSessionCategory, AVAudioSessionCategory.playback);
    // Spoken audio: a navigation prompt pauses the chapter rather than
    // talking over a sentence the listener then never hears.
    expect(config.avAudioSessionMode, AVAudioSessionMode.spokenAudio);
    expect(
      config.androidAudioAttributes?.contentType,
      AndroidAudioContentType.speech,
    );
    expect(config.androidWillPauseWhenDucked, isTrue);
  });
}
