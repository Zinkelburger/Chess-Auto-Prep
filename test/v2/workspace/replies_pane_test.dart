import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/replies.dart';
import 'package:chess_auto_prep/v2/workspace/replies_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/session_fixture.dart';

const chapter = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 *
''';

final class OneOpinion implements MovePolicy {
  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async => fen.whiteToMove
      ? const MaiaPolicy({'e2e4': 1.0})
      : const MaiaPolicy({'e7e5': 0.6, 'c7c5': 0.4});
}

void main() {
  late SessionFixture fixture;
  late SettingsStore settings;
  late Replies replies;

  setUp(() async {
    fixture = await openSession(chapter);
    settings = SettingsStore(initial: const Settings(coverOnceIn: 5));
  });

  tearDown(() {
    settings.dispose();
    fixture.dispose();
  });

  /// The owner is made inside the test body: its walk is a chain of futures,
  /// and one started in `setUp` lives outside the test's fake clock and
  /// never runs while the test pumps.
  Future<void> show(WidgetTester tester) async {
    replies = Replies(
      session: fixture.session,
      policy: OneOpinion(),
      settings: settings,
    );
    addTearDown(replies.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: RepliesPane(session: fixture.session, replies: replies),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows their replies with shares, a tick for the one the '
      'chapter plays and the word gap for the one it does not', (tester) async {
    fixture.session.forward();
    await show(tester);
    expect(find.textContaining('Their replies · 2200'), findsOneWidget);
    // c5 is unanswered, and after 1. e4 e5 the chapter stops: two gaps.
    expect(find.textContaining('2 gaps · 0% covered'), findsOneWidget);
    expect(find.text('60%'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.text('gap'), findsOneWidget);
  });

  testWidgets('clicking a reply plays it into the chapter', (tester) async {
    fixture.session.forward();
    await show(tester);
    await tester.tap(find.text('40%'));
    await tester.pumpAndSettle();
    expect(fixture.session.currentMove?.san, 'c5');
    expect(fixture.onDisk, contains('1. e4 c5'));
  });

  testWidgets('at our move the rows are candidates', (tester) async {
    await show(tester);
    expect(find.textContaining('Our candidates'), findsOneWidget);
    expect(find.text('gap'), findsNothing);
  });
}
