/// A bughouse table: two crazyhouse boards that feed each other.
///
/// Four people play. Board 1 has A (White) against C (Black); board 2 has
/// D (White) against B (Black). Partners hold opposite colours, so the
/// teams are A + B and C + D, and a team is also named by its colour on
/// board 1: A + B is "white" to the engine and to the books.
///
/// Crazyhouse gives the rules of each board — drops, and a promoted piece
/// going back as a pawn — and bughouse changes one of them: a captured
/// piece keeps its colour and crosses to the partner's reserve on the other
/// board, instead of joining the capturer's own. [TablePosition.play] lets
/// dartchess play the move, takes back the reserve credit it gave, and
/// hands the piece over.
library;

import 'package:dartchess/dartchess.dart';

enum BoardNumber {
  one('Board 1', '1'),
  two('Board 2', '2');

  const BoardNumber(this.label, this.digit);

  final String label;

  /// How the engine prefixes a move on this board, and how the books tag
  /// one: `1e2e4`, `A:e4` is board one.
  final String digit;

  BoardNumber get other => this == one ? two : one;
}

enum Team {
  ab('A + B'),
  cd('C + D');

  const Team(this.label);

  final String label;

  Team get other => this == ab ? cd : ab;

  /// The team's colour on board 1, which is how the engine's `Team` option
  /// and the books name it.
  Side get onBoardOne => this == ab ? Side.white : Side.black;

  /// The colour this team plays on [board].
  Side sideOn(BoardNumber board) =>
      board == BoardNumber.one ? onBoardOne : onBoardOne.opposite;
}

enum Seat {
  a('A'),
  b('B'),
  c('C'),
  d('D');

  const Seat(this.letter);

  final String letter;

  /// Who sits on [board] playing [side].
  static Seat of(BoardNumber board, Side side) => switch ((board, side)) {
    (BoardNumber.one, Side.white) => a,
    (BoardNumber.one, Side.black) => c,
    (BoardNumber.two, Side.white) => d,
    (BoardNumber.two, Side.black) => b,
  };

  Team get team => this == a || this == b ? Team.ab : Team.cd;
}

/// One legal move on one board: UCI as the engine and the books spell it
/// (castling `e1g1`, a drop `N@f3`, a pawn drop `P@e5`) and SAN as a
/// bughouse player writes it (`P@e5`, not dartchess's `@e5`).
typedef TableMove = ({BoardNumber board, String uci, String san});

/// Both boards at one moment. Immutable: a move returns a new table.
final class TablePosition {
  const TablePosition(this.one, this.two);

  static const initial = TablePosition(Crazyhouse.initial, Crazyhouse.initial);

  final Crazyhouse one;
  final Crazyhouse two;

  Crazyhouse board(BoardNumber board) => board == BoardNumber.one ? one : two;

  Side turn(BoardNumber board) => this.board(board).turn;

  /// Who is to move on [board].
  Seat mover(BoardNumber board) => Seat.of(board, turn(board));

  /// Whether [team] has a move to make on either board. Each board has its
  /// own turn, so a team can hold both moves, one, or none.
  bool hasMove(Team team) =>
      BoardNumber.values.any((board) => mover(board).team == team);

  /// The engine's form: two crazyhouse FENs joined by `|`.
  String get dualFen => '${one.fen}|${two.fen}';

  TablePosition withBoard(BoardNumber board, Crazyhouse position) =>
      board == BoardNumber.one
      ? TablePosition(position, two)
      : TablePosition(one, position);

  /// Every legal move on [board], promotions to each piece and every drop
  /// the reserve allows, in a fixed order: pieces from a1 upward, then drops
  /// pawn to queen.
  List<TableMove> legalMoves(BoardNumber board) {
    final position = this.board(board);
    return [
      for (final move in _moves(position))
        (board: board, uci: _uci(position, move), san: _san(position, move)),
    ];
  }

  /// [uci] played on [board], with any capture sent across; null when it is
  /// not a legal move there. Accepts castling either way, `e1g1` or `e1h1`.
  ({TablePosition after, TableMove move})? play(BoardNumber board, String uci) {
    final position = this.board(board);
    final parsed = _parse(position, uci);
    if (parsed == null || !position.isLegal(parsed)) return null;
    final move = (
      board: board,
      uci: _uci(position, parsed),
      san: _san(position, parsed),
    );
    return (after: _played(board, parsed), move: move);
  }

  TablePosition _played(BoardNumber board, Move move) {
    final before = this.board(board);
    final captured = _captured(before, move);
    final after = before.playUnchecked(move) as Crazyhouse;
    if (captured == null) return withBoard(board, after);
    // Crazyhouse credited the capturer's own reserve; bughouse gives the
    // piece, colour kept, to the partner on the other board.
    final kept = after.pockets!.decrement(
      captured.color.opposite,
      captured.role,
    );
    final partner = this.board(board.other);
    final given = partner.pockets!.increment(captured.color, captured.role);
    return withBoard(
      board,
      after.copyWith(pockets: kept) as Crazyhouse,
    ).withBoard(board.other, partner.copyWith(pockets: given) as Crazyhouse);
  }

