/// Setting a table up by hand: a FEN per board and each player's reserve
/// written as pieces (`2N Q P`), checked before they become a position.
///
/// Bughouse keeps every piece — all 64 are on a board or in a reserve — so
/// the boxes also say what is still to be placed, live as they are typed.
library;

import 'package:dartchess/dartchess.dart';

import 'table.dart';

/// What the setup boxes under one board hold: the board's FEN without its
/// reserve, and the reserves of White and Black on it.
typedef BoardBoxes = ({String fen, String white, String black});

sealed class SetupRead {
  const SetupRead();
}

final class SetupReady extends SetupRead {
  const SetupReady(this.position);

  final TablePosition position;
}

/// What is wrong, per board, in words for the line under its boxes.
final class SetupRefused extends SetupRead {
  const SetupRefused(this.problems);

  final Map<BoardNumber, String> problems;
}

/// The boxes for [position]'s [board], as the user would have typed them.
BoardBoxes boxesOf(TablePosition position, BoardNumber board) {
  final fen = position.board(board).fen;
  final fields = fen.split(' ');
  final open = fields.first.indexOf('[');
  final pocket = open < 0
      ? ''
      : fields.first.substring(open + 1, fields.first.length - 1);
  fields[0] = open < 0 ? fields.first : fields.first.substring(0, open);
  final letters = pocket.split('');
  return (
    fen: fields.join(' '),
    white: formatReserve(letters.where(_isUpper).join()),
    black: formatReserve(letters.where((l) => !_isUpper(l)).join()),
  );
}

/// A pasted `<board 1>|<board 2>`, or a single FEN for board 1 with board 2
/// at the start, as the MCP server and the old app read one.
SetupRead readDualFen(String text) {
  final parts = text.trim().split('|');
  if (parts.length > 2 || parts.first.trim().isEmpty) {
    return const SetupRefused({
      BoardNumber.one: 'That is not a valid dual FEN.',
    });
  }
  final boards = [
    for (final part in parts) _splitBoxes(part.trim()),
    if (parts.length == 1) boxesOf(TablePosition.initial, BoardNumber.two),
  ];
  return readBoxes(boards[0], boards[1]);
}

/// Both boards from their boxes, or what is wrong with each.
SetupRead readBoxes(BoardBoxes one, BoardBoxes two) {
  final problems = <BoardNumber, String>{};
  final built = <BoardNumber, Crazyhouse>{};
  for (final (board, boxes) in [
    (BoardNumber.one, one),
    (BoardNumber.two, two),
  ]) {
    switch (_readBoard(board, boxes)) {
      case _Built(:final position):
        built[board] = position;
      case _Wrong(:final message):
        problems[board] = message;
    }
  }
  if (problems.isNotEmpty) return SetupRefused(problems);
  return SetupReady(
    TablePosition(built[BoardNumber.one]!, built[BoardNumber.two]!),
  );
}

sealed class _BoardRead {
  const _BoardRead();
}

final class _Built extends _BoardRead {
  const _Built(this.position);

  final Crazyhouse position;
}

final class _Wrong extends _BoardRead {
  const _Wrong(this.message);

  final String message;
}

_BoardRead _readBoard(BoardNumber board, BoardBoxes boxes) {
  final FenShape shape;
  switch (checkFen(boxes.fen)) {
    case FenWrong(:final message):
      return _Wrong(message);
    case final FenShape read:
      shape = read;
  }
  final problems = <String>[];
  final reserve = StringBuffer(shape.pocket);
  for (final (side, text) in [
    (Side.white, boxes.white),
    (Side.black, boxes.black),
  ]) {
    switch (parseReserve(text)) {
      case ReserveWrong(:final message):
        problems.add('Player ${Seat.of(board, side).letter}: $message');
      case ReservePieces(:final letters):
        reserve.write(side == Side.white ? letters : letters.toLowerCase());
    }
  }
  if (problems.isNotEmpty) return _Wrong(problems.join(' '));
  final fen = '${shape.placement}[$reserve] ${shape.rest}';
  try {
    return _Built(
      Crazyhouse.fromSetup(Setup.parseFen(fen), ignoreImpossibleCheck: true),
    );
  } on FenException {
    return const _Wrong('That is not a valid FEN.');
  } on PositionSetupException {
    return const _Wrong('That leaves an impossible position.');
  }
}

