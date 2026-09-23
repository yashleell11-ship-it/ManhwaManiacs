import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/updates/mark_all_read.dart';

void main() {
  group('markAllReadMode', () {
    test('clears only the mode the screen is showing', () {
      expect(
        markAllReadMode(novelsEnabled: true, mode: ContentMode.manga),
        ContentMode.manga,
      );
      expect(
        markAllReadMode(novelsEnabled: true, mode: ContentMode.novel),
        ContentMode.novel,
      );
    });

    test('sends no filter when novels are off, so the request is unchanged', () {
      expect(
        markAllReadMode(novelsEnabled: false, mode: ContentMode.manga),
        isNull,
      );
    });
  });

  group('markAllReadLabel', () {
    test('names the mode it clears', () {
      expect(markAllReadLabel(ContentMode.manga), 'Mark all manga read');
      expect(markAllReadLabel(ContentMode.novel), 'Mark all novels read');
    });

    test('keeps the plain label with a single mode', () {
      expect(markAllReadLabel(null), 'Mark all read');
    });
  });
}
