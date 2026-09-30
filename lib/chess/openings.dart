import 'package:dartchess/dartchess.dart' show Chess, Position;

import 'fen.dart';
import 'pgn/chapter.dart';
import 'pgn/game_text.dart';
import 'pgn/game_tree.dart';

/// A named opening: `B90` and `Sicilian Defense: Najdorf Variation`.
final class Opening {
  const Opening(this.eco, this.name);

  final String eco;
  final String name;

  /// The way lila heads a position: the code, then the name.
  String get label => '$eco $name';

  @override
  bool operator ==(Object other) =>
      other is Opening && other.eco == eco && other.name == name;

  @override
  int get hashCode => Object.hash(eco, name);

  @override
  String toString() => label;
}

/// The named openings of the bundled lichess book
/// (github.com/lichess-org/chess-openings, CC0), looked up by position.
///
/// Representation: one entry per position the book names, keyed by
/// [Fen.position] — pieces, side, castling, en passant — so a game that
/// reaches the Najdorf by 1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6
/// or by any other order finds the same name. Where two rows reach one
/// position the first row keeps it.
///
/// Example: the row `B90  Sicilian Defense: Najdorf Variation  1. e4 c5 …
/// 5. Nc3 a6` is replayed to its last position, and that position's key
/// maps to (`B90`, `Sicilian Defense: Najdorf Variation`).
final class Openings {
  const Openings._(this._byPosition);

  /// No names: what the app shows before the book is read, or when it
  /// could not be.
  static const none = Openings._({});

  /// Reads [volumes], the text of each `eco / name / pgn` TSV file. The
  /// header row, blank lines and rows that are short or whose moves do not
  /// replay are skipped, so a damaged row costs its one name.
  factory Openings.parse(Iterable<String> volumes) {
    final byPosition = <String, Opening>{};
    for (final volume in volumes) {
      for (final row in volume.split('\n')) {
        final columns = row.trimRight().split('\t');
        if (columns.length < 3 || columns[0] == 'eco') continue;
        final end = _replay(columns[2]);
        if (end == null) continue;
        byPosition.putIfAbsent(
          Fen(end.fen).position,
          () => Opening(columns[0].trim(), columns[1].trim()),
        );
      }
    }
    return Openings._(byPosition);
  }

  final Map<String, Opening> _byPosition;

  bool get isEmpty => _byPosition.isEmpty;

  /// The name the book gives the position [fen], or null.
  Opening? at(Fen fen) => _byPosition[fen.position];

  /// The name of the last position of [line] the book names: the opening a
  /// game or a line is in once it has left the book.
  Opening? deepestIn(Iterable<Fen> line) {
    Opening? found;
    for (final fen in line) {
      found = at(fen) ?? found;
    }
    return found;
  }

  /// The name of the last named position on the way from [tree]'s start
  /// to [path]: lila's name for where the board is, which stays on the
  /// last opening once the moves leave the book.
  Opening? alongPath(GameTree tree, NodePath path) =>
      deepestIn([tree.rootFen, for (final node in tree.lineTo(path)) node.fen]);

  /// The name of the last named position of [tree]'s main line.
  Opening? ofMainLine(GameTree tree) =>
      alongPath(tree, tree.endOfLineFrom(const NodePath.root()));
}

/// The opening line over a board, the way lila names the position and a
/// book heads a game: the last named position on the way to [at] in
/// [chapter]. Before the first one, one game of a file is named by its own
/// `ECO`, `Opening` and `Variation` tags, else by the last named position
/// of its main line — unless [answerHidden], a puzzle's answer, whose moves
/// are not named before they are played. A merged chapter is many games
/// and has no name of its own before the book gives one. Empty when
/// nothing names it.
String openingLine(
  Openings book,
  Chapter chapter,
  NodePath at, {
  bool answerHidden = false,
}) {
  final tree = chapter.tree;
  if (book.alongPath(tree, at) case final here?) return here.label;
  final index = chapter.game;
  if (index == null || index >= chapter.lines.length) return '';
  final tags = chapter.lines[index].tags;
  String? known(String key) {
    final value = tagValue(tags, key)?.trim();
    return value == null || value.isEmpty || value == '?' ? null : value;
  }

  final name = [?known('Opening'), ?known('Variation')].join(', ');
  final tagged = [?known('ECO'), if (name.isNotEmpty) name].join(' ');
  if (tagged.isNotEmpty) return tagged;
  return answerHidden ? '' : book.ofMainLine(tree)?.label ?? '';
}

/// The position after [movetext] (`1. e4 c5 2. Nf3`) from the start, or
/// null when a move does not replay.
Position? _replay(String movetext) {
  Position position = Chess.initial;
  for (final token in movetext.split(' ')) {
    if (token.isEmpty || token.endsWith('.')) continue;
    final move = position.parseSan(token);
    if (move == null) return null;
    position = position.play(move);
  }
  return position;
}