/// One board's FEN, pocket and all, split into its boxes.
BoardBoxes _splitBoxes(String fen) {
  final fields = fen.split(RegExp(r'\s+'));
  final placement = fields.first;
  final open = placement.indexOf('[');
  final close = placement.indexOf(']', open + 1);
  if (open < 0 || close < 0) {
    return (fen: fen, white: '', black: '');
  }
  final letters = placement.substring(open + 1, close).split('');
  fields[0] = placement.substring(0, open);
  return (
    fen: fields.join(' '),
    white: formatReserve(letters.where(_isUpper).join()),
    black: formatReserve(letters.where((l) => !_isUpper(l)).join()),
  );
}

sealed class FenCheck {
  const FenCheck();
}

/// A FEN of the right shape, with the fields it left out filled in.
final class FenShape extends FenCheck {
  const FenShape({
    required this.placement,
    required this.pocket,
    required this.rest,
  });

  /// The pieces, promoted ones still marked `~`.
  final String placement;

  /// A reserve given in brackets, beside the boxes.
  final String pocket;

  /// Turn, castling, en passant and the two counters.
  final String rest;
}

final class FenWrong extends FenCheck {
  const FenWrong(this.message);

  final String message;
}

/// [text] checked for shape, with White to move and castling wherever king
/// and rook are still at home when it does not say.
FenCheck checkFen(String text) {
  final fields = text.trim().split(RegExp(r'\s+'));
  if (fields.first.isEmpty) return const FenWrong('Enter a FEN.');
  var placement = fields.first;
  var pocket = '';
  final open = placement.indexOf('[');
  if (open >= 0) {
    final close = placement.indexOf(']', open);
    if (close < 0) {
      return const FenWrong('The reserve in brackets isn’t closed.');
    }
    pocket = placement.substring(open + 1, close);
    placement = placement.substring(0, open);
  }
  if (_placementProblem(placement) case final problem?) {
    return FenWrong(problem);
  }
  final squares = _squaresOf(placement);
  for (final (king, side) in [('K', 'White'), ('k', 'Black')]) {
    final kings = squares.values.where((piece) => piece == king).length;
    if (kings != 1) {
      final verb = kings == 1 ? 'is' : 'are';
      return FenWrong('$side needs exactly one king; there $verb $kings.');
    }
  }
  final turn = fields.length > 1 ? fields[1] : 'w';
  if (turn != 'w' && turn != 'b') {
    return const FenWrong('The side to move is w or b.');
  }
  final castling = fields.length > 2 ? fields[2] : _homeCastling(squares);
  if (!RegExp(r'^(-|K?Q?k?q?)$').hasMatch(castling)) {
    return FenWrong('“$castling” isn’t castling rights (like KQkq or -).');
  }
  String field(int i, String fallback) =>
      fields.length > i ? fields[i] : fallback;
  final rest = [turn, castling, field(3, '-'), field(4, '0'), field(5, '1')];
  return FenShape(placement: placement, pocket: pocket, rest: rest.join(' '));
}

/// Why [placement] cannot be read, or null when it can.
String? _placementProblem(String placement) {
  final ranks = placement.split('/');
  if (ranks.length != 8) {
    return 'A FEN has 8 ranks; this has ${ranks.length}.';
  }
  for (final (r, rank) in ranks.indexed) {
    var file = 0;
    for (final char in rank.split('')) {
      if (_emptyRun.hasMatch(char)) {
        file += int.parse(char);
      } else if (_pieceLetter.hasMatch(char)) {
        file += 1;
      } else if (char != '~') {
        return '“$char” isn’t a piece or a number of empty squares.';
      }
    }
    if (file != 8) return 'Rank ${8 - r} covers $file squares, not 8.';
  }
  return null;
}

/// Pieces by square name, from a placement [_placementProblem] passed.
Map<String, String> _squaresOf(String placement) {
  final squares = <String, String>{};
  for (final (r, rank) in placement.split('/').indexed) {
    var file = 0;
    for (final char in rank.split('')) {
      if (_emptyRun.hasMatch(char)) {
        file += int.parse(char);
      } else if (_pieceLetter.hasMatch(char)) {
        squares['${'abcdefgh'[file]}${8 - r}'] = char;
        file += 1;
      }
    }
  }
  return squares;
}

final _emptyRun = RegExp('[1-8]');
final _pieceLetter = RegExp('[pnbrqk]', caseSensitive: false);

