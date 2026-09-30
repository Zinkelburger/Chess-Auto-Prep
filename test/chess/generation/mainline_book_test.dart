import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/generation/mainline_book.dart';
import 'package:chess_auto_prep/chess/generation/search_config.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/search_result.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4_reader.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart' show positionOf;
import 'package:chess_auto_prep/chess/pv_text.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

Fen after(String moves) {
  var fen = Fen.initial;
  for (final uci in moves.split(' ').where((m) => m.isNotEmpty)) {
    fen = pvMoves(fen, [uci]).single.after;
  }
  return fen;
}

String at(String moves) => after(moves).position;

/// ChessDB's scores, from the side to move: e4 best; after it c5 and e5
/// level; after 1.e4 c5 Nf3 and d4 tie and masters prefer d4.
Map<String, List<ScoredBookMove>> chessDb() => {
  at(''): [(uci: 'e2e4', cp: 30), (uci: 'd2d4', cp: 25)],
  at('e2e4'): [(uci: 'c7c5', cp: -30), (uci: 'e7e5', cp: -35)],
  at('e2e4 c7c5'): [(uci: 'g1f3', cp: 35), (uci: 'd2d4', cp: 35)],
  at('e2e4 e7e5'): [(uci: 'g1f3', cp: 40)],
  at('e2e4 c7c5 d2d4'): [(uci: 'c5d4', cp: -30)],
  at('e2e4 e7e5 g1f3'): [(uci: 'b8c6', cp: -40)],
};

Map<String, List<PlayedMove>> masters() => {
  at('e2e4'): [
    (uci: 'c7c5', games: 600),
    (uci: 'e7e5', games: 400),
    (uci: 'e7e6', games: 30),
  ],
  at('e2e4 c7c5'): [(uci: 'd2d4', games: 900), (uci: 'g1f3', games: 100)],
};

/// ChessDB's answer from [chessDb], nothing where it knows nothing.
BookAnswer known(Fen fen) => BookMoves(chessDb()[fen.position] ?? const []);

