/// The book-shaped presentation logic the novel screens lead with.
///
/// A manga screen is poster-led: the cover carries the identity and the
/// metadata is a caption under it. Novels have weak cover art — an
/// aggregator's generated placeholder, more often than not — and strong
/// metadata, so the novel screens invert that: title, author, length. This
/// file owns the parts of that inversion that are decisions rather than
/// widgets, so they can be tested without pumping a widget tree.
///
/// Carried across from `frontend/src/features/novels/book.ts`; the rules are
/// the same, the formatting is Dart's.
library;

import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/utils/chapter_label.dart';
import 'package:manhwamaniacs/shared/widgets/series_detail/series_chapter_sort.dart';

// --- Front matter -----------------------------------------------------------

/// "by Neil Gaiman", or null when the source did not name an author.
String? byline(String? author) {
  final trimmed = author?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : 'by $trimmed';
}

/// "412 chapters" / "1 chapter"; null for a source that did not say.
String? formatChapterCount(int? count) {
  if (count == null || count <= 0) return null;
  return '${formatThousands(count)} ${count == 1 ? 'chapter' : 'chapters'}';
}

/// "ongoing" → "Ongoing". Sources are inconsistent about case and the status
/// is set beside a byline, where a lowercase word reads as a typo.
String? formatStatus(String? status) {
  final trimmed = status?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed[0].toUpperCase() + trimmed.substring(1);
}

/// A blurb trimmed to a shelf row.
///
/// The line clamp itself is the widget's, but the whitespace is not:
/// connectors hand back descriptions with newlines and runs of spaces left in
/// from the source's markup, and those turn a two-line clamp into a two-line
/// gap.
String? shelfBlurb(String? description) {
  final collapsed = description?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (collapsed == null || collapsed.isEmpty) ? null : collapsed;
}

/// Genres, capped and de-duplicated.
///
/// Novel aggregators tag generously — twenty genres on one book is normal —
/// and a row that wraps to four lines of tags is a row nobody reads. Six is
/// enough to characterise a book; the front matter shows the rest.
const int kMaxShelfGenres = 6;

List<String> shelfGenres(Iterable<String>? genres, {int limit = kMaxShelfGenres}) {
  final seen = <String>{};
  final out = <String>[];
  for (final genre in genres ?? const <String>[]) {
    final trimmed = genre.trim();
    if (trimmed.isEmpty) continue;
    if (!seen.add(trimmed.toLowerCase())) continue;
    out.add(trimmed);
    if (out.length >= limit) break;
  }
  return out;
}

