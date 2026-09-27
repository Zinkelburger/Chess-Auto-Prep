import 'package:dartchess/dartchess.dart' show Side;

import '../pgn/game_text.dart';
import '../pgn/game_tree.dart';
import '../pgn/move_label.dart' show numberedMoves;
import '../pgn/pgn_reader.dart';
import '../tactics/game_ids.dart';

/// How a game went for the user.
enum GameOutcome { won, lost, drawn, unfinished }

/// One of the user's own games, read for the book check: who they played
/// and how it went, and the main line as the positions it passed through.
///
/// [positions] has one more entry than [moves]: the position before each
/// move, then the one after the last. Both are [Fen.position] keys, so they
/// can be looked up in a `RepertoireIndex` as they are.
final class PlayedGame {
  const PlayedGame({
    required this.index,
    required this.id,
    required this.side,
    required this.opponent,
    required this.opponentElo,
    required this.outcome,
    required this.date,
    required this.playedAt,
    required this.moves,
    required this.positions,
  });

  /// Where the game is in the file it was read from, counting from zero.
  final int index;

  /// The id both apps file it under, or empty when it has none.
  final String id;

  /// The side the user played.
  final Side side;

  final String opponent;

  /// The opponent's rating as the site gave it, or empty.
  final String opponentElo;

  final GameOutcome outcome;

  /// `2026.09.20`, or empty when the game does not say.
  final String date;

  /// When it was played, as text that sorts: `2026.09.20 10:00:00`.
  final String playedAt;

  /// The main line, each move numbered as it would start a line: `6.f3`,
  /// `6...Nf6`.
  final List<PlayedMove> moves;

  /// The position before each move, then the one after the last.
  final List<String> positions;

  /// The words a search over the games looks through, lowercased.
  String get searchText => '$opponent $date'.toLowerCase();
}

/// One move of a [PlayedGame]'s main line.
typedef PlayedMove = ({String uci, String label});

/// Game [index] of a file of [username]'s games, or null when it is not
/// theirs to check: another player's, a variant, or one whose moves cannot
/// be read.
PlayedGame? readPlayedGame(
  String text, {
  required int index,
  required String username,
}) {
  final read = readGame(text);
  final tree = read.tree;
  final side = sideOf(read.tags, username);
  if (tree == null || side == null || !isStandardChess(read.tags)) {
    return null;
  }
  final opponentSide = side == Side.white ? 'Black' : 'White';
  final moves = <PlayedMove>[];
  final positions = [tree.rootFen.position];
  for (final node in _mainLine(tree)) {
    moves.add((uci: node.uci, label: numberedMoves([node])));
    positions.add(node.fen.position);
  }
  return PlayedGame(
    index: index,
    id: gameIdIn(text),
    side: side,
    opponent: _known(tagValue(read.tags, opponentSide)) ?? '?',
    opponentElo: _known(tagValue(read.tags, '${opponentSide}Elo')) ?? '',
    outcome: _outcome(tagValue(read.tags, 'Result'), side),
    date:
        _known(tagValue(read.tags, 'UTCDate') ?? tagValue(read.tags, 'Date')) ??
        '',
    playedAt: playedAt(text),
    moves: List.unmodifiable(moves),
    positions: List.unmodifiable(positions),
  );
}

Iterable<MoveNode> _mainLine(GameTree tree) sync* {
  var next = tree.children;
  while (next.isNotEmpty) {
    yield next.first;
    next = next.first.children;
  }
}

GameOutcome _outcome(String? result, Side side) =>
    switch ((result?.trim(), side)) {
      ('1-0', Side.white) || ('0-1', Side.black) => GameOutcome.won,
      ('0-1', Side.white) || ('1-0', Side.black) => GameOutcome.lost,
      ('1/2-1/2', _) => GameOutcome.drawn,
      _ => GameOutcome.unfinished,
    };

String? _known(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty || trimmed == '?' ? null : trimmed;
}
