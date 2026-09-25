import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/workspace/gap_hunt.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/replies_pane.dart';
import 'package:chessground/chessground.dart' show StaticChessboard;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/replies_fixture.dart';
import '../support/scripted_policy.dart';
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
      ? const MaiaPolicy({'e2e4': 0.7, 'd2d4': 0.3})
      : const MaiaPolicy({'e7e5': 0.6, 'c7c5': 0.4});
}

/// A model that answers only after 1. e4 and fails everywhere else.
final class FirstReplyOnly implements MovePolicy {
  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async =>
      fen.position == 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -'
      ? const MaiaPolicy({'e7e5': 0.6, 'c7c5': 0.4})
      : const MaiaFailed('no opinion');
}

/// White answers 1...e5 with 2. Nf3, where the model has nothing to say.
const longerChapter = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 2. Nf3 *
''';

/// The chapter after a fill: our move carries what the search thought.
const filledChapter = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 {[%expectimax +0.42] [%score 56.0%]} e5 *
''';

void main() {
  late SessionFixture fixture;
  late SettingsStore settings;
  late RepliesFixture shownOwners;

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
  Future<void> show(
    WidgetTester tester, {
    MovePolicy? policy,
    RepertoireAnswers? answers,
  }) async {
    final owners = RepliesFixture(
      fixture.session,
      policy: policy ?? OneOpinion(),
      answers: answers,
      settings: settings,
    );
    shownOwners = owners;
    addTearDown(owners.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: RepliesPane(
              session: fixture.session,
              replies: owners.replies,
              gaps: owners.gaps,
            ),
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

  testWidgets('a model that answered nothing finds no gaps and claims no '
      'coverage', (tester) async {
    await show(tester, policy: const NoOpinion());
    expect(find.text('Their replies · 2200'), findsOneWidget);
    expect(find.textContaining('covered'), findsNothing);
  });

  testWidgets('where the model answered only some positions the gaps are '
      'counted and the coverage left out', (tester) async {
    fixture.dispose();
    fixture = await openSession(longerChapter);
    fixture.session.forward();
    await show(tester, policy: FirstReplyOnly());
    expect(find.text('Their replies · 2200 · 1 gap'), findsOneWidget);
  });

  testWidgets('the floated board goes when the table changes under the '
      'pointer', (tester) async {
    await show(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('70%')));
    await tester.pump(previewDelay);
    final board = tester.widget<StaticChessboard>(
      find.byType(StaticChessboard),
    );
    expect(board.lastMove?.uci, 'e2e4');
    fixture.session.forward();
    await tester.pump();
    expect(find.byType(StaticChessboard), findsNothing);
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

  testWidgets('at our move each candidate shows what a fill said it is '
      'worth, read off the document, or that no run reached it', (
    tester,
  ) async {
    fixture.dispose();
    fixture = await openSession(filledChapter);
    await show(tester);
    expect(find.text('+0.42'), findsOneWidget);
    expect(find.text('not in tree'), findsOneWidget);
    fixture.session.forward();
    await tester.pumpAndSettle();
    expect(find.text('not in tree'), findsNothing, reason: 'their move');
  });
  testWidgets(
    'failed gap refresh hides current marks and Retry restores navigation',
    (tester) async {
      final files = ScriptedFiles();
      fixture.session.forward();
      await show(
        tester,
        answers: RepertoireAnswers(
          files: files,
          documents: ScriptedDocumentStore(),
        ),
      );
      expect(shownOwners.gaps.canNextGap, isTrue);
      files.validateWith = (_, _) async =>
          const RepertoireValidationFailed('source unavailable');
      shownOwners.gaps.refreshAnswers();
      await tester.pumpAndSettle();
      expect(find.textContaining('Gap results unavailable'), findsOneWidget);
      expect(find.text('gap'), findsNothing);
      final next = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Next gap'),
      );
      expect(next.onPressed, isNull);
      files.validateWith = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Gap results unavailable'), findsNothing);
      expect(shownOwners.gaps.canNextGap, isTrue);
    },
  );
}