String _homeCastling(Map<String, String> squares) {
  final rights = [
    if (squares['e1'] == 'K' && squares['h1'] == 'R') 'K',
    if (squares['e1'] == 'K' && squares['a1'] == 'R') 'Q',
    if (squares['e8'] == 'k' && squares['h8'] == 'r') 'k',
    if (squares['e8'] == 'k' && squares['a8'] == 'r') 'q',
  ].join();
  return rights.isEmpty ? '-' : rights;
}

sealed class ReserveRead {
  const ReserveRead();
}

/// Upper-case reserve letters: `NNQP`.
final class ReservePieces extends ReserveRead {
  const ReservePieces(this.letters);

  final String letters;
}

final class ReserveWrong extends ReserveRead {
  const ReserveWrong(this.message);

  final String message;
}

/// The reserve order a person writes: the strongest piece first.
const _reserveOrder = 'QRBNP';

/// `2N Q P` from reserve letters in either case.
String formatReserve(String pocket) {
  final upper = pocket.toUpperCase();
  return [
    for (final piece in _reserveOrder.split(''))
      if (piece.allMatches(upper).length case final n when n > 0)
        n > 1 ? '$n$piece' : piece,
  ].join(' ');
}

/// Reserve letters from `2N Q P`, `NNQP` or `n, q`; or why not.
ReserveRead parseReserve(String text) {
  final letters = StringBuffer();
  final unread = text.replaceAllMapped(
    RegExp(r'(\d*)\s*([a-z])', caseSensitive: false),
    (match) {
      letters.write(
        match[2]!.toUpperCase() *
            int.parse(match[1]!.isEmpty ? '1' : match[1]!),
      );
      return '';
    },
  );
  final pieces = letters.toString();
  if (pieces.contains('K')) {
    return const ReserveWrong('A king can’t be in reserve (N is the knight).');
  }
  final stranger = pieces.split('').where((l) => !_reserveOrder.contains(l));
  if (stranger.isNotEmpty) {
    return ReserveWrong(
      '“${stranger.first}” isn’t a piece: use P, N, B, R or Q.',
    );
  }
  if (unread.replaceAll(RegExp(r'[\s,]'), '').isNotEmpty) {
    return ReserveWrong('Can’t read “${unread.trim()}” in a reserve.');
  }
  if (pieces.length > 30) {
    return const ReserveWrong('That is more pieces than a reserve can hold.');
  }
  return ReservePieces(pieces);
}

/// Every piece of a bughouse set, per colour.
const _fullSet = {'P': 16, 'N': 4, 'B': 4, 'R': 4, 'Q': 2, 'K': 2};

/// The pieces the boxes leave unplaced and any extras, in words:
/// `Pieces outstanding: White: 1P · Black: 2N`, or empty while a FEN cannot
/// be read yet. A promoted piece (`Q~`) counts as the pawn it was.
String outstanding(BoardBoxes one, BoardBoxes two) {
  final have = <String, int>{};
  void add(String letter) => have[letter] = (have[letter] ?? 0) + 1;
  for (final boxes in [one, two]) {
    final shape = checkFen(boxes.fen);
    if (shape is! FenShape) return '';
    final cells = shape.placement;
    for (var i = 0; i < cells.length; i++) {
      final c = cells[i];
      if (!_pieceLetter.hasMatch(c)) continue;
      final promoted = i + 1 < cells.length && cells[i + 1] == '~';
      add(promoted ? (_isUpper(c) ? 'P' : 'p') : c);
    }
    shape.pocket.split('').where((l) => l.isNotEmpty).forEach(add);
    for (final (text, upper) in [(boxes.white, true), (boxes.black, false)]) {
      if (parseReserve(text) case ReservePieces(:final letters)) {
        (upper ? letters : letters.toLowerCase()).split('').forEach(add);
      }
    }
  }
  String side(bool upper, int sign) => [
    for (final MapEntry(key: piece, value: full) in _fullSet.entries)
      if (sign * (full - (have[upper ? piece : piece.toLowerCase()] ?? 0))
          case final n when n > 0)
        '$n$piece',
  ].join(' ');
  String listed(String label, int sign) {
    final sides = [
      if (side(true, sign) case final w when w.isNotEmpty) 'White: $w',
      if (side(false, sign) case final b when b.isNotEmpty) 'Black: $b',
    ];
    return sides.isEmpty ? '' : '$label ${sides.join(' · ')}';
  }

  final parts = [
    listed('Pieces outstanding:', 1),
    listed('Too many:', -1),
  ].where((p) => p.isNotEmpty);
  return parts.isEmpty ? 'Pieces outstanding: none' : parts.join('   ');
}

bool _isUpper(String letter) => letter == letter.toUpperCase();
