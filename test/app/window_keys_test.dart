// The window's keys and the mouse's own buttons: ↓ and ↑ walk the file's
// games where the mode has no list of its own and the viewer's list where
// it has; ← on the Analysis tab steps back on its board; and the mouse's
// back and forward buttons travel once each, a plain click not at all.
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/shell.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/study_files.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/study_fixture.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  testWidgets('in Study, ↓ and ↑ walk the chapters', (tester) async {
    final ref = studyRef('Endgames');
    w.store.documents[ref] = Opened(
      twoChapterStudy,
      scriptedRevision(twoChapterStudy),
    );
    w.studyFiles.listing = StudiesListed([ref]);
    await w.pumpShell(tester);
    await w.requests.openStudy(ref);
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.study);
    expect(w.session.game, 0);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(w.session.game, 1);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(w.session.game, 0);
  });

  testWidgets("in the viewer, ↑ walks back up the file's games", (
    tester,
  ) async {
    final ref = collectionRef('three');
    w.store.documents[ref] = Opened(
      threeGameFile,
      scriptedRevision(threeGameFile),
    );
    await w.pumpShell(tester);
    await w.requests.openFile(ref, game: 2);
    await tester.pumpAndSettle();
    final at = w.session.game;
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(w.session.game, isNot(at));
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(w.session.game, at);
  });

  testWidgets("← on the Analysis tab steps back on the tab's board", (
    tester,
  ) async {
    await w.pumpShell(tester);
    await w.requests.open(kidMain);
    await tester.pumpAndSettle();
    w.session.cursor.forward();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final inspection = w.parts.workspace.inspection!;
    expect(inspection.active, isTrue);
    expect(inspection.session.cursor.currentMove?.san, 'c5');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(inspection.session.cursor.value.isRoot, isTrue);
  });

  group("the mouse's buttons", () {
    late Mode first;

    /// Databases, then Tactics, with its board in the middle of the
    /// window: one step to go back.
    Future<void> twoPlaces(WidgetTester tester) async {
      await w.pumpShell(tester);
      w.requests.switchTo(Mode.databases);
      await tester.pumpAndSettle();
      first = w.requests.mode;
      w.requests.switchTo(Mode.tactics);
      await tester.pumpAndSettle();
      expect(w.requests.backTo, isNotNull);
    }

    Future<void> click(WidgetTester tester, int buttons) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Shell)),
        kind: PointerDeviceKind.mouse,
        buttons: buttons,
      );
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('over the board, back goes back once and forward comes '
        'forward', (tester) async {
      await twoPlaces(tester);
      await click(tester, kBackMouseButton);
      expect(w.requests.mode, first);
      await click(tester, kForwardMouseButton);
      expect(w.requests.mode, Mode.tactics);
    });

    testWidgets('a plain click travels nowhere', (tester) async {
      await twoPlaces(tester);
      await click(tester, kBackMouseButton);
      expect(w.requests.mode, first);
      await click(tester, kPrimaryButton);
      expect(w.requests.mode, first);
    });
  });
}
