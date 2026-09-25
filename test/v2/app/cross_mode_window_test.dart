import 'dart:ui' show AppExitResponse;

import 'package:chess_auto_prep/v2/app/app.dart';
import 'package:chess_auto_prep/v2/app/exit_guard.dart';
import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/chess/explorer_answer.dart';
import 'package:chess_auto_prep/v2/chess/explorer_choice.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/features/library/library_panel.dart';
import 'package:chess_auto_prep/v2/net/lichess_explorer.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/comment_field.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/explorer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  testWidgets(
    'mode navigation, focused notes, offline retry and cancelled close preserve the same draft',
    (tester) async {
      final app = WindowFixture();
      addTearDown(app.dispose);
      await app.pumpShell(tester);
      await tester.tap(
        find
            .descendant(
              of: find.byType(LibraryPanel),
              matching: find.text('Main'),
            )
            .last,
      );
      await tester.pumpAndSettle();
      final node = NodePath.of([0]);
      app.session.goTo(node);
      await _ctrl(tester, LogicalKeyboardKey.keyE);
      final field = find.descendant(
        of: find.byType(CommentField),
        matching: find.byType(TextField),
      );
      expect(field, findsOneWidget);
      await tester.enterText(field, 'A note across modes');
      final orientation = app.session.orientation;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(app.session.orientation, orientation);
      expect(app.session.cursor, node, reason: 'text editing owns the arrow');
      app.store.saves.add(const SaveRefused('injected save refusal'));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(app.saver.state, isA<SaveStopped>());
      expect(app.session.commentAt(node), contains('A note across modes'));
      app.question.answer = DraftChoice.keepWaiting;
      for (final mode in Mode.values) {
        app.requests.switchTo(mode);
        await tester.pumpAndSettle();
        expect(app.requests.mode, mode);
        expect(find.text(mode.label), findsWidgets);
        expect(app.session.source, kidMain);
        expect(app.session.commentAt(node), contains('A note across modes'));
        expect(app.lineTrainer.lesson, isNull);
      }
      app.requests.switchTo(Mode.repertoires);
      await tester.pumpAndSettle();
      final opening = app.requests.open(benkoMain);
      await tester.pumpAndSettle();
      await opening;
      expect(app.session.source, kidMain);
      expect(app.question.asked, isNotEmpty);

      app.lichess.throwing = const SocketFailure();
      app.explorer.choose(const ExplorerChoice(source: ExplorerSource.lichess));
      await tester.tap(find.text('Explorer'));
      await tester.pumpAndSettle();
      expect(app.explorer.state, isA<ExplorerFailed>());
      expect(find.text('Try again'), findsOneWidget);
      app.lichess.throwing = null;
      app.lichess.answer = (_) => const ExplorerFetched(ExplorerAnswer.empty);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(app.explorer.state, isNot(isA<ExplorerFailed>()));
      expect(app.session.commentAt(node), contains('A note across modes'));

      var stopped = 0;
      final exit = AppExit(
        guard: app.parts.exit,
        navigatorKey: app.navigator,
        prepare: app.parts.prepareToClose,
        onCancelled: app.parts.resumeAfterClose,
        stopEngines: () async => stopped++,
        closeLog: () async {},
      );
      addTearDown(exit.closing.dispose);
      final closing = exit.leave();
      await tester.pumpAndSettle();
      expect(await closing, AppExitResponse.cancel);
      expect(stopped, 0);
      expect(app.session.source, kidMain);
      expect(app.session.commentAt(node), contains('A note across modes'));
      expect(exit.closing.value, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

final class SocketFailure implements Exception {
  const SocketFailure();
}
