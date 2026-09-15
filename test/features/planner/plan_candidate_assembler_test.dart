import 'package:chess_auto_prep/features/planner/controllers/plan_candidate_assembler.dart';
import 'package:chess_auto_prep/features/planner/models/plan_models.dart';
import 'package:chess_auto_prep/features/planner/services/plan_knowledge.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:flutter_test/flutter_test.dart';

const _afterC4 = 'rnbqkbnr/ppp1pppp/8/3p4/2PP4/8/PP2PPPP/RNBQKBNR b KQkq - 0 2';
const _afterD4d5 =
    'rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 2';

const _sourced = [
  PlanCandidate(san: 'e6', maiaProb: 0.40),
  PlanCandidate(san: 'c6', maiaProb: 0.30),
  PlanCandidate(san: 'dxc4', maiaProb: 0.15),
];

void main() {
  group('book basis', () {
    const assembler = PlanCandidateAssembler(
      knowledge: PlanKnowledge.empty,
      walksOwnGames: false,
      chapterShare: 0.08,
    );

    test('our move: nothing pre-ticked without chapters or games', () {
      final out = assembler.assemble(
        _sourced,
        fen: _afterC4,
        ourMove: true,
        ownFloor: 3,
      );
      expect(out.candidates.map((c) => c.san), ['e6', 'c6', 'dxc4']);
      expect(out.preselected, isEmpty);
    });

    test('their move: replies at or above the chapter share are ticked', () {
      final out = assembler.assemble(
        const [
          PlanCandidate(san: 'c4', maiaProb: 0.80),
          PlanCandidate(san: 'Bf4', maiaProb: 0.15),
          PlanCandidate(san: 'Nf3', maiaProb: 0.05),
        ],
        fen: _afterD4d5,
        ourMove: false,
        ownFloor: 3,
      );
      expect(out.preselected, {'c4', 'Bf4'});
    });

    test('the chapter move is ticked and added when unlisted', () {
      final knowledge = PlanKnowledge(
        chapterMoves: {
          normalizeFen(_afterC4): {'Nc6': 1},
        },
      );
      final out = PlanCandidateAssembler(
        knowledge: knowledge,
        walksOwnGames: false,
        chapterShare: 0.08,
      ).assemble(_sourced, fen: _afterC4, ourMove: true, ownFloor: 3);
      expect(out.candidates.map((c) => c.san), ['e6', 'c6', 'dxc4', 'Nc6']);
      expect(out.candidates.last.inChapters, isTrue);
      expect(out.preselected, {'Nc6'});
    });

    test('own games pre-tick only when played enough and consistently', () {
      PlanKnowledge games(Map<String, int> counts) =>
          PlanKnowledge(ownMoves: {normalizeFen(_afterC4): counts});
      Set<String> preselected(PlanKnowledge knowledge) =>
          PlanCandidateAssembler(
                knowledge: knowledge,
                walksOwnGames: false,
                chapterShare: 0.08,
              )
              .assemble(_sourced, fen: _afterC4, ourMove: true, ownFloor: 3)
              .preselected;
      // Fewer than five games here: no default.
      expect(preselected(games({'e6': 2, 'c6': 1})), isEmpty);
      // Six games but no move at 40% of them: no default.
      expect(preselected(games({'e6': 2, 'c6': 2, 'dxc4': 2})), isEmpty);
      // Five games, four of them ...c6: the favourite is the default.
      expect(preselected(games({'e6': 1, 'c6': 4})), {'c6'});
    });
  });

  group('own-games basis', () {
    final knowledge = PlanKnowledge(
      ownMoves: {
        normalizeFen(_afterC4): {'c6': 3, 'e6': 3, 'Nc6': 1},
      },
      ownReplies: {
        normalizeFen(_afterD4d5): {'c4': 11, 'Bf4': 2},
      },
    );
    final assembler = PlanCandidateAssembler(
      knowledge: knowledge,
      walksOwnGames: true,
      chapterShare: 0.08,
    );

    test('played moves come first, ties keep the source order', () {
      final out = assembler.assemble(
        _sourced,
        fen: _afterC4,
        ourMove: true,
        ownFloor: 3,
      );
      // e6 and c6 tie at 3 games: source order (e6 first); dxc4 was never
      // played; Nc6, unlisted by the sources, still gets a row.
      expect(out.candidates.map((c) => c.san), ['e6', 'c6', 'Nc6', 'dxc4']);
      expect(out.candidates.first.ownGames, 7);
      expect(out.preselected, {'e6'});
    });

    test('their move: replies met at least ownFloor times are ticked', () {
      final out = assembler.assemble(
        const [
          PlanCandidate(san: 'c4', maiaProb: 0.80),
          PlanCandidate(san: 'Bf4', maiaProb: 0.15),
        ],
        fen: _afterD4d5,
        ourMove: false,
        ownFloor: 3,
      );
      expect(out.preselected, {'c4'});
      expect(out.candidates.first.ownShare, closeTo(11 / 13, 1e-9));
    });
  });
}
