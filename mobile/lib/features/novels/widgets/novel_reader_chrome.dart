import 'package:flutter/material.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_chapter_view.dart';
import 'package:manhwamaniacs/features/reader/widgets/immersive_safe_area.dart';

/// The novel reader's controls: a title bar and a footer, both painted in the
/// reading palette and both hidden until the page is tapped.
///
/// Uses [ImmersiveSafeArea], not [SafeArea], and that is not a stylistic
/// choice. This screen hides the system overlays, and when an overlay is
/// hidden the OS reports **no** inset for it — so `MediaQuery.padding`
/// collapses to zero while the Dynamic Island still physically covers the top
/// of the display. A bar padded by `SafeArea` slides underneath the cutout and
/// its Back button becomes unreachable. `viewPadding` reports the inset the
/// display imposes whether or not the overlay is drawn, which is what a
/// fullscreen surface has to respect.
class NovelReaderChrome extends StatelessWidget {
  const NovelReaderChrome({
    super.key,
    required this.visible,
    required this.surface,
    required this.title,
    required this.percent,
    required this.isOffline,
    required this.onBack,
    required this.onPrevious,
    required this.onNext,
    required this.onType,
    this.onContents,
    this.onBookmark,
    this.onCast,
    this.audio,
  });

  final bool visible;
  final NovelSurfaceColors surface;
  final String title;
  final int percent;

  /// Whether this chapter came off the phone rather than the network. Worth
  /// saying quietly: it explains why prev/next are missing.
  final bool isOffline;

  final VoidCallback onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onType;

  /// The book's contents, opened at this chapter. Previous and next were the
  /// only way to move through a book, and Shadow Slave has 3,188 chapters.
  /// Null only for a caller that has nowhere to list them.
  final VoidCallback? onContents;

  /// Who reads this book, and the chance to decide otherwise. Null when the
  /// chapter has no attribution to show.
  final VoidCallback? onCast;

  /// Save the exact spot being read, in one tap. Null while a save is already
  /// in flight, which is what disables the button rather than a separate flag.
  ///
  /// It sits in the top bar beside "Text and page" rather than in the footer
  /// with prev/next: those two are navigation, this is an action on the
  /// chapter — the same division the manga reader's chrome already makes.
  final VoidCallback? onBookmark;

  /// The chapter's player, when it has one.
  ///
  /// It lives here rather than at the foot of the prose because the foot is
  /// eighty paragraphs down: a reader resuming at 60% never reaches it, and a
  /// reader who has not scrolled has no way to know a voice exists.
  ///
  /// NOT unmounted when the chrome hides — [AnimatedOpacity] at opacity 0
  /// keeps the element alive, and the player disposes its platform handle in
  /// `dispose()`, so anything that unmounted it would stop the audio the
  /// moment the controls faded.
  ///
  /// A widget rather than the audio's arguments: this file knows nothing
  /// about providers or tokens and should carry on not knowing.
  final Widget? audio;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: Column(
          children: [
            _Bar(
              surface: surface,
              top: true,
              child: Row(
                children: [
                  IconButton(
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back),
                    color: surface.ink,
                    tooltip: 'Back',
                  ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: surface.ink,
                      ),
                    ),
                  ),
                  if (isOffline)
                    Padding(
                      padding: EdgeInsets.only(right: context.space.xs),
                      child: Icon(
                        Icons.cloud_off_rounded,
                        size: 18,
                        color: surface.muted,
                      ),
                    ),
                  IconButton(
                    key: const Key('novel-contents'),
                    onPressed: onContents,
                    icon: const Icon(Icons.toc_rounded),
                    color: onContents == null ? surface.rule : surface.ink,
                    tooltip: 'Contents',
                  ),
                  IconButton(
                    onPressed: onBookmark,
                    icon: const Icon(Icons.bookmark_add_outlined),
                    color: onBookmark == null ? surface.rule : surface.ink,
                    tooltip: 'Bookmark this spot',
                  ),
                  IconButton(
                    onPressed: onCast,
                    icon: const Icon(Icons.record_voice_over_outlined),
                    color: onCast == null ? surface.rule : surface.ink,
                    tooltip: 'Voices',
                  ),
                  IconButton(
                    onPressed: onType,
                    icon: const Icon(Icons.text_fields_rounded),
                    color: surface.ink,
                    tooltip: 'Text and page',
                  ),
                ],
              ),
            ),
            const Spacer(),
            if (audio != null) audio!,
            _Bar(
              surface: surface,
              top: false,
              child: Row(
                children: [
                  IconButton(
                    onPressed: onPrevious,
                    icon: const Icon(Icons.chevron_left_rounded),
                    color: onPrevious == null ? surface.rule : surface.ink,
                    tooltip: 'Previous chapter',
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        '$percent%',
                        style: TextStyle(
                          fontSize: 13,
                          color: surface.muted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onNext,
                    icon: const Icon(Icons.chevron_right_rounded),
                    color: onNext == null ? surface.rule : surface.ink,
                    tooltip: 'Next chapter',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.surface, required this.top, required this.child});

  final NovelSurfaceColors surface;
  final bool top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        // Opaque in the palette's own background, not a translucent scrim: a
        // frosted bar over cream paper reads as a smudge, and the prose has to
        // stop being visible under the controls for them to be controls.
        color: surface.bg,
        border: Border(
          top: top ? BorderSide.none : BorderSide(color: surface.rule),
          bottom: top ? BorderSide(color: surface.rule) : BorderSide.none,
        ),
      ),
      child: ImmersiveSafeArea(
        top: top,
        bottom: !top,
        child: SizedBox(height: 52, child: child),
      ),
    );
  }
}
