/// The FICS bughouse archive as an opening book, read the way the master-games
/// explorer reads its own.
///
/// The book is a build artefact of `tools/bughouse_db/`: 21 years of BPGN from
/// bughouse-db.org replayed into a `(position, move)` table. Everything here
/// is read-only — rebuild the book, never patch it — and the schema is the one
/// in `tools/bughouse_db/schema.py`, which was written against
/// `services/master_games/master_games_db.dart` for exactly this reason.
///
/// Two things about it are worth knowing before reading a row:
///
///   * **The key is a position, not a move order.** Two boards interleave, so
///     a line is dead as a key by ply 6; hashing the pair of positions merges
///     every interleaving that arrives at the same place and buys about five
///     plies. [bughousePositionKey] mirrors `tools/bughouse_db/poskey.py`
///     byte for byte — see [_canonicalBoardFen] for the one place where
///     dartchess and python-chess disagree about a FEN.
///   * **Results are team-relative.** `teamA` is the pair holding White on
///     board A, and `unknown` is real: about one FICS game in nine ends `*`,
///     aborted or disconnected, and pretending those were draws would flatter
///     every line in the book.
///
/// The book lives outside the app, under `~/.local/share/chess-prep/`, because
/// it is 177 MB built from a 2 GB corpus that must never reach an installer.
/// A machine without one is the normal case, not an error: [BughouseBook.open]
/// returns null and the panel says so.
library;

import 'dart:io' as io;

import 'package:dartchess/dartchess.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../../services/storage/app_paths.dart';
import '../models/bughouse_state.dart';

const int _fnvOffset = -3750763034362895579; // 0xcbf29ce484222325, signed
const int _fnvPrime = 1099511628211;

/// Pocket letters in the order python-chess writes them, which is
/// `reversed(PIECE_TYPES)`.
///
/// dartchess writes its own `Role.values` order (pawn, knight, bishop, rook,
/// king, queen) instead, so the same reserve comes out `[PN]` here and `[NP]`
/// there. One byte of disagreement in the hashed string is a total miss in the
/// book, and it only shows up once a pocket holds two different pieces — which
/// is to say, not in any test that stops at move four.
const String _pocketOrder = 'KQRBNP';

/// [fen] truncated to the four fields that describe a *position*, with its
/// pocket in the canonical order.
///
/// The half-move and full-move counters are path, not position: two lines that
/// reach the same place by different routes must hash the same.
String _canonicalBoardFen(String fen) {
  final fields = fen.split(' ');
  final placement = fields.isEmpty ? '' : fields.first;
  final open = placement.indexOf('[');
  final kept = fields.take(4).toList();
  if (open >= 0 && placement.endsWith(']')) {
    final pocket = placement.substring(open + 1, placement.length - 1);
    kept[0] = '${placement.substring(0, open)}[${_orderPocket(pocket)}]';
  }
  return kept.join(' ');
}

String _orderPocket(String pocket) {
  if (pocket.length < 2) return pocket;
  final white = <String>[];
  final black = <String>[];
  for (final letter in pocket.split('')) {
    (letter == letter.toUpperCase() ? white : black).add(letter);
  }
  int rank(String a, String b) => _pocketOrder
      .indexOf(a.toUpperCase())
      .compareTo(_pocketOrder.indexOf(b.toUpperCase()));
  white.sort(rank);
  black.sort(rank);
  return white.join() + black.join();
}

/// The canonical dual FEN [bughousePositionKey] hashes.
String bughouseKeyFen(String fenA, String fenB) =>
    '${_canonicalBoardFen(fenA)} | ${_canonicalBoardFen(fenB)}';

/// Signed 64-bit FNV-1a of the canonical dual FEN — the book's `pos` column.
///
/// FNV rather than Zobrist so Dart and Python agree from the FEN alone, with
/// no shared table to keep in step. Dart VM ints are 64-bit and wrap on
/// multiply, which is exactly FNV's arithmetic.
int bughousePositionKey(String fenA, String fenB) {
  final s = bughouseKeyFen(fenA, fenB);
  var h = _fnvOffset;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h *= _fnvPrime;
  }
  return h;
}

