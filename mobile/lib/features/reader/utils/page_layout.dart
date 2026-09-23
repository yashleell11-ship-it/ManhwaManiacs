import 'package:flutter/material.dart';
import 'package:manhwamaniacs/features/settings/models/reader_defaults.dart';

/// Widest a page is drawn at 1x zoom, so a phone-shaped strip is not stretched
/// across a tablet.
const double maxContentWidth = 768;

/// Ratio a page is laid out at until its real size is known. Chosen to look
/// like a print page rather than a webtoon strip, because guessing tall would
/// leave a screenful of empty backdrop under every short page.
const double defaultAspectRatio = 2 / 3;

BoxFit readerFitModeToBoxFit(ReaderFitMode mode) => switch (mode) {
      ReaderFitMode.width => BoxFit.fitWidth,
      ReaderFitMode.height => BoxFit.fitHeight,
      ReaderFitMode.screen => BoxFit.contain,
    };

bool isAtReadingStart({
  required double scrollOffset,
  required double viewport,
  required double maxScroll,
  required ReadingDirection direction,
}) {
  if (direction.isVertical) {
    return scrollOffset <= _scrollEdgeThreshold;
  }

  final atLeft = scrollOffset <= _scrollEdgeThreshold;
  final atRight =
      scrollOffset + viewport >= maxScroll - _scrollEdgeThreshold;
  return switch (direction) {
    ReadingDirection.leftToRight => atLeft,
    ReadingDirection.rightToLeft => atRight,
    ReadingDirection.vertical => atLeft,
  };
}

bool isAtReadingEnd({
  required double scrollOffset,
  required double viewport,
  required double maxScroll,
  required ReadingDirection direction,
}) {
  if (direction.isVertical) {
    return scrollOffset + viewport >= maxScroll - _scrollEdgeThreshold;
  }

  final atLeft = scrollOffset <= _scrollEdgeThreshold;
  final atRight =
      scrollOffset + viewport >= maxScroll - _scrollEdgeThreshold;
  return switch (direction) {
    ReadingDirection.leftToRight => atRight,
    ReadingDirection.rightToLeft => atLeft,
    ReadingDirection.vertical => atRight,
  };
}

/// Whether the list has been scrolled as far as it goes.
///
/// Stricter than [isAtReadingEnd], which is the edge prompt's test and is true
/// a whole viewport before the end. This one answers "has the reader seen the
/// last page": at the true end the last page is on screen in full, however
/// short it is, because the trailing padding below it is wider than the edge
/// allowed here. That is what the probe line cannot say for a short last page
/// — its top never reaches the line before the scroll runs out.
///
/// Scroll offset grows in reading order for every direction (a right-to-left
/// list is reversed rather than laid out backwards), so one comparison serves
/// them all.
bool isAtScrollEnd({
  required double scrollOffset,
  required double maxScroll,
}) =>
    scrollOffset >= maxScroll - _scrollEdgeThreshold;

const double _scrollEdgeThreshold = 48.0;

double resolveInitialScrollTop({
  required double? savedScroll,
  required int initialPage,
  required int pageCount,
  required double estimatedOffsetToPage,
}) {
  if (savedScroll != null) return savedScroll;
  if (initialPage > 1 && pageCount > 0) return estimatedOffsetToPage;
  return 0;
}
