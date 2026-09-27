import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/features/pgn_viewer/auto_play.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/session_fixture.dart';

const _game = '''
// Color: White

[Event "Three moves"]
[Result "*"]

1. e4 e5 2. Nf3 *
''';

void main() {
  /// [body] over an open session and its autoplay, on fake time.
  void run(
    void Function(FakeAsync async, SessionFixture f, AutoPlay play) body,
  ) {
    fakeAsync((async) {
      late SessionFixture fixture;
      openSession(_game).then((opened) => fixture = opened);
      async.flushMicrotasks();
      final play = AutoPlay(fixture.session);
      body(async, fixture, play);
      play.dispose();
      fixture.dispose();
    });
  }

  String? san(SessionFixture f) => f.session.currentMove?.san;

  test('plays a move a moment after the key, then one a second, and stops '
      'at the end of the line', () {
    run((async, f, play) {
      play.toggle();
      expect(play.playing, isTrue);
      async.elapse(AutoPlay.firstStep);
      expect(san(f), 'e4');
      async.elapse(AutoPlay.step);
      expect(san(f), 'e5');
      async.elapse(AutoPlay.step);
      expect(san(f), 'Nf3');
      expect(play.playing, isFalse, reason: 'nothing after Nf3');
    });
  });

  test('stops when the user moves the cursor', () {
    run((async, f, play) {
      play.toggle();
      async.elapse(AutoPlay.firstStep);
      f.session.back();
      expect(play.playing, isFalse);
      async.elapse(const Duration(seconds: 3));
      expect(f.session.cursor, const NodePath.root());
    });
  });

  test('the key again stops it', () {
    run((async, f, play) {
      play.toggle();
      async.elapse(AutoPlay.firstStep);
      play.toggle();
      async.elapse(const Duration(seconds: 3));
      expect(san(f), 'e4');
    });
  });

  test('does not start at the end of the line', () {
    run((async, f, play) {
      f.session.toEnd();
      play.toggle();
      expect(play.playing, isFalse);
    });
  });
}
