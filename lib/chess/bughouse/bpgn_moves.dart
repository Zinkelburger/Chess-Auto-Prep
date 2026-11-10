import 'package:dartchess/dartchess.dart' show Role, Side;

import 'table.dart';
import 'table_game.dart';
import 'table_line.dart';
import 'table_setup.dart';

/// [line]'s moves as BPGN movetext in the order played, `1A. e4 1B. d4
/// 1a. e5`: the number is the board's own move number and the letter's case
/// is the mover's colour. The order is what makes it replayable, since a
/// drop on one board needs the capture on the other that came before it. A
/// move whose clock is known is followed by it, in seconds, as FICS writes
/// it: `1A. e4 {119.000}`. A hand edit is a comment where it was made,
/// `{ Hands edited on board 1: +N −2p }`, White's pieces in upper case.
/// Only each board's line is written, not its variations. Lines are wrapped
/// at 80 columns, as PGN writes them; [closing] goes last.
String bpgnMovetext(TableLine line, {List<String> closing = const []}) {
  final tokens = <String>[
    for (final node in line.shown.nodes)
      switch (node.entry) {
        LineMove(
          :final board,
          :final side,
          :final number,
          :final san,
          :final clock,
        ) =>
          '$number${_letter(board, side)}. $san'
              '${clock == null ? '' : ' {${clockSeconds(clock)}}'}',
        HandEdit(:final board, :final changes) =>
          '{ $_editNote ${board.digit}: ${handChangeText(changes)} }',
      },
    ...closing,
  ];
  final lines = <String>[];
  var current = '';
  for (final token in tokens) {
    if (current.isNotEmpty && current.length + token.length + 1 > 80) {
      lines.add(current);
      current = '';
    }
    current = current.isEmpty ? token : '$current $token';
  }
  if (current.isNotEmpty) lines.add(current);
  return lines.join('\n');
}

const _editNote = 'Hands edited on board';

String _letter(BoardNumber board, Side side) {
  final letter = board == BoardNumber.one ? 'A' : 'B';
  return side == Side.white ? letter : letter.toLowerCase();
}

/// What the Bughouse mode copies: the line's movetext, after a
/// `SetUpDualFEN` tag when it does not start from the usual table. With
/// [game], a whole BPGN game: its tags first, and its ending and result
/// after the moves.
String tableLineText(TableLine line, {TableGame? game}) {
  final result = game?.tags['Result'];
  final moves = bpgnMovetext(
    line,
    closing: [
      // A Termination tag already says it.
      if (game?.ending case final ending?
          when ending != game?.tags['Termination'])
        '{$ending}',
      ?result,
    ],
  );
  final tags = [
    if (game != null)
      for (final MapEntry(:key, :value) in game.tags.entries)
        '[$key "${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"]',
    if (line.root.dualFen != TablePosition.initial.dualFen)
      '[SetUpDualFEN "${line.root.lichessDualFen}"]',
  ];
  return tags.isEmpty ? moves : '${tags.join('\n')}\n\n$moves';
}

/// The games in [text], each its own text: a game is its tags and the
/// movetext after them, so a tag after movetext starts the next. Text
/// without tags is one game.
List<String> bpgnGames(String text) {
  final games = <String>[];
  var current = StringBuffer();
  var moves = false;
  void end() {
    if (current.toString().trim().isNotEmpty) games.add(current.toString());
    current = StringBuffer();
    moves = false;
  }

  for (final line in text.split(RegExp(r'\r?\n'))) {
    final tag = _tagLine.hasMatch(line);
    if (tag && moves) end();
    if (!tag && line.trim().isNotEmpty) moves = true;
    current.writeln(line);
  }
  end();
  return games;
}

final _tagLine = RegExp(r'^\s*\[\w+\s+"');
final _tag = RegExp(r'\[(\w+)\s+"((?:[^"\\]|\\.)*)"\]');

sealed class PastedMoves {
  const PastedMoves();
}

final class PastedLine extends PastedMoves {
  const PastedLine(this.line, {this.game});

  final TableLine line;

  /// What the text's tags say of the game; null when it has none.
  final TableGame? game;
}

/// Nothing was pasted. [token] is the first move that does not play, or
/// null when the text holds no bughouse moves at all.
final class PastedMovesRefused extends PastedMoves {
  const PastedMovesRefused(this.token);

  final String? token;
}

final _token = RegExp(
  r'\{\s*'
  '$_editNote'
  r'\s*([12])\s*:([^}]*)\}'
  r'|\{([^}]*)\}'
  r'|(\d+)([AaBb])\.\s*([^\s{}()]+)',
);
final _change = RegExp('([+−-])(\\d*)([pnbrqPNBRQ])');

/// Moves as the engines write them, `1e2e4 2N@f3`: the board's digit, then
/// the move in coordinates. What an older arena file's `Opening` tag holds.
final _engineMoves = RegExp(
  r'^[12](?:[a-h][1-8][a-h][1-8][nbrq]?|[PNBRQ]@[a-h][1-8])'
  r'(?:\s+[12](?:[a-h][1-8][a-h][1-8][nbrq]?|[PNBRQ]@[a-h][1-8]))*$',
);

