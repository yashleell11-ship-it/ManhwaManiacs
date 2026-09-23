/// What a library card says about where the reader is in a followed series.
///
/// Every follow is created as "reading" and nobody ever changes it, so the
/// shelf used to print "Reading" under series the owner had followed as a
/// to-read note and never opened, and the "N NEW" pill counted new-chapter
/// notifications — most of them for series he had not begun. The list now
/// carries the server's [ReadState] for each row, and these helpers turn it
/// into the card's words.
///
/// Mirrors `frontend/src/features/library/read-state.ts` — both clients
/// describe the same series the same way.
library;

import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/read_state.dart';
import 'package:manhwamaniacs/features/library/utils/local_read_marks.dart';
import 'package:manhwamaniacs/features/library/utils/series_display.dart';

/// Above this the pill stops counting; "3183 NEW" is noise, not information.
const int _newCountCap = 99;

/// 4.0 → "4", 12.5 → "12.5": printed chapter numbers, not measurements.
String _formatNumber(double value) =>
    value % 1 == 0 ? value.toInt().toString() : value.toString();

/// The server's [state], unless it says "not started" while this phone's own
/// reader has a record for the series ([local]) — then "started", at the
/// furthest chapter the phone knows the number of.
///
/// The phone's Sources-tab reader kept its positions on the phone alone
/// before 3.4.0, so the server can be missing a whole series the owner has
/// been reading here; a card that says "Not started" under it contradicts the
/// series page one tap away, which merges both stores. Only ever upgrades a
/// "not started": where the server has a position it is the one both clients
/// share, and the phone's record is already on its way there. Carries no
/// position or new-chapter count — without the chapter list the phone cannot
/// say how many chapters lie past its furthest one, and "0 new" is not a
/// claim to invent. A null [state] stays null, so a row from a server older
/// than read states keeps the line it always had.
ReadState? readStateWithLocal(ReadState? state, LocalReadMark? local) {
  if (state == null || state.started || local == null) return state;
  return ReadState(
    started: true,
    chapterNumber: local.chapterNumber,
    total: state.total,
  );
}

/// "Not started", "Ch 5 of 120", or null when the row carries no read state
/// (so the caller keeps whatever it said before).
///
/// Printed numbers are used only when both ends have one and they are in
/// order; otherwise the position in the list is honest where a mix is not —
/// "Ch 12 of 10" is what a numbered chapter over an unnumbered tail would say.
String? readStateLabel(ReadState? state) {
  if (state == null) return null;
  if (!state.started) return 'Not started';
  final number = state.chapterNumber;
  final latest = state.latestNumber;
  final position = state.position;
  if (position != null) {
    if (number != null && latest != null && number <= latest) {
      return 'Ch ${_formatNumber(number)} of ${_formatNumber(latest)}';
    }
    return 'Ch $position of ${state.total}';
  }
  // Started, but on a chapter the known list no longer carries.
  if (number != null) return 'Ch ${_formatNumber(number)}';
  return 'Started';
}

/// Chapters past the furthest one opened — 0 for a series never started,
/// where every chapter is "unread" but none is "new" to this reader.
int readStateNewCount(ReadState? state) {
  final count = state?.newCount;
  if (state == null || !state.started || count == null) return 0;
  return count < 0 ? 0 : count;
}

/// "2 new", "99+ new", or null for none — for a line of text, not a pill.
String? newCountLabel(int count) {
  if (count <= 0) return null;
  return count > _newCountCap ? '$_newCountCap+ new' : '$count new';
}

/// The pill's text: "2 NEW", "99+ NEW".
String newCountBadgeText(int count) =>
    count > _newCountCap ? '$_newCountCap+ NEW' : '$count NEW';

/// A card line with no pill beside it: "Ch 5 of 120 · 2 new", "Not started",
/// or null when the row carries no read state.
String? readStateNote(ReadState? state) {
  final label = readStateLabel(state);
  if (label == null) return null;
  final fresh = newCountLabel(readStateNewCount(state));
  return fresh == null ? label : '$label · $fresh';
}

/// The library list row's meta line: where the reader is and what is
/// waiting, else — for a row with no read state — the chapter count.
/// [local] is this phone's own record for the series (`readStateWithLocal`).
String seriesCardMeta(FollowedSeries series, {LocalReadMark? local}) =>
    readStateNote(readStateWithLocal(series.readState, local)) ??
    '${series.chapterCount} chapters';

/// The line under a library grid cover: where the reader is and what is
/// waiting, else — for a row with no read state — the reading-status word it
/// always printed. [local] as for [seriesCardMeta].
String progressCardLabel(FollowedSeries series, {LocalReadMark? local}) =>
    readStateNote(readStateWithLocal(series.readState, local)) ??
    readingStatusLabel(series.readingStatus);

/// The home card's pill count: chapters past the furthest one read when the
/// row carries a read state, else the unread notifications it always counted.
int libraryCardNewCount(ReadState? state, {required int unreadNotifications}) =>
    state == null ? unreadNotifications : readStateNewCount(state);
