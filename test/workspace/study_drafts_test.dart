import 'package:chess_auto_prep/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/chess/pgn/study.dart';
import 'package:chess_auto_prep/workspace/document/study_drafts.dart';
import 'package:dartchess/dartchess.dart' show Side;
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

  test('a game pasted onto the analysis board keeps its players and result; '
      'a board played out by hand names no one', () async {
    final fixture = await openSession('[Event "?"]\n\n1. e4 e5 *\n');
    addTearDown(fixture.dispose);
    final session = fixture.session;
    final pasted =
        pastedBoard(
              '[Event "Club"]\n[White "Alice"]\n[Black "Bob"]\n'
              '[Result "1-0"]\n\n1. e4 e5 2. Nf3 1-0\n',
              side: Side.white,
            )
            as PastedBoard;
    expect(await session.showAnalysisBoard(pasted.chapter), isTrue);
    final draft = gameDraft(session)!;
    expect(draft.name, contains('Alice'));
    expect(draft.result, '1-0');
    final text = studyChapterText(draft, study: 'Games', name: draft.name);
    expect(text, contains('[White "Alice"]'));
    expect(text, contains('[Black "Bob"]'));
    expect(text, endsWith('1-0'));

    expect(
      await session.showAnalysisBoard(
        analysisBoard(side: Side.white, sans: const ['d4', 'd5']),
      ),
      isTrue,
    );
    session.playMove('c2c4');
    final played = gameDraft(session)!;
    expect(played.name, '');
    expect(played.tags, isEmpty);
  });
}
