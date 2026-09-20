/// Parsing the cast and the voice roster.
///
/// The shapes here decide what a person is offered when they cast a book, so
/// what matters is the degenerate cases: a server with no pack, a voice with
/// no name, a chapter nobody has attributed. Every one of them has to come
/// back as a usable empty rather than as a crash in a reading app.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/novels/models/novel_cast.dart';

void main() {
  group('NovelAttribution', () {
    test('reads the cast, the narrator and the pinned narration voice', () {
      final got = NovelAttribution.fromJson({
        'attributed': true,
        'narrator': 'Arthur',
        'narrator_voice_id': 'libritts-2803',
        'cast': [
          {'name': 'Tessia', 'gender': 'female', 'voice_id': 'libritts-84'},
          {'name': 'Wren', 'gender': 'male', 'voice_id': null},
        ],
      });

      expect(got.attributed, isTrue);
      expect(got.narrator, 'Arthur');
      expect(got.narratorVoiceId, 'libritts-2803');
      expect(got.cast.map((m) => m.name), ['Tessia', 'Wren']);
      // Null is "reads in the narrator's voice", a real state and not missing
      // data.
      expect(got.cast.last.voiceId, isNull);
    });

    test('an unattributed chapter is an ordinary empty, not an error', () {
      // Almost the whole library. A reader opening a chapter must not walk an
      // error path for the common case.
      final got = NovelAttribution.fromJson({
        'attributed': false,
        'cast': <dynamic>[],
        'narrator': null,
        'narrator_voice_id': null,
      });

      expect(got.attributed, isFalse);
      expect(got.cast, isEmpty);
      expect(got.narratorVoiceId, isNull);
    });

    test('a nameless cast row is dropped rather than shown blank', () {
      // It would render as an empty row with a voice picker attached to
      // nobody.
      final got = NovelAttribution.fromJson({
        'attributed': true,
        'cast': [
          {'name': '', 'gender': 'male', 'voice_id': 'v1'},
          {'name': 'Arthur', 'gender': 'male', 'voice_id': 'v2'},
        ],
      });

      expect(got.cast.map((m) => m.name), ['Arthur']);
    });

    test('a junk payload does not crash the reader', () {
      final got = NovelAttribution.fromJson({'cast': 'not a list'});

      expect(got.attributed, isFalse);
      expect(got.cast, isEmpty);
    });

    test('gender defaults to unknown, which routes to the narrator', () {
      // "unknown" is a real value meaning the text never said, and guessing
      // would be wrong on every line that character speaks.
      final got = NovelCastMember.fromJson({'name': 'Caria'});

      expect(got.gender, 'unknown');
      expect(got.voiceId, isNull);
    });
  });

  group('NovelVoice', () {
    test('carries what a person actually chooses on', () {
      final got = NovelVoice.fromJson({
        'voice_id': 'libritts-2803',
        'name': 'Atlas',
        'character': 'deep, lively',
        'gender': 'male',
        'pitch_hz': 103.0,
        'seconds': 19.4,
      });

      expect(got.name, 'Atlas');
      expect(got.character, 'deep, lively');
      expect(got.pitchHz, 103.0);
      expect(got.seconds, 19.4);
    });

    test('falls back to the id when a pack carries no names', () {
      // An older pack is still usable — the picker just shows the raw id
      // rather than rendering a blank row.
      for (final raw in [
        {'voice_id': 'libritts-251'},
        {'voice_id': 'libritts-251', 'name': ''},
        {'voice_id': 'libritts-251', 'name': '   '},
      ]) {
        expect(NovelVoice.fromJson(raw).name, 'libritts-251', reason: '$raw');
      }
    });

    test('a missing pitch is zero rather than a crash', () {
      expect(NovelVoice.fromJson({'voice_id': 'v1'}).pitchHz, 0);
    });
  });
}