/// One continuation played from a position, aggregated over the whole archive.
class BughouseBookMove {
  const BughouseBookMove({
    required this.board,
    required this.mover,
    required this.san,
    required this.games,
    required this.teamA,
    required this.teamB,
    required this.draws,
    required this.unknown,
    required this.averageElo,
    required this.maxElo,
    required this.lastYear,
    required this.topGameNo,
  });

  /// Which board the move was played on.
  final BughouseBoard board;

  /// Whose move it was. Redundant with the position — the book stores it
  /// because BPGN does, and it costs nothing to keep the mover attached to the
  /// move rather than re-derived from two turns.
  final Side mover;

  final String san;
  final int games;

  /// Games won by the pair holding White on board A.
  final int teamA;

  /// Games won by the other pair.
  final int teamB;

  final int draws;

  /// Games that ended `*` — aborted, adjourned, or someone's connection went.
  final int unknown;

  /// Mean of the four players' ratings, or null when none were rated.
  final int? averageElo;

  final int maxElo;
  final int lastYear;

  /// `BughouseDBGameNo` of the strongest game to play this move.
  final int topGameNo;

  /// Games that reached a result, the denominator a win rate can honestly use.
  int get decided => games - unknown;

  /// Score in [0, 1] for the pair holding White on board A, over [decided].
  double get teamAScore => decided == 0 ? 0.5 : (teamA + draws / 2) / decided;
}

/// Everything the book knows about one two-board position.
class BughouseBookPosition {
  const BughouseBookPosition({
    required this.key,
    required this.games,
    required this.teamA,
    required this.teamB,
    required this.draws,
    required this.unknown,
    required this.moves,
  });

  static const empty = BughouseBookPosition(
    key: 0,
    games: 0,
    teamA: 0,
    teamB: 0,
    draws: 0,
    unknown: 0,
    moves: [],
  );

  final int key;

  /// Games through this position, counted *before* the singleton pruning that
  /// shaped [moves]. A position can honestly say "1,240 games" while listing
  /// only the twelve continuations worth showing.
  final int games;

  final int teamA;
  final int teamB;
  final int draws;
  final int unknown;

  /// Continuations, most played first.
  final List<BughouseBookMove> moves;

  bool get isEmpty => moves.isEmpty;

  /// Games in [moves], which is [games] less the pruned singleton tail.
  int get listed => moves.fold(0, (sum, m) => sum + m.games);
}

/// What the book on this machine is, for the line that names it.
class BughouseBookStatus {
  const BughouseBookStatus({
    required this.path,
    required this.games,
    required this.maxPly,
    required this.minGames,
    required this.years,
  });

  final String path;

  /// Games indexed, across every year in [years].
  final int games;

  /// How deep the book goes, in half-moves across *both* boards.
  final int maxPly;

  /// Continuations played fewer times than this were pruned.
  final int minGames;

  /// The archive years indexed, ascending.
  final List<int> years;

  String get yearRange => years.isEmpty ? '' : '${years.first}–${years.last}';
}

/// A read-only handle on the book.
class BughouseBook {
  BughouseBook._(this._db, this.status);

  final Database _db;
  final BughouseBookStatus status;

  /// Opens the book if this machine has one, else null.
  ///
  /// Not having one is ordinary: the book is built by `python3 -m bughouse_db`
  /// from a 2 GB download, so most installs will never see it.
  static Future<BughouseBook?> open({String? path}) async {
    final candidates = path != null ? [path] : await searchPath();
    for (final candidate in candidates) {
      if (!io.File(candidate).existsSync()) continue;
      try {
        final db = sqlite3.open(candidate, mode: OpenMode.readOnly);
        return BughouseBook._(db, _readStatus(db, candidate));
      } on SqliteException {
        // A half-written book from an interrupted index is not worth a banner
        // in a pane about something else; the next candidate, or none.
        continue;
      }
    }
    return null;
  }

