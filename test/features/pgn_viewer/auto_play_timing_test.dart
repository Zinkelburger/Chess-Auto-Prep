// Autoplay's pace as the viewer promises it, in real numbers: the first
// move 300 ms after the key, then one a second; and a move the user makes
// before the first step stops it.
import 'dart:async';

import 'package:chess_auto_prep/features/pgn_viewer/auto_play.dart';
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
  void run(
    void Function(FakeAsync async, SessionFixture f, AutoPlay play) body,
  ) {
    fakeAsync((async) {
      late SessionFixture fixture;
      unawaited(openSession(_game).then((opened) => fixture = opened));
      async.flushMicrotasks();
      final play = AutoPlay(fixture.session);
      body(async, fixture, play);
      play.dispose();
      fixture.dispose();
    });
  }

  String? san(SessionFixture f) => f.session.cursor.currentMove?.san;

  test('the first move after 300 ms, then one a second', () {
    run((async, f, play) {
      play.toggle();
      async.elapse(const Duration(milliseconds: 299));
      expect(san(f), isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(san(f), 'e4');
      async.elapse(const Duration(milliseconds: 999));
      expect(san(f), 'e4');
      async.elapse(const Duration(milliseconds: 1));
      expect(san(f), 'e5');
    });
  });

  test('a move the user makes before the first step stops it', () {
    run((async, f, play) {
      play.toggle();
      f.session.cursor.forward();
      expect(play.playing, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(san(f), 'e4');
    });
  });
}
