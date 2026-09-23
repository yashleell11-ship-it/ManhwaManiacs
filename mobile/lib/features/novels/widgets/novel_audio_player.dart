import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';

/// Playback for a rendered chapter, and the clock the highlight follows.
///
/// The URL is STREAMED rather than downloaded, because this client holds a
/// bearer token and can set its own headers. The server answers Range with a
/// 206, so playback starts on the first bytes and a seek pulls only what it
/// needs. The web player cannot do this — `mm_session` is httpOnly and
/// SameSite=lax, so a browser-managed media request to another origin never
/// carries it, and that player has to fetch the whole file through the JSON
/// client first.
///
/// A narration saved on the phone plays from [filePath] instead, with no
/// network and no token: that is what makes a chapter listenable on a plane.
///
/// [onPosition] fires on every tick. The reader takes it as a raw millisecond
/// count and does its own lookup rather than being handed a widget, so nothing
/// here decides how a chapter is drawn.
class NovelAudioPlayerBar extends StatefulWidget {
  const NovelAudioPlayerBar({
    required this.audio,
    required this.onPosition,
    required this.muted,
    required this.rule,
    this.url,
    this.headers = const {},
    this.filePath,
    super.key,
  }) : assert(
         url != null || filePath != null,
         'a player needs something to play',
       );

  /// Where to stream from when nothing is saved on the phone.
  final String? url;
  final Map<String, String> headers;

  /// The saved narration, when there is one. Wins over [url].
  final String? filePath;

  final NovelAudio audio;

  /// Playhead position, or null when nothing is playing.
  final ValueChanged<int?> onPosition;

  final Color muted;
  final Color rule;

  @override
  State<NovelAudioPlayerBar> createState() => _NovelAudioPlayerBarState();
}

class _NovelAudioPlayerBarState extends State<NovelAudioPlayerBar> {
  AudioPlayer? _player;
  bool _loading = false;
  bool _failed = false;
  Duration _position = Duration.zero;
  double _speed = 1;

  @override
  void dispose() {
    // Releases the platform player. Left undisposed, the audio keeps playing
    // after the reader is gone — which on iOS also keeps the audio session
    // active and silences everything else on the phone.
    _player?.dispose();
    widget.onPosition(null);
    super.dispose();
  }

  Future<void> _toggle() async {
    final existing = _player;
    if (existing != null) {
      if (existing.playing) {
        await existing.pause();
      } else {
        unawaited(existing.play());
      }
      return;
    }

    setState(() {
      _loading = true;
      _failed = false;
    });
    final player = AudioPlayer();
    try {
      // Nothing is fetched until here, so a reader who never presses play
      // never spends the bytes.
      final file = widget.filePath;
      if (file != null) {
        await player.setFilePath(file);
      } else {
        await player.setUrl(widget.url!, headers: widget.headers);
      }
    } catch (_) {
      // Audio is an addition to the page. A failure leaves the chapter
      // readable and says so, rather than breaking the reader.
      await player.dispose();
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
      return;
    }

    player.positionStream.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
      // The finish is reported as a position too, and it can land after the
      // null the state listener below sends for it. A finished player is
      // not reading, whatever its playhead says — and a file a few
      // milliseconds shorter than the map's total would otherwise look like
      // a voice with one breath left, holding auto-next off for good.
      widget.onPosition(
        player.processingState == ProcessingState.completed
            ? null
            : position.inMilliseconds,
      );
    });
    player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {});
      if (state.processingState == ProcessingState.completed) {
        // One sentence left lit after the voice stops reads as a bug.
        widget.onPosition(null);
      }
    });

    await player.setSpeed(_speed);
    if (!mounted) {
      await player.dispose();
      return;
    }
    setState(() {
      _player = player;
      _loading = false;
    });
    unawaited(player.play());
  }

  @override
  Widget build(BuildContext context) {
    final total = Duration(milliseconds: widget.audio.totalMs);
    final playing = _player?.playing ?? false;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: widget.rule),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: _loading ? null : _toggle,
            tooltip: _failed
                ? 'Audio could not be loaded'
                : playing
                    ? 'Pause'
                    : 'Listen to this chapter',
            icon: Icon(
              _failed
                  ? Icons.error_outline
                  : playing
                      ? Icons.pause
                      : Icons.play_arrow,
              color: widget.muted,
            ),
          ),
          Expanded(
            child: Slider(
              value: _position.inMilliseconds
                  .clamp(0, widget.audio.totalMs)
                  .toDouble(),
              max: (widget.audio.totalMs <= 0 ? 1 : widget.audio.totalMs)
                  .toDouble(),
              onChanged: (value) {
                final target = Duration(milliseconds: value.round());
                setState(() => _position = target);
                _player?.seek(target);
                widget.onPosition(target.inMilliseconds);
              },
            ),
          ),
          Text(
            '${_clock(_position)} / ${_clock(total)}',
            style: TextStyle(
              color: widget.muted,
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<double>(
            value: _speed,
            underline: const SizedBox.shrink(),
            isDense: true,
            style: TextStyle(color: widget.muted, fontSize: 12),
            items: const [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
                .map(
                  (v) => DropdownMenuItem(
                    value: v,
                    child: Text('${v.toString().replaceAll('.0', '')}x'),
                  ),
                )
                .toList(growable: false),
            onChanged: (value) {
              if (value == null) return;
              setState(() => _speed = value);
              _player?.setSpeed(value);
            },
          ),
        ],
      ),
    );
  }
}

/// m:ss, and h:mm:ss only when there is an hour to show.
///
/// Truncates rather than rounds: rounding would read a second ahead of the
/// voice.
String _clock(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final seconds = (total % 60).toString().padLeft(2, '0');
  final minutes = (total ~/ 60) % 60;
  final hours = total ~/ 3600;
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}
