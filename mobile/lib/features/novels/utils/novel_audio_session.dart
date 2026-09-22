import 'package:audio_session/audio_session.dart';
import 'package:manhwamaniacs/core/logging/app_logger.dart';

/// How the phone should treat the narration it plays: as spoken word.
///
/// just_audio would otherwise fall back to the MUSIC recipe. Both use the
/// playback category, which together with `UIBackgroundModes: audio` in
/// Info.plist is what keeps a chapter playing with the screen locked. The
/// difference is interruptions: under the spoken-audio mode a navigation
/// prompt or a voice note PAUSES the chapter instead of ducking it, because
/// a sentence talked over is a sentence lost, whereas a song talked over
/// is just quieter for a moment.
const AudioSessionConfiguration novelAudioSessionConfiguration =
    AudioSessionConfiguration.speech();

/// Applies [novelAudioSessionConfiguration] once, at startup.
///
/// Never throws and is never awaited in front of the first frame: a platform
/// that refuses the configuration still reads novels, it only keeps the
/// default recipe. Configuring does not ACTIVATE the session either, so an
/// app that never plays a chapter never takes audio focus from anything.
Future<void> configureNovelAudioSession() async {
  try {
    final session = await AudioSession.instance;
    await session.configure(novelAudioSessionConfiguration);
  } catch (error, stackTrace) {
    appLogger.w('Audio session configuration failed', error, stackTrace);
  }
}
