import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const text = '[Event "Course"]\n[Result "*"]\n\n1. e4 e5 (1... c5) *';
  test(
    'explicit scope controls tree paths through both isolate routes',
    () async {
      final mainlines = await OpeningTreeBuilder.buildTree(
        pgnList: [text],
        username: '',
        userIsWhite: null,
        strictPlayerMatching: false,
        includeVariations: false,
      );
      final allLines = await OpeningTreeBuilder.buildTree(
        pgnList: [text],
        username: '',
        userIsWhite: null,
        strictPlayerMatching: false,
        includeVariations: true,
        onProgress: (_, _) {},
      );
      mainlines.makeMove('e4');
      allLines.makeMove('e4');
      expect(mainlines.continuations.map((m) => m.move), ['e5']);
      expect(
        allLines.continuations.map((m) => m.move),
        containsAll(['e5', 'c5']),
      );
    },
  );
  test('position lookup and index respect mainlines versus variations', () {
    Position position = Chess.initial;
    for (final san in ['e4', 'c5']) {
      position = position.play(position.parseSan(san)!);
    }
    final fen = normalizeFen(position.fen);
    final records = [
      (headers: <String, String>{'Result': '*'}, pgnText: text),
    ];
    expect(buildFenIndex(records)[fen], [0]);
    expect(buildMainlineFenIndex(records)[fen], isNull);
    expect(
      gamePassesThroughFen(
        records.first.headers,
        text,
        fen,
        includeVariations: false,
      ),
      isFalse,
    );
  });
  test(
    'cached coverage excludes null moves but retains PGN ply coordinates',
    () {
      final cached = parseCachedEvals(
        '1. e4 {[%eval 0.2]} Z0 2. Nf3 {[%eval 0.3]} *',
      );
      expect(cached, isNotNull);
      expect(cached!.totalMoves, 2);
      expect(cached.evals.map((e) => e.ply), [1, 3]);
    },
  );
}