  /// Where a book may be, in the order it is looked for: an explicit override,
  /// the directory `tools/bughouse_db` writes to, then the app's own support
  /// directory, so a future build can ship or download one without moving the
  /// tooling.
  ///
  /// Never throws. The controller opens the book from its constructor, and an
  /// unhandled async error there would take down every widget test that builds
  /// the pane — including on a bare test binding, where the support directory
  /// is a platform channel that answers nothing.
  static Future<List<String>> searchPath() async {
    final env = io.Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? io.Directory.current.path;
    final override = env['BUGHOUSE_DB_HOME'];
    String? support;
    try {
      support = (await AppPaths.supportDirectory()).path;
    } on Object {
      support = null;
    }
    return [
      if (override != null && override.isNotEmpty) p.join(override, _fileName),
      p.join(home, '.local', 'share', 'chess-prep', 'bughouse-db', _fileName),
      if (support != null) p.join(support, _fileName),
    ];
  }

  static const _fileName = 'bughouse_book.db';

  static BughouseBookStatus _readStatus(Database db, String path) {
    final meta = <String, String>{
      for (final row in db.select('SELECT key, value FROM meta'))
        row['key'] as String: row['value'] as String,
    };
    return BughouseBookStatus(
      path: path,
      games: int.tryParse(meta['games'] ?? '') ?? 0,
      maxPly: int.tryParse(meta['max_ply'] ?? '') ?? 0,
      minGames: int.tryParse(meta['min_games'] ?? '') ?? 0,
      years: [
        for (final year in (meta['years'] ?? '').split(','))
          ?int.tryParse(year.trim()),
      ]..sort(),
    );
  }

  /// Every recorded continuation from a two-board position.
  ///
  /// Two indexed lookups on a `WITHOUT ROWID` primary key — sub-millisecond,
  /// which is why this runs on the UI isolate the way the master-games
  /// explorer does.
  BughouseBookPosition explore(String fenA, String fenB) {
    final key = bughousePositionKey(fenA, fenB);
    final node = _db.select(
      'SELECT games, team_a, team_b, draws, unknown FROM node WHERE pos = ?',
      [key],
    );
    final rows = _db.select(
      'SELECT move, games, team_a, team_b, draws, unknown, elo_sum, elo_n, '
      'max_elo, last_year, top_game FROM edge WHERE pos = ? '
      'ORDER BY games DESC',
      [key],
    );
    final moves = <BughouseBookMove>[];
    for (final row in rows) {
      final move = row['move'] as String;
      if (move.length < 3) continue;
      final letter = move[0];
      final eloN = row['elo_n'] as int;
      moves.add(
        BughouseBookMove(
          board: letter.toUpperCase() == 'A'
              ? BughouseBoard.a
              : BughouseBoard.b,
          // BPGN's own convention: the board letter is upper case when White
          // moved and lower case when Black did.
          mover: letter == letter.toUpperCase() ? Side.white : Side.black,
          san: move.substring(2),
          games: row['games'] as int,
          teamA: row['team_a'] as int,
          teamB: row['team_b'] as int,
          draws: row['draws'] as int,
          unknown: row['unknown'] as int,
          averageElo: eloN == 0 ? null : (row['elo_sum'] as int) ~/ eloN,
          maxElo: row['max_elo'] as int,
          lastYear: row['last_year'] as int,
          topGameNo: row['top_game'] as int,
        ),
      );
    }
    if (node.isEmpty && moves.isEmpty) return BughouseBookPosition.empty;
    final head = node.isEmpty ? null : node.first;
    return BughouseBookPosition(
      key: key,
      // `node` is aggregated before pruning, so it is the honest total; the
      // sum over `edge` is what survived it.
      games: head?['games'] as int? ?? moves.fold(0, (sum, m) => sum + m.games),
      teamA: head?['team_a'] as int? ?? 0,
      teamB: head?['team_b'] as int? ?? 0,
      draws: head?['draws'] as int? ?? 0,
      unknown: head?['unknown'] as int? ?? 0,
      moves: moves,
    );
  }

  void close() => _db.close();
}
