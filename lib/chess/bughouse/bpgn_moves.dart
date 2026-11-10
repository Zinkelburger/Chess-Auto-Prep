import 'dart:isolate';

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
/// at 80 columns, as PGN writes them; [closing] goes last. Without [clocks],
/// the moves go without their clocks.
String bpgnMovetext(
  TableLine line, {
  List<String> closing = const [],
  bool clocks = true,
}) {
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
              '${clock == null || !clocks ? '' : ' {${clockSeconds(clock)}}'}',
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
/// after the moves. [clocks] as [bpgnMovetext] takes it.
String tableLineText(TableLine line, {TableGame? game, bool clocks = true}) {
  final result = game?.tags['Result'];
  final moves = bpgnMovetext(
    line,
    clocks: clocks,
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

/// The games of a BPGN file: a game is its tags and the movetext after
/// them, so a tag after movetext starts the next, and text without tags is
/// one game. Only where each game starts and ends is kept, so a file of many
/// thousands of games is not copied game by game; a game's text is taken
/// when it is asked for.
final class BpgnGames {
  BpgnGames(this.text) : _bounds = _gameBounds(text);

  BpgnGames._(this.text, this._bounds);

  /// [text]'s games, found off the UI isolate when it is large: a FICS
  /// month runs to tens of megabytes, which takes a noticeable while to go
  /// through. A smaller file is gone through sooner than an isolate starts.
  static Future<BpgnGames> index(String text) async => text.length < _largeFile
      ? BpgnGames(text)
      : BpgnGames._(text, await Isolate.run(() => _gameBounds(text)));

  static const _largeFile = 1 << 20;

  final String text;

  /// Each game's start and end in [text], one after the other.
  final List<int> _bounds;

  int get length => _bounds.length ~/ 2;

  String operator [](int index) =>
      text.substring(_bounds[2 * index], _bounds[2 * index + 1]);
}

List<int> _gameBounds(String text) {
  final bounds = <int>[];
  var start = 0;
  var moves = false;
  var blank = true;
  void end(int at) {
    if (!blank) bounds.addAll([start, at]);
    start = at;
    moves = false;
    blank = true;
  }

  for (var line = 0; line < text.length;) {
    final stop = _lineEnd(text, line);
    final kind = _lineKind(text, line, stop);
    if (kind == _Line.tag && moves) end(line);
    if (kind != _Line.blank) blank = false;
    if (kind == _Line.moves) moves = true;
    line = stop;
  }
  end(text.length);
  return bounds;
}

/// Where the line of [text] that starts at [start] ends, its newline
/// included.
int _lineEnd(String text, int start) {
  final next = text.indexOf('\n', start);
  return next < 0 ? text.length : next + 1;
}

enum _Line { blank, tag, moves }

/// What the line of [text] from [start] to [stop] holds: nothing, a tag, or
/// anything else, which is movetext.
_Line _lineKind(String text, int start, int stop) {
  var i = start;
  while (i < stop && _blanks.contains(text.codeUnitAt(i))) {
    i++;
  }
  if (i == stop) return _Line.blank;
  return _tagStart.matchAsPrefix(text, i) == null ? _Line.moves : _Line.tag;
}

/// Space, tab, carriage return and newline.
const _blanks = {0x20, 0x09, 0x0D, 0x0A};
final _tagStart = RegExp(r'\[\w+[ \t]+"');

/// [text] split where its tags end: the tag lines at its start, and the
/// movetext from the first line that is not one. A tag-shaped note in the
/// movetext, as a FICS chat comment may hold, stays the movetext's.
({String header, String moves}) _split(String text) {
  for (var line = 0; line < text.length;) {
    final stop = _lineEnd(text, line);
    if (_lineKind(text, line, stop) == _Line.moves) {
      return (header: text.substring(0, line), moves: text.substring(line));
    }
    line = stop;
  }
  return (header: text, moves: '');
}

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
/// null when the text holds no bughouse moves at all. [game] is what the
/// text's tags say of its game and [start] the table it starts from, so a
/// game of a file can be named and set up without its moves.
final class PastedMovesRefused extends PastedMoves {
  const PastedMovesRefused(
    this.token, {
    this.game,
    this.start = TablePosition.initial,
  });

  final String? token;
  final TableGame? game;
  final TablePosition start;
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

/// The tags in [header], as written, and the engine moves an older arena
/// file's `Opening` tag played before its movetext.
({Map<String, String> tags, String? setup, List<String> opening}) _tags(
  String header,
) {
  final tags = <String, String>{};
  for (final tag in _tag.allMatches(header)) {
    tags[tag[1]!] = tag[2]!.replaceAllMapped(_escaped, (m) => m[1]!);
  }
  final setup = tags.remove('SetUpDualFEN');
  final opening = tags['Opening']?.trim() ?? '';
  return (
    tags: tags,
    setup: setup,
    opening: _engineMoves.hasMatch(opening)
        ? opening.split(RegExp(r'\s+'))
        : const [],
  );
}

final _escaped = RegExp(r'\\(.)');

/// The game [tags] describe, ending as its `Termination` tag says, else as
/// [closing] does; null without tags.
TableGame? _gameOf(Map<String, String> tags, {String? closing}) => tags.isEmpty
    ? null
    : TableGame(tags, ending: tags['Termination'] ?? closing);

/// One BPGN game back into a line: what [tableLineText] writes, hand edits
/// included, a FICS game, or an arena game. A move is SAN or coordinates
/// (`e7e5`, `f7g8q`), and the comment right after it holds its clock. A
/// `SetUpDualFEN` tag is the start and the other tags, those before the
/// movetext, are the game's.
/// Other comments are passed over but the last, which says how the game
/// ended when no `Termination` tag does. Every move must play, in order, or
/// nothing is taken.
///
/// An older arena file kept its opening in an `Opening` tag, as engine
/// moves, and started its movetext after it; the arena now writes the
/// opening in the movetext and keeps the tag. So the movetext is read from
/// the start, and when it does not play from there, after the tag's moves;
/// only then is the tag dropped, its moves being in the line.
PastedMoves readTableLineText(String text) {
  final (:header, :moves) = _split(text);
  final (:tags, :setup, :opening) = _tags(header);
  var root = TablePosition.initial;
  if (setup != null) {
    switch (readDualFen(setup)) {
      case SetupReady(:final position):
        root = position;
      case SetupRefused():
        return PastedMovesRefused(
          '[SetUpDualFEN "$setup"]',
          game: _gameOf(tags),
        );
    }
  }
  final whole = _read(moves, root, tags, const []);
  if (whole.result is PastedLine || opening.isEmpty) return whole.result;
  final after = _read(moves, root, {...tags}..remove('Opening'), opening);
  // How far each got into the movetext: the tag's own moves do not count.
  return after.result is PastedLine ||
          after.played - opening.length > whole.played
      ? after.result
      : whole.result;
}

/// The movetext [moves] played from [root] after the engine moves [opening];
/// [played] is how many of its moves played, which is how far it got when
/// it was refused.
({PastedMoves result, int played}) _read(
  String moves,
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

  PastedMovesRefused refused(String? token) =>
      PastedMovesRefused(token, game: _gameOf(tags), start: root);

  for (final move in opening) {
    final board = move[0] == '1' ? BoardNumber.one : BoardNumber.two;
    if (!play(board, move.substring(1))) {
      return (result: refused(move), played: played);
    }
  }
  String? closing;
  final tokens = _token.allMatches(moves).toList();
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
      return (result: refused(token[0]), played: played);
    }
    closing = null;
  }
  if (!taken) return (result: refused(null), played: played);
  return (
    result: PastedLine(line, game: _gameOf(tags, closing: closing)),
    played: played,
  );
}
