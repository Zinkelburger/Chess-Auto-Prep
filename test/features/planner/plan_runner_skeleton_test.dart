import 'package:chess_auto_prep/features/planner/controllers/plan_runner.dart';
import 'package:chess_auto_prep/features/planner/models/plan_models.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// A planned build hands its chapter paths to the skeleton plan, so the
/// selector pins the user's chosen moves and transfers them to look-alike
/// positions in sibling chapters.
void main() {
  test('chapter paths become pins; form pins are kept; no duplicates', () {
    final plan = RepertoirePlan(
      isWhite: false,
      elo: 1800,
      minShare: 0.05,
      chapters: [
        PlanChapter(
          name: 'QGD',
          family: 'QGD',
          moves: ['d4', 'd5', 'c4', 'e6'],
          points: [
            const PlanBuildPoint(moves: ['d4', 'd5', 'c4', 'e6', 'Nc3']),
            const PlanBuildPoint(moves: ['d4', 'd5', 'c4', 'e6']),
          ],
        ),
        PlanChapter(
          name: 'London',
          family: 'London System',
          moves: ['d4', 'd5', 'Bf4'],
          points: [
            const PlanBuildPoint(moves: ['d4', 'd5', 'Bf4', 'c5']),
          ],
        ),
      ],
    );
    final base = SkeletonPlan.fromLines(const [
      '1.d4 Nf6 2.c4 c5',
    ], playAsWhite: false);
    final merged = PlanRunner.withPlanLines(base, plan);

    // Black's moves along each path: …d5, …e6 (QGD/dup share it), …c5 —
    // plus the form's own …Nf6 / …c5. Nodes keep every pin; the by-position
    // map keeps one per position, and the walk's choice (later) wins there.
    final ucis = merged.nodes.map((n) => n.uci).toSet();
    expect(ucis, containsAll(['d7d5', 'e7e6', 'c7c5', 'g8f6']));
    expect(merged.pinsByFen.values, contains('d7d5'));
    // …e6 after 1.d4 d5 2.c4 appears in two chapters but pins once.
    final e6Pins = merged.nodes.where((n) => n.uci == 'e7e6').length;
    expect(e6Pins, 1);
    expect(merged.sourceLines.first, '1.d4 Nf6 2.c4 c5');
    expect(merged.sourceLines.length, 4);
  });

  test('an empty plan leaves the form skeleton untouched', () {
    const base = SkeletonPlan();
    final plan = const RepertoirePlan(
      isWhite: true,
      elo: 1800,
      minShare: 0.05,
      chapters: [],
    );
    expect(identical(PlanRunner.withPlanLines(base, plan), base), isTrue);
  });
}