void main() {
  Future<SearchResult> build({
    int linePlies = 4,
    int branchPlies = 8,
    Future<BookAnswer> Function(Fen)? movesAt,
    SearchNode? seed,
  }) => buildMainlineBook(
    root: positionOf(Fen.initial)!,
    config: MainlineConfig(
      side: Side.white,
      linePlies: linePlies,
      branchPlies: branchPlies,
    ),
    movesAt: movesAt ?? (fen) async => known(fen),
    practiceAt: (fen) async => masters()[fen.position] ?? const [],
    seed: seed,
  );

  test('our move is ChessDB\'s best; theirs are the masters\' replies, '
      'weighted by their games, until most of them are covered', () async {
    final tree = (await build() as SearchComplete).tree as OurNode;
    expect(tree.candidates.map((c) => c.move.san), ['e4']);
    final replies = (tree.chosen.child as OpponentNode).replies;
    expect(replies.map((r) => r.move.san), ['c5', 'e5']);
    expect(replies.map((r) => r.probability), [0.6, 0.4]);
    final sicilian = replies.first.child as OurNode;
    expect(
      sicilian.chosen.move.san,
      'd4',
      reason: 'a tie goes to the move masters played most',
    );
    final afterD4 = sicilian.chosen.child as OpponentNode;
    expect(afterD4.replies.single.move.san, 'cxd4');
    expect(
      afterD4.replies.single.probability,
      1,
      reason: 'where masters never went ChessDB\'s best is all of it',
    );
    expect(
      afterD4.replies.single.child,
      isA<HorizonNode>(),
      reason: 'the line is as long as it may be',
    );
  });

  test(
    'past the branching depth the opponent plays ChessDB\'s best too',
    () async {
      final tree =
          (await build(branchPlies: 1) as SearchComplete).tree as OurNode;
      final replies = (tree.chosen.child as OpponentNode).replies;
      expect(replies.single.move.san, 'c5');
    },
  );

  test('a line ends where ChessDB knows nothing more', () async {
    final tree = (await build(linePlies: 10) as SearchComplete).tree as OurNode;
    final open = (tree.chosen.child as OpponentNode).replies[1].child;
    final afterNc6 =
        ((open as OurNode).chosen.child as OpponentNode).replies.single.child;
    expect(afterNc6, isA<HorizonNode>());
    expect(afterNc6.evalForUs.cp, 40, reason: 'valued by the move into it');
  });

  test('a line ChessDB knows nothing more of stays finished through a save, '
      'and a resume does not ask about it again', () async {
    // e5 is a masters' reply ChessDB does not score, and it knows nothing
    // after it either: a dead end with no score of its own.
    Future<BookAnswer> answers(Fen fen) async => switch (fen.position) {
      final p when p == at('e2e4') => const BookMoves([(uci: 'c7c5', cp: -30)]),
      final p when p == at('e2e4 e7e5') => const BookMoves([]),
      _ => known(fen),
    };
    const linePlies = 10;
    final built =
        (await build(linePlies: linePlies, movesAt: answers)) as SearchComplete;
    final saved = encodeTreeV4(
      built.tree,
      const SearchConfig(
        side: Side.white,
        horizonPlies: linePlies,
        lossLimitCp: null,
      ),
      complete: true,
    );
    final read = decodeTreeV4(saved) as TreeDecoded;
    final replies =
        ((read.root as OurNode).chosen.child as OpponentNode).replies;
    final afterCxd4 =
        ((replies.first.child as OurNode).chosen.child as OpponentNode)
            .replies
            .single
            .child;
    expect(afterCxd4, isA<HorizonNode>(), reason: 'ply 4, scored');
    expect(afterCxd4.evalForUs.cp, 30);
    final e5 = replies.firstWhere((r) => r.move.san == 'e5').child;
    expect(e5, isA<HorizonNode>(), reason: 'ply 2, never scored');
    expect(e5.evaluated, isFalse);

    final asked = <String>[];
    final resumed = await build(
      linePlies: linePlies,
      seed: read.root,
      movesAt: (fen) async {
        asked.add(fen.position);
        return answers(fen);
      },
    );
    expect(resumed, isA<SearchComplete>());
    expect(asked, isEmpty);
  });

  test('ChessDB going quiet stops the book with what it has, and a resume '
      'goes on from there', () async {
    var answers = 0;
    final stopped = await build(
      movesAt: (fen) async => ++answers > 2 ? const BookLost() : known(fen),
    );
    expect(stopped, isA<SearchIncomplete>());
    final partial = (stopped as SearchIncomplete).tree as OurNode;
    final replies = (partial.chosen.child as OpponentNode).replies;
    expect(replies.first.child, isA<FrontierNode>());
    final resumed = await build(seed: partial);
    expect(resumed, isA<SearchComplete>());
    final whole = (resumed as SearchComplete).tree as OurNode;
    final sicilian =
        (whole.chosen.child as OpponentNode).replies.first.child as OurNode;
    expect(sicilian.chosen.move.san, 'd4');
  });

  test('ChessDB out of reach from the start is a failure, not an empty '
      'book', () async {
    expect(
      await build(movesAt: (_) async => const BookLost()),
      isA<EvaluationFailed>(),
    );
    expect(
      await build(movesAt: (_) async => const BookMissed()),
      isA<EvaluationFailed>(),
    );
  });

  test('ChessDB going quiet part way stops the book as incomplete, for that '
      'reason, keeping what it built', () async {
    var asked = 0;
    final result = await build(
      movesAt: (fen) async => ++asked == 1 ? known(fen) : const BookLost(),
    );
    final stopped = result as SearchIncomplete;
    expect(stopped.reason, StopReason.sourceUnavailable);
    expect((stopped.tree as OurNode).candidates.single.move.san, 'e4');
  });

  test('a masters\' reply ChessDB does not score is left unscored, not '
      'given their best move\'s score', () async {
    final tree =
        (await build(
                      linePlies: 2,
                      movesAt: (fen) async => fen.position == at('e2e4')
                          ? const BookMoves([(uci: 'c7c5', cp: -30)])
                          : known(fen),
                    )
                    as SearchComplete)
                .tree
            as OurNode;
    final replies = (tree.chosen.child as OpponentNode).replies;
    final e5 = replies.firstWhere((r) => r.move.san == 'e5');
    final c5 = replies.firstWhere((r) => r.move.san == 'c5');
    expect(e5.child.evaluated, isFalse);
    expect(c5.child.evaluated, isTrue);
  });

  test('one position ChessDB does not answer is left to do while the rest '
      'is built, and a resume asks about it again', () async {
    final result = await build(
      movesAt: (fen) async =>
          fen.position == at('e2e4 c7c5') ? const BookMissed() : known(fen),
    );
    final incomplete = result as SearchIncomplete;
    expect(incomplete.reason, StopReason.unanswered);
    final replies =
        ((incomplete.tree as OurNode).chosen.child as OpponentNode).replies;
    expect(replies.first.child, isA<FrontierNode>(), reason: 'the miss');
    expect(
      replies[1].child,
      isA<OurNode>(),
      reason: 'the line beside it is still built',
    );
    final resumed = await build(seed: incomplete.tree);
    expect(resumed, isA<SearchComplete>());
  });

  test('a run out of requests stops the book as a budget does, not as '
      'ChessDB going quiet', () async {
    var asked = 0;
    final result = await build(
      movesAt: (fen) async => ++asked > 2 ? const BookSpent() : known(fen),
    );
    final stopped = result as SearchIncomplete;
    expect(stopped.reason, StopReason.nodeBudget);
    expect((stopped.tree as OurNode).candidates.single.move.san, 'e4');
  });

  group('castling, which masters spell king onto rook', () {
    // 1.e4 e5 2.Nf3 Nc6 3.Bc4 Bc5 4.O-O Nf6 5.d3, Black to move.
    const giuoco = 'e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 e1h1 g8f6 d2d3';
    const played = [(uci: 'e8h8', games: 70), (uci: 'd7d6', games: 30)];
    Future<SearchResult> castle(
      List<ScoredBookMove> scored, {
      int branchPlies = 8,
      List<PlayedMove> practice = played,
    }) => buildMainlineBook(
      root: positionOf(after(giuoco))!,
      config: MainlineConfig(
        side: Side.white,
        linePlies: 1,
        branchPlies: branchPlies,
      ),
      movesAt: (fen) async =>
          BookMoves(fen.position == at(giuoco) ? scored : const []),
      practiceAt: (fen) async =>
          fen.position == at(giuoco) ? practice : const [],
    );

    test(
      'is a reply the book keeps, so the shares still add up to one',
      () async {
        final result = await castle(const [
          (uci: 'e8g8', cp: -20),
          (uci: 'd7d6', cp: -30),
        ]);
        final replies =
            ((result as SearchComplete).tree as OpponentNode).replies;
        expect(replies.map((r) => r.move.uci), ['e8g8', 'd7d6']);
        expect(replies.map((r) => r.move.san), ['O-O', 'd6']);
        expect(replies.map((r) => r.probability), [0.7, 0.3]);
        expect(
          replies.fold(0.0, (sum, r) => sum + r.probability),
          closeTo(1, 1e-9),
        );
        expect(
          replies.first.child.evalForUs.cp,
          20,
          reason: 'ChessDB scores castling under its own spelling',
        );
      },
    );

    test('counts its masters\' games when ChessDB scores it level with '
        'another move', () async {
      final result = await castle(const [
        (uci: 'd7d6', cp: -20),
        (uci: 'e8g8', cp: -20),
      ], branchPlies: 0);
      final replies = ((result as SearchComplete).tree as OpponentNode).replies;
      expect(replies.single.move.uci, 'e8g8');
    });

    test('adds up its games under both spellings and gives an illegal move '
        'no share', () async {
      final result = await castle(
        const [(uci: 'e8g8', cp: -20), (uci: 'd7d6', cp: -30)],
        practice: const [
          (uci: 'e8h8', games: 60),
          (uci: 'd7d6', games: 30),
          (uci: 'e8g8', games: 10),
          (uci: 'e8e6', games: 10),
        ],
      );
      final replies = ((result as SearchComplete).tree as OpponentNode).replies;
      expect(replies.map((r) => r.move.uci), ['e8g8', 'd7d6']);
      expect(replies.first.probability, closeTo(0.7, 1e-9));
      expect(replies.last.probability, closeTo(0.3, 1e-9));
    });
  });
}
