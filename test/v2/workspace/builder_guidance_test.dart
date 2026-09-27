import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/tree_edit.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/gap_walk.dart';
import 'package:chess_auto_prep/v2/workspace/replies.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import '../support/session_fixture.dart';
import '../support/replies_fixture.dart';

String pgn(String moves) => '[Event "Probe"]\n[Result "*"]\n\n$moves *\n';

final class RareReplyPolicy implements MovePolicy {
  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async => fen.whiteToMove
      ? const MaiaPolicy({'e2e4': 1})
      : const MaiaPolicy({'e7e5': .992, 'a7a6': .008});
}

void main() {
  test('equally covered alternatives retain their coverage', () async {
    final answers = parseChapter(
      name: 'Answers',
      text: pgn('1. e4 c5 2. Nf3') + pgn('1. d4 Nf6 2. c4'),
    );
    final elsewhere = {
      for (final fen in answeredPositions(answers.tree, Side.white))
        fen: 'Answers',
    };
    Future<GapWalk> walk(String text) async => (await walkGaps(
      tree: parseChapter(name: 'Probe', text: text).tree,
      side: Side.white,
      floor: .01,
      shares: (fen) async => fen.value.contains('/4P3/')
          ? {'e7e5': .4, 'c7c5': .6}
          : {'d7d5': .4, 'g8f6': .6},
      overtaken: () => false,
      elsewhere: elsewhere,
    ))!;
    expect((await walk(pgn('1. e4'))).covered, closeTo(.6, 1e-9));
    expect((await walk(pgn('1. d4'))).covered, closeTo(.6, 1e-9));
    expect(
      (await walk(pgn('1. e4') + pgn('1. d4'))).covered,
      closeTo(.6, 1e-9),
    );
  });

  test('a finished game has no gap to fill', () async {
    final tree = parseChapter(
      name: 'Mate',
      text: pgn('1. f3 e5 2. g4 Qh4#'),
    ).tree;
    final mate = NodePath.of([0, 0, 0, 0]);
    expect(positionOf(tree.fenAt(mate))!.isCheckmate, isTrue);
    final walk = (await walkGaps(
      tree: tree,
      side: Side.white,
      floor: .01,
      shares: (fen) async =>
          fen.value.contains('/6P1/') ? {'d8h4': 1.0} : {'e7e5': 1.0},
      overtaken: () => false,
    ))!;
    expect(walk.gaps, isEmpty);
    expect(walk.covered, 1);
  });

  test('a rare qualifying gap stays visible in Replies', () async {
    final fixture = await openSession('// Color: White\n${pgn('1. e4')}');
    final settings = SettingsStore(initial: const Settings(coverOnceIn: 200));
    final owners = RepliesFixture(
      fixture.session,
      policy: RareReplyPolicy(),
      settings: settings,
    );
    addTearDown(() {
      owners.dispose();
      settings.dispose();
      fixture.dispose();
    });
    await pumpEventQueue();
    fixture.session.forward();
    await pumpEventQueue();
    expect(
      owners.gaps.currentWalk!.gaps.whereType<MissingReply>().map((g) => g.uci),
      contains('a7a6'),
    );
    expect(
      (owners.replies.table as RepliesShown).rows.map((r) => r.uci),
      contains('a7a6'),
    );
  });
}
