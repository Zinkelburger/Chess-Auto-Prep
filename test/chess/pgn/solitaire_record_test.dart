import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/chess/pgn/solitaire_record.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pgn_round_trip.dart';

const _annotated = r'''
[Event "Annotated original"]
[White "First player"]
[Black "Second player"]
[Result "1-0"]

{Opening introduction. The later move is Bb5.}
1. e4 $1 {Original e4 note. [%clk 0:04:00]}
({Existing variation introduction.} 1. d4 {Original d4 note.} d5 2. c4)
e5 {Next comes Nf3. [%eval 0.22]}
2. Nf3 Nc6 3. Bb5 {Future secret.} a6 1-0
''';

NodePath _ply(int count) => NodePath.of(List.filled(count, 0));

String _write(GameRead source, GameTree tree) => writeGameText(
  source.tags,
  tree,
  terminator: source.terminator,
  separator: source.separator,
);

GameTree _roundTrip(GameRead source, GameTree tree) {
  final text = _write(source, tree);
  expectRoundTrip(text);
  return readGame(text).tree!;
}

void main() {
  test(
    'review keeps the original game and records every attempt beside it',
    () {
      final source = readGame(_annotated);
      final original = source.tree!;
      final before = _write(source, original);
      final attempts = [
        const SolitaireAttempt(
          at: NodePath.root(),
          uci: 'e2e3',
          outcome: SolitaireOutcome.mistake,
          evaluation: '-0.80',
          gameEvaluation: '+0.22',
        ),
        const SolitaireAttempt(
          at: NodePath.root(),
          uci: 'e2e3',
          outcome: SolitaireOutcome.mistake,
          hinted: true,
        ),
        const SolitaireAttempt(
          at: NodePath.root(),
          uci: 'd2d4',
          outcome: SolitaireOutcome.goodMove,
        ),
        const SolitaireAttempt(
          at: NodePath.root(),
          uci: 'e2e4',
          outcome: SolitaireOutcome.revealed,
        ),
        SolitaireAttempt(
          at: _ply(2),
          uci: 'f1c4',
          outcome: SolitaireOutcome.betterMove,
          evaluation: '+0.70',
          gameEvaluation: '+0.10',
        ),
        SolitaireAttempt(
          at: _ply(4),
          uci: 'f1b5',
          outcome: SolitaireOutcome.gameMove,
          hinted: true,
        ),
      ];

      final review = _roundTrip(source, solitaireReview(original, attempts));

      expect(mainlineSans(review), mainlineSans(original));
      expect(
        review.mainLine.map((move) => move.fen.value),
        original.mainLine.map((move) => move.fen.value),
      );
      expect(review.rootComment, original.rootComment);
      expect(review.children.map((move) => move.san), ['e4', 'd4', 'e3']);
      final e4 = review.children.first;
      expect(e4.nags, [1]);
      expect(e4.comment, startsWith(original.children.first.comment!));
      expect(e4.comment, contains('Solitaire: Move shown.'));
      expect(
        e4.children.first.comment,
        original.children.first.children.first.comment,
      );
      final d4 = review.children[1];
      expect(d4.startingComment, 'Existing variation introduction.');
      expect(d4.comment, 'Original d4 note. Solitaire: Good alternative.');
      expect(d4.children.single.san, 'd5');
      expect(d4.children.single.children.single.san, 'c4');
      final e3 = review.children[2];
      expect('Solitaire: Mistake.'.allMatches(e3.comment!), hasLength(2));
      expect(e3.comment, contains('Evaluation: -0.80.'));
      expect(e3.comment, contains('Game move evaluation: +0.22.'));
      expect(e3.comment, contains('Hint used.'));
      expect(e3.children, isEmpty);
      final bc4 = review.nodeAt(_ply(2).child(1))!;
      expect(bc4.san, 'Bc4');
      expect(bc4.comment, contains('Better than the game move.'));
      expect(bc4.comment, contains('Evaluation: +0.70.'));
      expect(bc4.children, isEmpty);
      expect(
        review.nodeAt(_ply(5))!.comment,
        'Future secret. Solitaire: Game move. Hint used.',
      );
      expect(
        _write(source, original),
        before,
        reason: 'the file remains untouched',
      );
      expect(attempts, hasLength(6));
    },
  );

  test(
    'progress reveals only the solved mainline prefix and completed tries',
    () {
      final source = readGame(_annotated);
      final attempts = [
        const SolitaireAttempt(
          at: NodePath.root(),
          uci: 'd2d4',
          outcome: SolitaireOutcome.mistake,
        ),
        const SolitaireAttempt(
          at: NodePath.root(),
          uci: 'e2e4',
          outcome: SolitaireOutcome.gameMove,
        ),
        SolitaireAttempt(
          at: _ply(2),
          uci: 'f1c4',
          outcome: SolitaireOutcome.betterMove,
        ),
        SolitaireAttempt(
          at: _ply(4),
          uci: 'f1b5',
          outcome: SolitaireOutcome.revealed,
        ),
      ];
      final opening = solitaireProgress(
        source.tree!,
        attempts,
        const NodePath.root(),
      );
      expect(opening.children, isEmpty);
      expect(opening.rootComment, isNull);

      final progress = _roundTrip(
        source,
        solitaireProgress(source.tree!, attempts, _ply(2)),
      );
      expect(mainlineSans(progress), ['e4', 'e5']);
      expect(progress.rootComment, isNull);
      expect(progress.children.first.nags, isEmpty);
      expect(progress.children.first.comment, 'Solitaire: Game move.');
      expect(progress.children.first.children.single.comment, isNull);
      expect(progress.children.first.children.single.children, isEmpty);
      expect(progress.children[1].san, 'd4');
      expect(progress.children[1].children, isEmpty);
      expect(progress.children[1].startingComment, isNull);
      expect(progress.children[1].comment, 'Solitaire: Mistake.');
      final text = _write(source, progress);
      for (final spoiler in [
        'Bb5',
        'Nf3',
        'Bc4',
        'c4',
        'Original',
        '[%clk',
        '[%eval',
      ]) {
        expect(
          text,
          isNot(contains(spoiler)),
          reason: '$spoiler is not yet revealed',
        );
      }

      final next = _roundTrip(
        source,
        solitaireProgress(source.tree!, attempts, _ply(3)),
      );
      expect(mainlineSans(next), ['e4', 'e5', 'Nf3']);
      expect(next.nodeAt(_ply(2))!.children.map((move) => move.san), [
        'Nf3',
        'Bc4',
      ]);
      expect(
        next.nodeAt(_ply(2).child(1))!.comment,
        'Solitaire: Better than the game move.',
      );
      expect(_write(source, next), isNot(contains('Bb5')));
    },
  );

  test(
    'underpromotion retains original spelling and noninitial move numbers',
    () {
      final source = readGame('''
[SetUp "1"]
[FEN "8/P7/8/8/8/8/7k/K7 w - - 0 42"]
[Result "*"]

42. a8Q *
''');
      expect(source.issues, isEmpty);
      final review = solitaireReview(source.tree!, const [
        SolitaireAttempt(
          at: NodePath.root(),
          uci: 'a7a8n',
          outcome: SolitaireOutcome.goodMove,
        ),
      ]);
      final text = _write(source, review);
      final restored = _roundTrip(source, review);
      expect(text, contains('42. a8Q'));
      expect(text, contains('(42. a8=N'));
      expect(restored.rootFen, source.tree!.rootFen);
      expect(restored.children.first.spelling, 'a8Q');
      expect(restored.children[1].uci, 'a7a8n');
      expect(
        restored.children[1].fen.value,
        startsWith('N7/8/8/8/8/8/7k/K7 b'),
      );
    },
  );

  test(
    'black castling normalizes UCI before reusing or adding a variation',
    () {
      final source = readGame('''
[SetUp "1"]
[FEN "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 23"]
[Result "*"]

23... 0-0 *
''');
      expect(source.issues, isEmpty);
      final review = solitaireReview(source.tree!, const [
        SolitaireAttempt(
          at: NodePath.root(),
          uci: 'e8g8',
          outcome: SolitaireOutcome.gameMove,
        ),
        SolitaireAttempt(
          at: NodePath.root(),
          uci: 'e8c8',
          outcome: SolitaireOutcome.betterMove,
        ),
      ]);
      final restored = _roundTrip(source, review);
      expect(restored.children, hasLength(2));
      expect(restored.children.map((move) => move.uci), ['e8h8', 'e8a8']);
      expect(restored.children.first.spelling, '0-0');
      expect(restored.children.first.comment, 'Solitaire: Game move.');
      expect(_write(source, review), contains('(23... O-O-O'));
    },
  );

  test(
    'stale paths and illegal attempts cannot extend the original mainline',
    () {
      final source = readGame('1. e4 *');
      final review = solitaireReview(source.tree!, [
        const SolitaireAttempt(
          at: NodePath.root(),
          uci: 'e2e5',
          outcome: SolitaireOutcome.mistake,
        ),
        SolitaireAttempt(
          at: NodePath.of([9]),
          uci: 'd2d4',
          outcome: SolitaireOutcome.mistake,
        ),
        SolitaireAttempt(
          at: _ply(1),
          uci: 'e7e5',
          outcome: SolitaireOutcome.goodMove,
        ),
      ]);
      expect(_write(source, review), _write(source, source.tree!));
    },
  );
}