/// `1234567` → `1,234,567`. Dart has no `toLocaleString`, and a six-figure
/// word count run together is a number nobody can read at a glance.
String formatThousands(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

// --- Whole-book length estimate ---------------------------------------------

/// How long the whole book is, projected from the chapters actually measured.
///
/// There is no bulk word-count endpoint and no `word_count` on a chapter
/// listing, so the only real numbers available are the chapters whose text has
/// been fetched — anything already read or downloaded. This projects the mean
/// of that sample across the catalogue.
///
/// It is an ESTIMATE and the UI says so. Two guards keep it from being a
/// fabrication: it refuses to project from fewer than [kMinLengthSample]
/// measured chapters, and it reports [sampleSize] so the caller can qualify
/// the number ("from 5 chapters") rather than presenting it as a fact.
const int kMinLengthSample = 2;

class SeriesLengthEstimate {
  const SeriesLengthEstimate({
    required this.chapters,
    required this.sampleSize,
    required this.meanWords,
    required this.totalWords,
    required this.minutes,
  });

  /// Chapters the source reports, 0 when it reports none.
  final int chapters;

  /// How many chapters the mean was taken over.
  final int sampleSize;

  /// Mean words per measured chapter, or null with too small a sample.
  final int? meanWords;

  /// Projected words for the whole series, or null when not projectable.
  final int? totalWords;

  /// Projected reading minutes for the whole series, or null.
  final int? minutes;
}

SeriesLengthEstimate estimateSeriesLength(
  int? chapterCount,
  Iterable<int> sampledWordCounts,
) {
  final chapters = (chapterCount != null && chapterCount > 0) ? chapterCount : 0;

  var total = 0;
  var sampleSize = 0;
  for (final words in sampledWordCounts) {
    if (words <= 0) continue;
    total += words;
    sampleSize += 1;
  }

  if (sampleSize < kMinLengthSample || chapters == 0) {
    return SeriesLengthEstimate(
      chapters: chapters,
      sampleSize: sampleSize,
      meanWords: null,
      totalWords: null,
      minutes: null,
    );
  }

  final meanWords = (total / sampleSize).round();
  final totalWords = meanWords * chapters;
  return SeriesLengthEstimate(
    chapters: chapters,
    sampleSize: sampleSize,
    meanWords: meanWords,
    totalWords: totalWords,
    minutes: (totalWords / kWordsPerMinute).round().clamp(1, 1 << 30),
  );
}

/// "≈ 61 h" for a whole-book estimate, or null when there is nothing to
/// project from. Hours only — nobody plans a 400-chapter novel to the minute,
/// and a spurious "≈ 61 h 14 min" would claim a precision the sample does not
/// have.
String? formatEstimatedTotal(SeriesLengthEstimate estimate) {
  final minutes = estimate.minutes;
  if (minutes == null) return null;
  final hours = minutes / 60;
  if (hours < 1) return '≈ ${minutes < 1 ? 1 : minutes} min';
  return '≈ ${formatThousands(hours.round())} h';
}

/// "≈ 1.1M words" / "≈ 84k words" for a projected total.
///
/// Rounded hard on purpose: this is a projection from a handful of chapters,
/// and "≈ 1,043,217 words" would read as a count.
String? formatEstimatedWords(SeriesLengthEstimate estimate) {
  final total = estimate.totalWords;
  if (total == null || total <= 0) return null;
  if (total >= 1000000) {
    return '≈ ${(total / 1000000).toStringAsFixed(1)}M words';
  }
  if (total >= 10000) {
    return '≈ ${formatThousands((total / 1000).round())}k words';
  }
  return '≈ ${formatThousands((total / 100).round() * 100)} words';
}

// --- Table of contents ------------------------------------------------------

class TocEntry {
  const TocEntry({required this.ordinal, required this.title});

  /// The number column: "12", "12.5", or null for an unnumbered chapter.
  final String? ordinal;

  /// The chapter's own title, or null when it has nothing but a number.
  final String? title;
}

/// One line of a table of contents: a number column and a title.
///
/// A download-style row list writes "Chapter 12" and then, underneath,
/// "Chapter 12: The Gate Opens". A table of contents sets the number in its
/// own column and the title beside it, once. The de-duplication that makes
/// that possible is [chapterLabel]'s and is reused rather than re-derived —
/// sources embed the number in the title in half a dozen shapes and that
/// function already knows all of them.
TocEntry tocEntry({required double? number, required String? title}) {
  final label = chapterLabel(number: number, title: title);
  if (number == null) {
    return TocEntry(ordinal: null, title: label.primary);
  }
  return TocEntry(ordinal: formatChapterNumber(number), title: label.secondary);
}

/// "12" / "12.5" — a whole number never renders its ".0".
String formatChapterNumber(double value) {
  if (value.isNaN || value.isInfinite) return '';
  return value % 1 == 0 ? value.toInt().toString() : value.toString();
}

// --- Go to chapter ----------------------------------------------------------

/// "Chapter 120", "Ch. 45", "c-1: Prologue" — the number a source writes at
/// the front of a title, behind a word for "chapter". "Chapter 12.5" is read
/// whole.
final RegExp _wordPrefix = RegExp(
  r'^\s*(?:chapter|chap|ch|c)\s*\.?\s*[-#]?\s*(\d+(?:\.\d+)?)(?!\d)',
  caseSensitive: false,
);

/// Royal Road's "1. Good Morning Brother", novelbin's "12 - " — a bare number
/// and a separator. The web's `BARE_ORDINAL_PREFIX` (`chapter-label.ts`); the
/// lookahead keeps "12.5 Special" from reading as 12.
final RegExp _bareOrdinalPrefix =
    RegExp(r'^\s*(\d+(?:\.\d+)?)\s*[.):\-–—]\s*(?=\D|$)');

/// A title that is nothing but a number.
final RegExp _bareNumber = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*$');

/// "Volume 2 Chapter 15: Return" — the word, anywhere in the title.
final RegExp _wordAnywhere = RegExp(
  r'\b(?:chapter|ch\.?)\s*[-#:]?\s*(\d+(?:\.\d+)?)(?!\d)',
  caseSensitive: false,
);

/// The chapter number a reader would say — the one printed in the title.
///
/// Novel chapter keys and `number` are ROW ORDINALS, not the book's own
/// numbering: TBATE's prologue is row 1 and a side story takes another row,
/// so "Chapter 120" is row 122 there. A reader asking for chapter 120 means
/// the title, so this reads the title first — in the shapes the novel sources
/// actually write — and falls back to the row ordinal only for a title that
/// carries no number at all ("Side Story: Sylvie"). Nothing is ever parsed
/// out of, or computed into, a chapter KEY.
///
/// The web's `printedChapterNumber` (`book.ts`) is the same rule; both answer
/// `backend/tests/fixtures/reading_navigation_cases.json`.
double? printedChapterNumber({required String? title, required double? number}) {
  final text = title ?? '';
  for (final pattern in [
    _wordPrefix,
    _bareOrdinalPrefix,
    _bareNumber,
    _wordAnywhere,
  ]) {
    final match = pattern.firstMatch(text);
    if (match != null) return double.parse(match.group(1)!);
  }
  return number;
}

/// The number in whatever was typed — "120", "ch 120", "Chapter 529" — or
/// null.
double? goToChapterQuery(String query) {
  final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(query);
  return match == null ? null : double.parse(match.group(1)!);
}

/// Every chapter whose printed number is what was typed, in reading order.
///
/// A LIST, never a single answer: printed numbers are not unique. TBATE's
/// rows 531 and 532 are both titled "Chapter 529", and "1" is both the
/// prologue ("c-1: Prologue") and chapter one — so the caller shows each with
/// its row and the reader picks. Works only from the chapter list already in
/// hand, one regex pass per chapter: nothing for Shadow Slave's 3,188, and no
/// source traffic.
List<SourceChapterSummary> goToChapterMatches(
  List<SourceChapterSummary> chapters,
  String query,
) {
  final wanted = goToChapterQuery(query);
  if (wanted == null) return const [];
  return [
    for (final chapter in sortSeriesChapters(
      chapters,
      numberOf: (chapter) => chapter.number,
      order: SeriesChapterSortOrder.oldest,
    ))
      if (printedChapterNumber(title: chapter.title, number: chapter.number) ==
          wanted)
        chapter,
  ];
}

/// Where a fixed-height contents list starts so [index] is in view with
/// [rowsAbove] rows of context over it.
///
/// Fixed row heights are what make this arithmetic rather than a measurement:
/// a lazily built list of 3,188 rows cannot be asked where row 3,000 is, but
/// it can be told to start there.
double contentsScrollOffset(int index, double rowExtent, {int rowsAbove = 2}) {
  final first = index - rowsAbove;
  return first <= 0 ? 0 : first * rowExtent;
}

// --- Chapter opener ---------------------------------------------------------

class DropCap {
  const DropCap({required this.initial, required this.rest});

  /// The single initial letter, set large.
  final String initial;

  /// Everything after it — the paragraph continues in the normal face.
  final String rest;
}

/// A paragraph shorter than this is an epigraph, a dateline or a stray
/// heading, not an opening paragraph. A three-line initial over one line of
/// text looks broken, so those are left alone.
const int kMinDropCapLength = 80;

/// Split a chapter's first paragraph into a drop cap and the rest, or return
/// null when this paragraph should not get one.
///
/// Refused, deliberately, when the paragraph opens with anything but a letter.
/// Dialogue is the common case — a great many web-novel chapters open on
/// `"Wait," she said` — and a raised quotation mark reads as a mistake, while
/// dropping the quote and capping the W silently alters the text. Books set
/// those openers plain too.
DropCap? splitDropCap(String? paragraph) {
  final text = paragraph?.trim();
  if (text == null || text.length < kMinDropCapLength) return null;

  // Take a whole grapheme, not a code unit: a surrogate pair (an emoji, a
  // CJK extension) must never be split down the middle into two broken
  // halves rendered as tofu.
  final runes = text.runes;
  if (runes.isEmpty) return null;
  final initial = String.fromCharCode(runes.first);
  if (!_letter.hasMatch(initial)) return null;

  return DropCap(initial: initial, rest: text.substring(initial.length));
}

final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// A scene-break ornament is at most this long.
const int kMaxSceneBreakLength = 12;

/// Whether a paragraph is a scene-break ornament rather than prose.
///
/// Web-novel chapters mark a scene change with a line of `***`, `- - -`,
/// `◇◇◇` or similar. Run through the body renderer those become an indented
/// paragraph of punctuation, which is exactly what they are not: a book sets
/// them centred, with air above and below. Detected rather than configured
/// because the marker differs per source and per translator.
///
/// Deliberately narrow — a short line carrying NO letters and NO digits. An
/// em-dash opener (`— and then nothing`) has letters and stays prose.
bool isSceneBreak(String paragraph) {
  final text = paragraph.trim();
  if (text.isEmpty || text.length > kMaxSceneBreakLength) return false;
  return !_letterOrDigit.hasMatch(text);
}

// --- Reading time -----------------------------------------------------------

/// 250 wpm is the conventional adult silent-reading rate for prose. It is an
/// estimate and is labelled as one ("~12 min"); nothing depends on it being
/// exact.
const int kWordsPerMinute = 250;

/// Whole minutes at [kWordsPerMinute], never less than 1 for real text.
int readingMinutes(int wordCount) {
  if (wordCount <= 0) return 0;
  final minutes = (wordCount / kWordsPerMinute).round();
  return minutes < 1 ? 1 : minutes;
}

/// "~8 min" / "~1 h 12 min". Hours once past 90 minutes, because "~104 min"
/// is a number a reader has to do arithmetic on.
String? formatReadingTime(int wordCount) {
  final minutes = readingMinutes(wordCount);
  if (minutes <= 0) return null;
  if (minutes <= 90) return '~$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '~$hours h' : '~$hours h $rest min';
}

/// "1,240 words". Thousands separated, singular respected.
String? formatWordCount(int wordCount) {
  if (wordCount <= 0) return null;
  return '${formatThousands(wordCount)} ${wordCount == 1 ? 'word' : 'words'}';
}

/// "1,240 words · ~5 min" — the one line a novel chapter row shows.
///
/// A novel chapter list has no page count worth showing: the connector reports
/// `page_count: 0` for every novel chapter, because a novel chapter is not
/// made of pages. What a reader actually wants to know before opening one is
/// how long it is.
String? formatChapterLength(int? wordCount) {
  if (wordCount == null) return null;
  final words = formatWordCount(wordCount);
  if (words == null) return null;
  final time = formatReadingTime(wordCount);
  return time == null ? words : '$words · $time';
}

/// Words in a chapter's paragraphs, for a payload whose `word_count` did not
/// come through. Whitespace-split, which is what the backend counts too.
int countWords(Iterable<String> paragraphs) {
  var total = 0;
  for (final paragraph in paragraphs) {
    final trimmed = paragraph.trim();
    if (trimmed.isEmpty) continue;
    total += trimmed.split(RegExp(r'\s+')).length;
  }
  return total;
}
