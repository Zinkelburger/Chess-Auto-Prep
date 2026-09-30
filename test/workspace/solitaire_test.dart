import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/solitaire.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/session_fixture.dart';

const _game = '''
[Event "Solitaire"]
[White "Alice"]
[Black "Bob"]
[Result "1-0"]

1. e4 {Opening note} e5 (1... c5) 2. Nf3 Nc6 3. Bb5 1-0
''';

void main() {
  void run(
    void Function(FakeAsync async, SessionFixture f, Solitaire solitaire) body,
  ) {
    fakeAsync((async) {
      late SessionFixture fixture;
      openSession(_game).then((opened) => fixture = opened);
      async.flushMicrotasks();
      final analysis = EngineAnalysis(
        fixture.session,
        () async => const StartFailed('off'),
      );
      final solitaire = Solitaire(fixture.session, analysis);
      body(async, fixture, solitaire);
      solitaire.dispose();
      analysis.dispose();
      fixture.dispose();
    });
  }

  test('counts the side\'s main-line moves and hides the game while '
      'guessing', () {
    run((async, f, solitaire) {
      solitaire.offer();
      expect(solitaire.side, Side.white);
      expect(solitaire.movesToGuess, 3);
      solitaire.setSide(Side.black);
      expect(solitaire.movesToGuess, 2);
      solitaire.setSide(Side.white);
      solitaire.start();
      expect(solitaire.active, isTrue);
      expect(f.session.shownTo, const NodePath.root());
    });
  });

  test('a right guess advances and the reply is played for the user; a '
      'wrong one is refused and writes nothing', () {
    run((async, f, solitaire) {
      solitaire.start();
      expect(solitaire.play('e2e3'), isTrue);
      expect(solitaire.lastWrong, isTrue);
      expect(f.session.cursor, const NodePath.root());
      expect(solitaire.play('e2e4'), isTrue);
      expect(f.session.currentMove?.san, 'e4');
      async.elapse(Solitaire.replyDelay);
      expect(f.session.currentMove?.san, 'e5');
      expect(f.session.shownTo, f.session.cursor);
      expect(solitaire.play('g1f3'), isTrue);
      async.elapse(Solitaire.replyDelay);
      expect(f.session.currentMove?.san, 'Nc6');
      solitaire.showHint();
      expect(solitaire.hint, 'Move your bishop.');
      solitaire.reveal();
      expect(solitaire.finished, isTrue);
      expect(f.session.shownTo, isNull, reason: 'the whole game is back');
      expect(solitaire.guessed, 3);
      expect(solitaire.firstTry, 1);
      expect(solitaire.hinted, 1);
      expect(solitaire.revealed, 1);
      expect(solitaire.misses.map((m) => solitaire.moveLabel(m.at)), [
        '1. e4',
        '3. Bb5',
      ]);
      expect(solitaire.misses.first.tried, ['e3']);
      expect(f.session.hasHeldEdits, isFalse);
      expect(f.onDisk, _game);
    });
  });

  test('guessing Black starts with White\'s move played', () {
    run((async, f, solitaire) {
      solitaire.setSide(Side.black);
      solitaire.start();
      expect(solitaire.play('e7e5'), isTrue, reason: 'taken, not the turn');
      expect(f.session.cursor, const NodePath.root());
      async.elapse(Solitaire.replyDelay);
      expect(f.session.currentMove?.san, 'e4');
      solitaire.play('e7e5');
      expect(f.session.currentMove?.san, 'e5');
    });
  });

  test('stop and another game show the whole game again', () {
    run((async, f, solitaire) {
      solitaire.start();
      solitaire.stop();
      expect(solitaire.active, isFalse);
      expect(f.session.shownTo, isNull);
      expect(solitaire.play('e2e4'), isFalse, reason: 'moves go to the file');
      solitaire.start();
      f.session.showOnlyTo(null);
      expect(solitaire.active, isFalse);
    });
  });
}
