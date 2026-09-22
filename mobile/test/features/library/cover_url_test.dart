import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/utils/cover_url.dart';

FollowedSeries _series({required String coverUrl}) => FollowedSeries(
      id: 42,
      sourceId: 'asurascans',
      seriesKey: 'killer-pietro',
      title: 'Killer Pietro',
      coverUrl: coverUrl,
      isFavorite: false,
      readingStatus: 'reading',
      notify: false,
      sortOrder: 0,
      contentRating: 'safe',
      rating: 'safe',
      chapterCount: 10,
    );

void main() {
  group('followedSeriesCoverUrl', () {
    test('resolves a backend-relative proxy path against the API base', () {
      expect(
        followedSeriesCoverUrl(
          'http://127.0.0.1:8000',
          _series(coverUrl: '/sources/asurascans/series/killer-pietro/cover'),
        ),
        'http://127.0.0.1:8000/sources/asurascans/series/killer-pietro/cover',
      );
    });

    test('normalizes trailing slash on base URL', () {
      expect(
        followedSeriesCoverUrl(
          'http://127.0.0.1:8000/',
          _series(coverUrl: '/sources/asurascans/series/killer-pietro/cover'),
        ),
        'http://127.0.0.1:8000/sources/asurascans/series/killer-pietro/cover',
      );
    });

    test('leaves an absolute source cover URL untouched', () {
      expect(
        followedSeriesCoverUrl(
          'http://127.0.0.1:8000',
          _series(coverUrl: 'https://cdn.example.com/cover.jpg'),
        ),
        'https://cdn.example.com/cover.jpg',
      );
    });

    test('returns null for an empty cover URL', () {
      expect(
        followedSeriesCoverUrl('http://127.0.0.1:8000', _series(coverUrl: '')),
        isNull,
      );
    });
  });

  group('historyCoverUrl', () {
    test('resolves the relative proxy path production history rows carry', () {
      // Every history row in production has this shape; unresolved it has no
      // host and the cover renders as the broken-image placeholder.
      expect(
        historyCoverUrl(
          'https://api.manhwamaniacs.xyz',
          '/sources/asurascans/series/nano-machine-6f7fe6eb/cover',
        ),
        'https://api.manhwamaniacs.xyz/sources/asurascans/series/'
        'nano-machine-6f7fe6eb/cover',
      );
    });

    test('leaves an absolute cover URL untouched', () {
      expect(
        historyCoverUrl('http://127.0.0.1:8000', 'https://example.test/c.jpg'),
        'https://example.test/c.jpg',
      );
    });

    test('is null when the row has no cover', () {
      expect(historyCoverUrl('http://127.0.0.1:8000', null), isNull);
      expect(historyCoverUrl('http://127.0.0.1:8000', '  '), isNull);
    });
  });
}
