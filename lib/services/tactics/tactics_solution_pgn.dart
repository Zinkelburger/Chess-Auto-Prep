/// Build a PGN string for a tactic with its solution as the mainline.
library;

import 'package:dartchess/dartchess.dart';

import '../../models/tactics_position.dart';

/// PGN from the tactic FEN with [solutionSan] as the mainline, carrying the
/// source-game headers so the analysis tab shows meaningful context.
String buildSolutionPgn(TacticsPosition tactic, List<String> solutionSan) {
  String escaped(String s) => s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  final headers = StringBuffer();
  headers.writeln('[White "${escaped(tactic.gameWhite)}"]');
  headers.writeln('[Black "${escaped(tactic.gameBlack)}"]');
  if (tactic.gameDate.isNotEmpty) {
    headers.writeln('[Date "${escaped(tactic.gameDate)}"]');
  }
  headers.writeln('[Result "*"]');
  headers.writeln('[FEN "${tactic.fen}"]');
  headers.writeln('[SetUp "1"]');

  if (solutionSan.isEmpty) return '${headers.toString()}\n*';

  final setup = Setup.parseFen(tactic.fen);
  final buf = StringBuffer();
  var moveNum = setup.fullmoves;
  var isWhite = setup.turn == Side.white;

  for (int i = 0; i < solutionSan.length; i++) {
    if (isWhite) {
      buf.write('$moveNum. ');
    } else if (i == 0) {
      buf.write('$moveNum... ');
    }
    buf.write(solutionSan[i]);
    if (!isWhite) moveNum++;
    isWhite = !isWhite;
    if (i < solutionSan.length - 1) buf.write(' ');
  }
  buf.write(' *');

  return '${headers.toString()}\n$buf';
}
