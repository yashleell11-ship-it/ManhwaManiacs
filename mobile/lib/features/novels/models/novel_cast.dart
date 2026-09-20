/// Who speaks in a chapter, and in whose voice.
///
/// Only what decides how a line SOUNDS lives here: a name, a gender, a voice
/// id, and the roster to choose from. `frontend/AGENTS.md` records that
/// character/world/timeline extraction was permanently abandoned and must
/// never come back, and a "cast" is one field away from being exactly that. A
/// description, a relationship, a first appearance would all be the abandoned
/// thing wearing a different hat.
library;

/// One character who can be given a voice.
class NovelCastMember {
  const NovelCastMember({
    required this.name,
    required this.gender,
    required this.voiceId,
  });

  factory NovelCastMember.fromJson(Map<String, dynamic> json) {
    return NovelCastMember(
      name: (json['name'] as String?) ?? '',
      gender: (json['gender'] as String?) ?? 'unknown',
      voiceId: json['voice_id'] as String?,
    );
  }

  final String name;

  /// From accumulated pronoun counts, never from the name — web-novel casts
  /// are transliterated and a guess is wrong on every line that character
  /// speaks. `unknown` is a real value that routes to the narrator.
  final String gender;

  /// Null means this character reads in the narrator's voice.
  final String? voiceId;
}

/// One voice a character can be given.
class NovelVoice {
  const NovelVoice({
    required this.voiceId,
    required this.name,
    required this.character,
    required this.gender,
    required this.pitchHz,
    required this.seconds,
  });

  factory NovelVoice.fromJson(Map<String, dynamic> json) {
    final id = (json['voice_id'] as String?) ?? '';
    return NovelVoice(
      voiceId: id,
      // A person cannot choose between libritts-2803 and libritts-251; they
      // can choose between Atlas and Lucian.
      name: switch ((json['name'] as String?)?.trim()) {
        final String n when n.isNotEmpty => n,
        _ => id,
      },
      character: (json['character'] as String?) ?? '',
      gender: (json['gender'] as String?) ?? 'unknown',
      pitchHz: (json['pitch_hz'] as num?)?.toDouble() ?? 0,
      seconds: (json['seconds'] as num?)?.toDouble() ?? 0,
    );
  }

  final String voiceId;

  /// What the picker calls it, and what the sample hears itself called.
  final String name;

  /// Two words on how it reads — "deep, steady".
  final String character;
  final String gender;

  /// The one number that orders the list the way people ask for it.
  final double pitchHz;

  /// How long the introduction runs.
  final double seconds;
}

/// A chapter's attribution: who speaks, and the voices in play.
class NovelAttribution {
  const NovelAttribution({
    required this.attributed,
    required this.narrator,
    required this.narratorVoiceId,
    required this.cast,
  });

  factory NovelAttribution.fromJson(Map<String, dynamic> json) {
    final raw = json['cast'];
    return NovelAttribution(
      attributed: json['attributed'] == true,
      narrator: json['narrator'] as String?,
      narratorVoiceId: json['narrator_voice_id'] as String?,
      cast: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(NovelCastMember.fromJson)
              .where((member) => member.name.isNotEmpty)
              .toList(growable: false)
          : const <NovelCastMember>[],
    );
  }

  /// An unattributed chapter is the ORDINARY case, not an error: almost
  /// nothing in the library has been through the pass.
  static const NovelAttribution none = NovelAttribution(
    attributed: false,
    narrator: null,
    narratorVoiceId: null,
    cast: <NovelCastMember>[],
  );

  final bool attributed;

  /// Who narrates this chapter, when it is known.
  final String? narrator;

  /// The series' pinned narration voice, or null to use the derived default.
  final String? narratorVoiceId;

  final List<NovelCastMember> cast;
}
