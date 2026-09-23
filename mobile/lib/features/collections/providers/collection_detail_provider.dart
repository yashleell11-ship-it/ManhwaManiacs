import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/features/collections/providers/collections_provider.dart';
import 'package:manhwamaniacs/features/library/models/collection_detail.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/utils/all_followed.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

final collectionDetailProvider = AsyncNotifierProvider.autoDispose
    .family<CollectionDetailNotifier, CollectionDetail, int>(
  CollectionDetailNotifier.new,
  name: 'collectionDetail',
);

class CollectionDetailNotifier
    extends AutoDisposeFamilyAsyncNotifier<CollectionDetail, int> {
  @override
  Future<CollectionDetail> build(int collectionId) async {
    final repo = ref.read(libraryRepositoryProvider);
    final result = await repo.getCollection(collectionId);
    if (result.isErr) throw result.error;
    return result.value;
  }

  Future<void> refresh() async {
    final collectionId = arg;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final repo = ref.read(libraryRepositoryProvider);
      final result = await repo.getCollection(collectionId);
      if (result.isErr) throw result.error;
      return result.value;
    });
  }

  Future<AppError?> updateCollection({
    String? name,
    String? description,
  }) async {
    final repo = ref.read(libraryRepositoryProvider);
    final result = await repo.updateCollection(
      arg,
      name: name,
      description: description,
    );
    if (result.isErr) return result.error;
    await refresh();
    ref.invalidate(collectionsProvider);
    return null;
  }

  Future<AppError?> deleteCollection() async {
    final repo = ref.read(libraryRepositoryProvider);
    final result = await repo.deleteCollection(arg);
    if (result.isErr) return result.error;
    ref.invalidate(collectionsProvider);
    return null;
  }

  Future<AppError?> addSeries({
    required String sourceId,
    required String seriesKey,
  }) async {
    final repo = ref.read(libraryRepositoryProvider);
    final result = await repo.addSeriesToCollection(
      arg,
      sourceId: sourceId,
      seriesKey: seriesKey,
    );
    if (result.isErr) return result.error;
    await refresh();
    ref.invalidate(collectionsProvider);
    return null;
  }

  Future<AppError?> removeSeries({
    required String sourceId,
    required String seriesKey,
  }) async {
    final repo = ref.read(libraryRepositoryProvider);
    final result = await repo.removeSeriesFromCollection(
      arg,
      sourceId: sourceId,
      seriesKey: seriesKey,
    );
    if (result.isErr) return result.error;
    await refresh();
    ref.invalidate(collectionsProvider);
    return null;
  }
}

/// Every follow the add picker can offer — all pages, not the first 200, or a
/// series that sorts late in a big library could never be added (its search
/// box filters this list, so it could not be found either).
final librarySeriesPickerProvider =
    FutureProvider.autoDispose<List<FollowedSeries>>((ref) async {
  final repo = ref.watch(libraryRepositoryProvider);
  final result = await listAllFollowed(repo);
  if (result.isErr) throw result.error;
  return result.value;
});
