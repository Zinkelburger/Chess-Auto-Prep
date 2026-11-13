import 'package:chess_auto_prep/workspace/document/study_drafts.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/session_fixture.dart';

void main() {
  test('a file of one game is that game, named as the first', () async {
    final fixture = await openSession('[Event "?"]\n\n1. e4 e5 *\n');
    addTearDown(fixture.dispose);
    expect(gameDraft(fixture.session)?.name, 'Game 1');
  });

  test('a file of two games merged is no one game', () async {
    final fixture = await openSession(
      '[Event "?"]\n[White "A"]\n[Black "B"]\n\n1. e4 *\n\n'
      '[Event "?"]\n[White "C"]\n[Black "D"]\n\n1. d4 *\n',
    );
    addTearDown(fixture.dispose);
    expect(gameDraft(fixture.session)?.name, '');
  });
}
