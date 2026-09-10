/// Replays saved mainlines off the UI thread, including older tournaments.
library;

import 'dart:io' as io;
import 'dart:isolate';

import 'package:dartchess/dartchess.dart';

import '../../../constants/chess_constants.dart';

Future<List<String?>> loadTournamentFinalPositions(String pgnPath) async {
  try {
    final text = await io.File(pgnPath).readAsString();
    return await Isolate.run(() => tournamentFinalPositions(text));
  } catch (_) {
    return const [];
  }
}

List<String?> tournamentFinalPositions(String pgn) => [
  for (final game in PgnGame.parseMultiGamePgn(pgn)) _finalPosition(game),
];

String? _finalPosition(PgnGame game) {
  try {
    Position position = Chess.fromSetup(
      Setup.parseFen(game.headers['FEN'] ?? kStandardStartFen),
    );
    for (final node in game.moves.mainline()) {
      final move = position.parseSan(node.san);
      if (move == null) return null;
      position = position.play(move);
    }
    return position.fen;
  } catch (_) {
    return null;
  }
}