  /// What [move] takes, as the piece that reaches a reserve: a promoted
  /// piece goes back as a pawn. Drops and castling take nothing; en passant
  /// takes the pawn beside the square moved to.
  static Piece? _captured(Crazyhouse position, Move move) {
    if (move is! NormalMove) return null;
    final target = position.board.pieceAt(move.to);
    if (target != null) {
      // Castling is king-takes-own-rook in dartchess: nothing is captured.
      if (target.color == position.turn) return null;
      return target.promoted ? target.copyWith(role: Role.pawn) : target;
    }
    final mover = position.board.pieceAt(move.from);
    if (mover?.role == Role.pawn && move.to == position.epSquare) {
      return Piece(color: position.turn.opposite, role: Role.pawn);
    }
    return null;
  }

  /// The FICS and Hivemind books' key for this table: 64-bit FNV-1a over
  /// [keyText], the sum `tools/bughouse_db/poskey.py` takes, so a position
  /// the Python tools stored is found by any route that reaches it.
  int get bookKey {
    final text = keyText;
    var hash = _fnvOffset;
    for (var i = 0; i < text.length; i++) {
      hash ^= text.codeUnitAt(i);
      hash *= _fnvPrime;
    }
    return hash;
  }

  /// Each board's FEN cut to the four fields that are the position (the
  /// move counters are the road there), joined by ` | `, with each reserve
  /// in python-chess's letter order. dartchess writes a reserve pawn first
  /// and python-chess writes it last, and one byte of difference is a book
  /// that never answers: `[PPpq]` here is `[PPqp]` there.
  String get keyText => '${_keyFen(one)} | ${_keyFen(two)}';
}

const _fnvOffset = -3750763034362895579; // 0xcbf29ce484222325 as signed
const _fnvPrime = 1099511628211;

/// python-chess's reserve order.
const _pocketOrder = 'KQRBNP';

String _keyFen(Crazyhouse position) {
  final fields = position.fen.split(' ').take(4).toList();
  final placement = fields.first;
  final open = placement.indexOf('[');
  if (open >= 0) {
    final pocket = placement.substring(open + 1, placement.length - 1);
    int rank(String letter) => _pocketOrder.indexOf(letter.toUpperCase());
    final letters = pocket.split('');
    final white = letters.where((l) => l == l.toUpperCase()).toList()
      ..sort((x, y) => rank(x).compareTo(rank(y)));
    final black = letters.where((l) => l != l.toUpperCase()).toList()
      ..sort((x, y) => rank(x).compareTo(rank(y)));
    fields[0] =
        '${placement.substring(0, open)}[${white.join()}${black.join()}]';
  }
  return fields.join(' ');
}

/// Pieces a reserve can hold, in the order a tray shows them.
const reserveRoles = [
  Role.pawn,
  Role.knight,
  Role.bishop,
  Role.rook,
  Role.queen,
];

Iterable<Move> _moves(Crazyhouse position) sync* {
  for (final MapEntry(key: from, value: targets)
      in position.legalMoves.entries) {
    final pawn = position.board.pieceAt(from)?.role == Role.pawn;
    for (final to in targets.squares) {
      if (pawn && (to.rank == Rank.first || to.rank == Rank.eighth)) {
        for (final role in const [
          Role.queen,
          Role.rook,
          Role.bishop,
          Role.knight,
        ]) {
          yield NormalMove(from: from, to: to, promotion: role);
        }
      } else {
        yield NormalMove(from: from, to: to);
      }
    }
  }
  for (final role in reserveRoles) {
    if (position.pockets!.of(position.turn, role) == 0) continue;
    for (final to in position.legalDrops.squares) {
      final drop = DropMove(to: to, role: role);
      if (position.isLegal(drop)) yield drop;
    }
  }
}

/// [uci] read on [position]: a bare promotion to the last rank is a queen,
/// which is what a UCI engine means by it.
Move? _parse(Crazyhouse position, String uci) {
  final move = Move.parse(uci);
  if (move is NormalMove && move.promotion == null) {
    final pawn = position.board.pieceAt(move.from)?.role == Role.pawn;
    final last = move.to.rank == Rank.first || move.to.rank == Rank.eighth;
    if (pawn && last) return move.withPromotion(Role.queen);
  }
  return move;
}

/// The move as the engine and the books write it: a castle as the king's
/// two-square step, not dartchess's king-takes-rook.
String _uci(Crazyhouse position, Move move) {
  if (move case NormalMove(:final from, :final to)) {
    final castles =
        position.board.kings.has(from) &&
        position.board.bySide(position.turn).has(to);
    if (castles) {
      final file = to.file > from.file ? File.g : File.c;
      return from.name + Square.fromCoords(file, from.rank).name;
    }
  }
  return move.uci;
}

/// SAN with the pawn named on a drop, `P@e5`.
String _san(Crazyhouse position, Move move) {
  final san = position.makeSan(move).$2;
  return san.startsWith('@') ? 'P$san' : san;
}
