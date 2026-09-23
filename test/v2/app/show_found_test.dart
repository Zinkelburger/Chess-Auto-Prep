import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/app/workspace_requests.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/draft_lines.dart';
import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/traps.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart' show positionOf;
import 'package:chess_auto_prep/v2/workspace/fill_gaps.dart';
import 'package:dartchess/dartchess.dart' show NormalMove, Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

/// [ucis] played from [root] as a search writes them.
List<DraftMove> played(List<String> ucis, {Fen root = Fen.initial}) {
  var position = positionOf(root)!;
  return [
    for (final uci in ucis)
      () {
        final before = Fen(position.fen);
        final (next, san) = position.makeSan(NormalMove.fromUci(uci));
        position = next;
        return DraftMove(
          move: MoveRef(uci: uci, san: san),
          before: before.position,
          after: Fen(next.fen),
          value: 0.5,
          ours: before.whiteToMove,
        );
      }(),
  ];
}

FillFound found(FillOrigin origin) {
  final trap = played(['e2e4', 'f7f6', 'd1h5', 'g7g6']);
  return FillFound(
    origin: origin,
    side: Side.white,
    traps: [
      Trap(
        toTrap: trap.sublist(0, 1),
        blunder: trap[1],
        punishment: trap.sublist(2),
        share: 0.3,
        lossCp: 200,
        reach: 1,
        afterBest: const Eval(0),
        afterBlunder: const Eval(200),
      ),
    ],
    lines: [
      DraftLine(moves: played(['e2e4', 'c7c5', 'g1f3']), reach: 0.7),
    ],
  );
}

void main() {
  final kid = kidMain;
  late WindowFixture w;

  setUp(() => w = WindowFixture());

  tearDown(() => w.dispose());

  const onBoard = OnTheBoard(root: Fen.initial, line: []);

  test('a trap is played onto the board and stops on the mistake', () async {
    expect(await w.requests.showFound(found(onBoard), 0), isA<RequestDone>());
    expect(w.session.currentMove?.san, 'f6');
    w.session.forward();
    expect(w.session.currentMove?.san, 'Qh5+', reason: 'the answer follows');
    expect(w.store.creates, isEmpty);
  });

  test('a line goes to its end beside what is already there', () async {
    await w.requests.showFound(found(onBoard), 0);
    await w.requests.showFound(found(onBoard), 1);
    expect(w.session.currentMove?.san, 'Nf3');
    expect(w.session.tree!.children.single.children.map((n) => n.san), [
      'f6',
      'c5',
    ]);
  });

  test('the moves to where the search began are played first', () async {
    final fromE4 = FillFound(
      origin: const OnTheBoard(
        root: Fen.initial,
        line: [MoveRef(uci: 'e2e4', san: 'e4')],
      ),
      side: Side.white,
      traps: const [],
      lines: [
        DraftLine(
          moves: played(
            ['c7c5', 'g1f3'],
            root: const Fen(
              'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
            ),
          ),
          reach: 1,
        ),
      ],
    );
    await w.requests.showFound(fromE4, 0);
    expect(
      [for (final n in w.session.tree!.lineTo(w.session.cursor)) n.san],
      ['e4', 'c5', 'Nf3'],
    );
  });

  test('from a chapter it goes back to the board first', () async {
    await w.requests.open(kid);
    await w.requests.showFound(found(onBoard), 1);
    expect(w.session.isScratch, isTrue);
    expect(w.session.currentMove?.san, 'Nf3');
  });

  test('a run on a chapter opens its draft in the builder there', () async {
    w.requests.switchTo(Mode.pgnViewer);
    final inDraft = FillFound(
      origin: InDraft(draft: kid, sans: const ['c5']),
      side: Side.black,
      traps: const [],
      lines: [
        DraftLine(
          moves: [
            for (final san in ['Nc3', 'Nc6'])
              DraftMove(
                move: MoveRef(uci: '', san: san),
                before: '',
                after: Fen.initial,
                value: 0.5,
                ours: false,
              ),
          ],
          reach: 1,
        ),
      ],
    );
    expect(await w.requests.showFound(inDraft, 0), isA<RequestDone>());
    expect(w.requests.mode, Mode.repertoires);
    expect(w.session.source, kid);
    expect(w.session.cursor, NodePath.of([0, 1, 0]));
  });
}
