import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/library/utils/local_read_marks.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';

/// This phone's own reading records, indexed for the library cards.
///
/// Follows the store: it rebuilds when the reader records a page and when the
/// active profile changes (the store is per profile), so a card never shows
/// one persona's position under another's shelf. A card should `select` its
/// own series' [LocalReadMark] rather than watch this whole, so a page turn
/// in the reader rebuilds only the card whose answer moved.
final localReadMarksProvider = Provider<LocalReadMarks>(
  (ref) => LocalReadMarks(ref.watch(sourceProgressProvider)),
  name: 'localReadMarks',
);
