import 'package:manhwamaniacs/features/content_mode/content_mode.dart';

/// What "Mark all read" on the Updates screen clears, and what it says.
///
/// The list is scoped to the active content mode, so the bulk action is too:
/// clearing the whole account from Manga mode used to consume every novel
/// chapter the reader had not been shown, and they never read as new in
/// Novels mode. With novels disabled there is only one mode, so this is null —
/// no filter on the request and the plain label, exactly what a manga-only
/// deployment always had. Mirrors the web's `mark-all.ts`.
ContentMode? markAllReadMode({
  required bool novelsEnabled,
  required ContentMode mode,
}) =>
    novelsEnabled ? mode : null;

/// Names the mode it clears, so nobody expects the other one to go too.
String markAllReadLabel(ContentMode? mode) => mode == null
    ? 'Mark all read'
    : 'Mark all ${mode.label.toLowerCase()} read';
