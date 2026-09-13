import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

/// What this profile is part-way through, newest first.
///
/// This replaced a `dashboardProvider` that fetched three endpoints at once —
/// recently-updated, continue-reading and statistics — for a home screen that
/// was never built. Nothing watched it: the only references were the five
/// `ref.invalidate` calls that still surround this provider, so the fetch never
/// ran and the Library tab had no resume affordance at all.
///
/// Deliberately NOT a revival of that three-call provider. `GET
/// /library/statistics` scans the profile's whole session history and is the
/// heaviest endpoint in the app; putting it behind the Library tab would pay
/// that cost on every launch to render a strip that does not use it.
///
/// Kept `autoDispose` and kept under the same invalidations, because reading
/// position is per-(user, profile) and the 18+ gate can hide a series: a
/// profile switch or a mature-setting change must not leave the previous
/// persona's row on screen.
final continueReadingProvider =
    FutureProvider.autoDispose<List<ContinueReadingItem>>((ref) async {
  final repo = ref.watch(libraryRepositoryProvider);
  final result = await repo.continueReading(limit: _continueReadingLimit);
  if (result.isErr) throw result.error;
  return result.value;
});

/// Enough to fill the strip on the widest phone and leave a little to scroll,
/// without asking the server for a page of rows nobody will reach.
const int _continueReadingLimit = 8;
