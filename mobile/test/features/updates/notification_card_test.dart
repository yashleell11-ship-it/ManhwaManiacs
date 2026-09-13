import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode.dart';
import 'package:manhwamaniacs/features/content_mode/content_mode_controller.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';
import 'package:manhwamaniacs/features/updates/screens/updates_screen.dart';
import 'package:manhwamaniacs/shared/widgets/glass_card.dart';

/// Ids the notification and the follow agree on, so the screen can resolve one
/// from the other — which is the whole point of the title lookup.
const int _followId = 7;

UpdateNotification _notification({
  String sourceId = 'asurascans',
  bool isRead = false,
}) =>
    UpdateNotification(
      id: 1,
      followedSeriesId: _followId,
      sourceId: sourceId,
      seriesKey: 'series/one',
      chapterKey: 'series/one/chapters/211',
      chapterTitle: 'Chapter 211',
      chapterNumber: 211,
      isRead: isRead,
    );

FollowedSeries _follow({String sourceId = 'asurascans'}) => FollowedSeries(
      id: _followId,
      sourceId: sourceId,
      seriesKey: 'series/one',
      title: 'The Great Mage Returns',
      coverUrl: '',
      isFavorite: false,
      readingStatus: 'unread',
      notify: true,
      sortOrder: 0,
      contentRating: 'safe',
      rating: 'safe',
      chapterCount: 0,
    );

/// Records what the screen asked the notifier to do.
class _FakeUpdatesNotifier extends AutoDisposeAsyncNotifier<UpdatesState>
    implements UpdatesNotifier {
  _FakeUpdatesNotifier(this.state0, this.markedRead);

  final UpdatesState state0;
  final List<int> markedRead;

  @override
  Future<UpdatesState> build() async => state0;

  @override
  Future<AppError?> markRead(int id) async {
    markedRead.add(id);
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<List<int>> _pump(
  WidgetTester tester, {
  required UpdateNotification notification,
  required FollowedSeries follow,
  ContentMode mode = ContentMode.manga,
  Map<String, ContentMode> index = const {},
  bool novelsEnabled = false,
}) async {
  final markedRead = <int>[];
  final router = GoRouter(
    initialLocation: '/updates',
    routes: [
      GoRoute(path: '/updates', builder: (_, __) => const UpdatesScreen()),
      GoRoute(
        path: Routes.reader,
        builder: (_, __) => const Scaffold(body: Text('PAGE READER')),
      ),
      GoRoute(
        path: Routes.novelReader,
        builder: (_, __) => const Scaffold(body: Text('NOVEL READER')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        updatesProvider.overrideWith(
          () => _FakeUpdatesNotifier(
            UpdatesState(
              notifications: [notification],
              unreadCount: notification.isRead ? 0 : 1,
              followed: [follow],
            ),
            markedRead,
          ),
        ),
        contentModeScopeProvider.overrideWithValue(
          ContentModeScope(
            mode: mode,
            index: index,
            novelsEnabled: novelsEnabled,
          ),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return markedRead;
}

/// The notification card's own subtree.
///
/// Scoped, because the screen also lists the followed series below the
/// notifications — so the series title legitimately appears twice on screen and
/// an unscoped finder would be ambiguous. The chapter line is unique to the
/// notification card, so its enclosing card is the one we mean.
Finder _card() => find.ancestor(
      of: find.text('Chapter 211'),
      matching: find.byType(GlassCard),
    );

Finder _inCard(String text) =>
    find.descendant(of: _card(), matching: find.text(text));

void main() {
  group('update notification card', () {
    testWidgets('names the series, not the bare source id', (tester) async {
      // It used to print "asurascans" where the name of the thing you follow
      // belongs, while the title sat in the same payload.
      await _pump(
        tester,
        notification: _notification(),
        follow: _follow(),
      );

      expect(_inCard('The Great Mage Returns'), findsOneWidget);
      expect(_inCard('asurascans'), findsNothing);
    });

    testWidgets('still says something useful when the follow is gone',
        (tester) async {
      // Unfollowed since the notification was written: no title to resolve, so
      // the source id is better than an empty line.
      await _pump(
        tester,
        notification: _notification(),
        follow: const FollowedSeries(
          id: _followId + 1,
          sourceId: 'asurascans',
          seriesKey: 'series/other',
          title: 'Something Else',
          coverUrl: '',
          isFavorite: false,
          readingStatus: 'unread',
          notify: true,
          sortOrder: 0,
          contentRating: 'safe',
          rating: 'safe',
          chapterCount: 0,
        ),
      );

      expect(_inCard('Chapter 211'), findsOneWidget);
      expect(_inCard('asurascans'), findsOneWidget);
    });

    testWidgets('opens the chapter it announces', (tester) async {
      // The card had no tap target at all: the only way to reach the chapter
      // was to remember the series and go find it.
      await _pump(tester, notification: _notification(), follow: _follow());

      await tester.tap(find.text('Chapter 211'));
      await tester.pumpAndSettle();

      expect(find.text('PAGE READER'), findsOneWidget);
    });

    testWidgets('opens a novel notification in the NOVEL reader',
        (tester) async {
      await _pump(
        tester,
        notification: _notification(sourceId: 'novelarchive'),
        follow: _follow(sourceId: 'novelarchive'),
        mode: ContentMode.novel,
        index: const {'novelarchive': ContentMode.novel},
        novelsEnabled: true,
      );

      await tester.tap(find.text('Chapter 211'));
      await tester.pumpAndSettle();

      expect(find.text('NOVEL READER'), findsOneWidget);
    });

    testWidgets('clears the badge on the way through', (tester) async {
      // A badge that only clears via a separate "Mark read" button counts
      // chapters you have already read, which is a badge you learn to ignore.
      final marked = await _pump(
        tester,
        notification: _notification(),
        follow: _follow(),
      );

      await tester.tap(find.text('Chapter 211'));
      await tester.pumpAndSettle();

      expect(marked, [1]);
    });

    testWidgets('does not re-mark one that is already read', (tester) async {
      final marked = await _pump(
        tester,
        notification: _notification(isRead: true),
        follow: _follow(),
      );

      await tester.tap(find.text('Chapter 211'));
      await tester.pumpAndSettle();

      expect(marked, isEmpty);
    });
  });
}