/// The tags of one game's [text], as written, and the engine moves an
/// older arena file's `Opening` tag played before its movetext.
({Map<String, String> tags, String? setup, List<String> opening}) _tags(
  String text,
) {
  final tags = <String, String>{};
  for (final tag in _tag.allMatches(text)) {
    tags[tag[1]!] = tag[2]!.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
  }
  final setup = tags.remove('SetUpDualFEN');
  final opening = tags['Opening']?.trim() ?? '';
  if (!_engineMoves.hasMatch(opening)) {
    return (tags: tags, setup: setup, opening: const []);
  }
  tags.remove('Opening');
  return (tags: tags, setup: setup, opening: opening.split(RegExp(r'\s+')));
}

/// What [text]'s tags say of its game, without reading its moves; null
/// when it has none.
TableGame? tableGameOf(String text) {
  final tags = _tags(text).tags;
  return tags.isEmpty ? null : TableGame(tags, ending: tags['Termination']);
}

/// One BPGN game back into a line: what [tableLineText] writes, hand edits
/// included, a FICS game, or an arena game. A move is SAN or coordinates
/// (`e7e5`, `f7g8q`), and the comment right after it holds its clock. A
/// `SetUpDualFEN` tag is the start and the other tags are the game's.
/// Other comments are passed over but the last, which says how the game
/// ended when no `Termination` tag does. Every move must play, in order, or
/// nothing is taken.
///
/// An older arena file kept its opening in an `Opening` tag, as engine
/// moves, and started its movetext after it; the arena now writes the
/// opening in the movetext and keeps the tag. So the movetext is read from
/// the start, and when it does not play from there, after the tag's moves.
PastedMoves readTableLineText(String text) {
  final (:tags, :setup, :opening) = _tags(text);
  var root = TablePosition.initial;
  if (setup != null) {
    switch (readDualFen(setup)) {
      case SetupReady(:final position):
        root = position;
      case SetupRefused():
        return PastedMovesRefused('[SetUpDualFEN "$setup"]');
    }
  }
  final whole = _read(text, root, tags, const []);
  if (whole.result is PastedLine || opening.isEmpty) return whole.result;
  final after = _read(text, root, tags, opening);
  return after.result is PastedLine || after.played > whole.played
      ? after.result
      : whole.result;
}

/// [text]'s movetext played from [root] after the engine moves [opening];
/// [played] is how many of its moves played, which is how far it got when
/// it was refused.
({PastedMoves result, int played}) _read(
  String text,
  TablePosition root,
  Map<String, String> tags,
  List<String> opening,
) {
  var line = TableLine(root);
  var position = root;
  var taken = false;
  var played = 0;

  /// Plays [move], SAN or coordinates, on [board]; false when it does not.
  bool play(BoardNumber board, String move, {Duration? clock}) {
    final uci = position.moveBySan(board, move)?.uci ?? move;
    final next = lineMove(position, board, uci, clock: clock);
    if (next == null) return false;
    line = line.played(next.move);
    position = next.after;
    played++;
    return taken = true;
  }

  for (final move in opening) {
    final board = move[0] == '1' ? BoardNumber.one : BoardNumber.two;
    if (!play(board, move.substring(1))) {
      return (result: PastedMovesRefused(move), played: played);
    }
  }
  String? closing;
  final tokens = _token.allMatches(text.replaceAll(_tag, ' ')).toList();
  for (final (i, token) in tokens.indexed) {
    if (token[1] case final digit?) {
      final board = digit == '1' ? BoardNumber.one : BoardNumber.two;
      for (final change in _change.allMatches(token[2]!)) {
        final letter = change[3]!;
        final count = int.tryParse(change[2]!) ?? 1;
        line = line.edited(
          board,
          letter == letter.toUpperCase() ? Side.white : Side.black,
          Role.values.firstWhere((r) => r.letter == letter.toLowerCase()),
          change[1] == '+' ? count : -count,
        );
        taken = true;
      }
      position = (line.replay() as LineReplayed).position;
      continue;
    }
    if (token[3] case final comment?) {
      final note = comment.trim();
      final said =
          clockComment(note) == null &&
          !note.startsWith('C:') &&
          note.contains(RegExp('[A-Za-z]'));
      if (said) closing = note;
      continue;
    }
    final board = token[5]!.toUpperCase() == 'A'
        ? BoardNumber.one
        : BoardNumber.two;
    final after = i + 1 < tokens.length ? tokens[i + 1][3] : null;
    final clock = after == null ? null : clockComment(after);
    if (!play(board, token[6]!, clock: clock)) {
      return (result: PastedMovesRefused(token[0]), played: played);
    }
    closing = null;
  }
  if (!taken) {
    return (result: const PastedMovesRefused(null), played: played);
  }
  final game = tags.isEmpty
      ? null
      : TableGame(tags, ending: tags['Termination'] ?? closing);
  return (result: PastedLine(line, game: game), played: played);
}
