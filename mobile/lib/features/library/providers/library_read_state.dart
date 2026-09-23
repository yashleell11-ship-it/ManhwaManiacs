import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/library/providers/library_list_provider.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';

/// Brings the shelves that say how far the profile has read back up to date
/// when a reader closes.
///
/// The Library tab draws its cards from [updatesProvider], the browse screen
/// under it from [libraryListProvider], and the resume strip from
/// [continueReadingProvider]. All three live inside the tab's indexed stack
/// while the reader is pushed over it on the root navigator, so none of them
/// is disposed or rebuilt when the reader closes — and nothing else told them
/// that anything had been read. A series opened for the first time still said
/// "Not started" on the way back, and a started one kept its old "Ch X of Y"
/// and "N NEW", until a pull-to-refresh or a relaunch. The web never had this:
/// it invalidates its library queries whenever progress is saved.
///
/// Refreshed on the way OUT of the reader rather than on every save, because
/// on the phone those shelves stay mounted underneath it: refreshing per save
/// would be three requests a page turn for screens nobody can see.
///
/// A provider of its own, like `librarySeriesActionsProvider`, so a reader
/// can resolve it while it builds and call it from dispose(), when reading a
/// provider through the widget would throw.
final libraryReadStateProvider = Provider<LibraryReadState>(
  LibraryReadState.new,
  name: 'libraryReadState',
);

class LibraryReadState {
  LibraryReadState(this._ref);

  final Ref _ref;

  /// Refreshes once [lastSave] — the reader's final progress save — has
  /// settled, so the shelves are asked after the server has the read rather
  /// than racing it. A save that failed still leaves the refresh worth doing:
  /// earlier saves in the same read may well have landed.
  Future<void> afterReading(Future<void> lastSave) async {
    try {
      await lastSave;
    } catch (_) {
      // Refresh regardless; see above.
    }
    refresh();
  }

  /// Re-reads every read-state shelf that is currently alive.
  ///
  /// [Ref.exists] first, like the series actions: building an autoDispose list
  /// nobody is showing would be a fetch whose result nobody renders.
  void refresh() {
    if (_ref.exists(updatesProvider)) {
      unawaited(_ref.read(updatesProvider.notifier).refreshFollowed());
    }
    // Both keep what they already hold when the fetch fails, so reading
    // downloaded chapters offline does not come back to an error screen. The
    // browse list is re-read page for page rather than invalidated: it is
    // paginated, and a rebuild is page 1 only — someone scrolled past the
    // first twenty series came back to find the rest gone and their place
    // lost, every time a reader closed.
    if (_ref.exists(libraryListProvider)) {
      unawaited(_ref.read(libraryListProvider.notifier).refreshLoaded());
    }
    if (_ref.exists(continueReadingProvider)) {
      _ref.invalidate(continueReadingProvider);
    }
  }
}
