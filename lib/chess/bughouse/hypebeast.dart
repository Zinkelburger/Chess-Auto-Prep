/// How HypeBeast, the bughouse engine, is read back: the `info` lines of a
/// search, its coordinator's `hb_coord` and `hb_summary` reports and its
/// joint `bestmove`, and how its scores are shown.
///
/// HypeBeast is Fairy-Stockfish playing one seat of a bughouse table: it is
/// told both boards and the seat (a board and the colour to move there) and
/// searches that board. Its lines are that board's moves alone, scored in
/// centipawns from the side to move there. The Bughouse mode shows every
/// score in pawns from A + B's side — White on board 1, Black on board 2 —
/// so a score read for a seat of C + D changes sign ([TableScore.forSeat]).
///
/// With `Coordination` on, the engine searches the partner board first
/// (silently), then streams this board's main line, then compares the
/// moves that matter across the boards and reports them in `hb_coord`
/// before `bestmove`; its decision may differ from the main line's move.
/// [seatRows] turns what was read into the rows the mode shows, as the
/// website's driver does.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart' show ListEquality;

import 'table.dart';

/// One search line of the board searched: its MultiPV rank, how deep, its
/// score from the side to move there (centipawns or plies to mate, + when
/// the side to move is better), how many nodes the search had, and its
/// moves as plain UCI moves of that board (`e2e4`, `N@f3`, `e7e8q`).
final class SeatLine {
  const SeatLine({
    required this.multipv,
    required this.depth,
    this.seldepth = 0,
    this.nodes = 0,
    this.cp,
    this.mate,
    this.bound = false,
    this.pv = const [],
  });

  final int multipv;
  final int depth;
  final int seldepth;
  final int nodes;
  final int? cp;
  final int? mate;

  /// Whether the score is only a bound (`lowerbound`, `upperbound`).
  final bool bound;
  final List<String> pv;

  bool get scored => cp != null || mate != null;
}

/// One `info` line read, or null when it says nothing of the search: an
/// `info string`, or a line without a depth. A line with no `pv` is the
/// engine's closing verdict on its main search (`info depth 17 score cp
/// 263 nodes 1126201 time 1960`), printed just before its summary.
SeatLine? parseSeatInfo(String line) {
  if (!line.startsWith('info ') || line.startsWith('info string')) return null;
  final tokens = line.trim().split(RegExp(r'\s+'));
  int? depth;
  var seldepth = 0, multipv = 1, nodes = 0;
  int? cp, mate;
  var bound = false;
  var pv = const <String>[];
  for (var i = 1; i < tokens.length; i++) {
    int? next() => i + 1 < tokens.length ? int.tryParse(tokens[++i]) : null;
    switch (tokens[i]) {
      case 'depth':
        depth = next();
      case 'seldepth':
        seldepth = next() ?? 0;
      case 'multipv':
        multipv = next() ?? 1;
      case 'nodes':
        nodes = next() ?? 0;
      case 'score' when i + 2 < tokens.length:
        final kind = tokens[++i];
        final value = int.tryParse(tokens[++i]);
        if (kind == 'cp') cp = value;
        if (kind == 'mate') mate = value;
        if (i + 1 < tokens.length &&
            (tokens[i + 1] == 'lowerbound' || tokens[i + 1] == 'upperbound')) {
          bound = true;
          i++;
        }
      case 'pv':
        pv = List.unmodifiable(tokens.sublist(i + 1));
        i = tokens.length;
    }
  }
  if (depth == null) return null;
  return SeatLine(
    multipv: multipv,
    depth: depth,
    seldepth: seldepth,
    nodes: nodes,
    cp: cp,
    mate: mate,
    bound: bound,
    pv: pv,
  );
}

/// A move the coordinator compared, with its scores from the searching
/// side in centipawns: [l] on its board alone, [s] with what it sends the
/// partner. Either is null when the coordinator did not score it.
final class Candidate {
  const Candidate(this.move, {this.l, this.s});

  final String move;
  final int? l;
  final int? s;

  /// The score shown for it: [s], else [l].
  int? get score => s ?? l;
}

/// The coordinator's report: why it chose as it did and the moves it
/// compared, in the order it printed them.
final class Coordination {
  const Coordination(this.reason, this.candidates);

  final String reason;
  final List<Candidate> candidates;
}

/// The JSON of an `info string hb_coord` line, or null when it does not
/// read. A report without candidates (a mate the team wins outright) has
/// an empty list.
Coordination? parseCoordination(String json) {
  final Object? raw;
  try {
    raw = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (raw is! Map<String, Object?>) return null;
  int? score(Object? value) => value is num ? value.round() : null;
  return Coordination(
    raw['reason'] is String ? raw['reason']! as String : '',
    List.unmodifiable([
      if (raw['candidates'] case final List<Object?> candidates)
        for (final candidate in candidates)
          if (candidate case {'move': final String move})
            Candidate(move, l: score(candidate['L']), s: score(candidate['S'])),
    ]),
  );
}

/// The `key=value` pairs of an `info string hb_summary` line.
Map<String, String> parseSummary(String text) => {
  for (final pair in text.trim().split(RegExp(r'\s+')))
    if (pair.indexOf('=') case final at when at > 0)
      pair.substring(0, at): pair.substring(at + 1),
};

/// What a seat chose on its board: a move, or to sit ([move] null).
final class SeatDecision {
  const SeatDecision(this.move);

  final String? move;

  bool get sits => move == null;

  @override
  bool operator ==(Object other) => other is SeatDecision && other.move == move;

  @override
  int get hashCode => move.hashCode;

  @override
  String toString() => move ?? 'pass';
}

/// `bestmove (g8f6,pass)` → the seat's half for [board]: a move, or a sit
/// for `pass`. Null for `(none)` (no legal move) or a line that does not
/// read. A plain `bestmove e2e4` is read as that move.
SeatDecision? parseBestMove(String line, BoardNumber board) {
  final fields = line.trim().split(RegExp(r'\s+'));
  if (fields.length < 2 || fields.first != 'bestmove') return null;
  final token = fields[1];
  final String half;
  if (token.startsWith('(') && token.endsWith(')') && token.contains(',')) {
    final halves = token.substring(1, token.length - 1).split(',');
    if (halves.length != 2) return null;
    half = halves[board == BoardNumber.one ? 0 : 1].trim();
  } else {
    half = token;
  }
  return switch (half) {
    'pass' => const SeatDecision(null),
    '' || 'none' || '(none)' || '0000' => null,
    _ => SeatDecision(half),
  };
}

/// What a search has shown so far: its lines by MultiPV rank, the
/// coordinator's report once printed, and the size of the search.
final class SeatReport {
  const SeatReport({this.lines = const [], this.coordination, this.nodes = 0});

  final List<SeatLine> lines;
  final Coordination? coordination;
  final int nodes;

  SeatLine? get main => lines.where((line) => line.multipv == 1).firstOrNull;
}

/// Reads one search's output line by line into a [SeatReport].
///
/// - A MultiPV 1 line with only a bound is noise and is passed over; a
///   later rank may only ever have bounds and is kept.
/// - Each new MultiPV 1 line drops the other ranks more than one iteration
///   older, as the website's driver does, so rows from different depths do
///   not mix. The last block of a stopped search may still be out of order
///   (lines its unfinished iteration did not reach keep the previous
///   depth's score) or cut to a move or two; [seatRows] sorts by score.
/// - Builds before HypeBeast v1.1.2 (v1.1.1 among them) predate its MultiPV
///   support: with `Coordination` off they print lines 2…N without
///   searching them, each iteration repeating the rank's last line — the
///   same moves and the same `seldepth` (often 1) — at `score cp 0`, one
///   depth deeper or again at the same depth when the block is printed
///   twice. Such a line is dropped, with what the rank showed before, while
///   the main line is properly deep (seldepth above 4). v1.1.2 and later
///   search every line and never repeat one unchanged at 0.
final class SeatReader {
  final _lines = <int, SeatLine>{};

  /// Each later rank's line as last printed, shown or not.
  final _printed = <int, SeatLine>{};
  Coordination? _coordination;
  int _nodes = 0;
  int? _totalNodes;

  SeatReport get report => SeatReport(
    lines: List.unmodifiable(
      _lines.values.toList()..sort((a, b) => a.multipv.compareTo(b.multipv)),
    ),
    coordination: _coordination,
    nodes: _totalNodes ?? _nodes,
  );

  /// Reads [line]; true when the report changed.
  bool read(String line) {
    if (line.startsWith('info string ')) return _string(line.substring(12));
    final info = parseSeatInfo(line);
    if (info == null) return false;
    final grew = info.nodes > _nodes;
    if (grew) _nodes = info.nodes;
    // The closing `info depth … nodes …` without a pv only counts nodes.
    if (info.pv.isEmpty) return grew;
    if (info.bound && info.multipv == 1) return grew;
    if (info.multipv > 1) {
      final before = _printed[info.multipv];
      _printed[info.multipv] = info;
      if (_unsearched(info, before)) {
        return _lines.remove(info.multipv) != null || grew;
      }
    }
    if (info.multipv == 1) {
      _lines.removeWhere((rank, l) => rank > 1 && l.depth < info.depth - 1);
    }
    _lines[info.multipv] = info;
    return true;
  }

  bool _unsearched(SeatLine line, SeatLine? before) =>
      line.cp == 0 &&
      line.mate == null &&
      before != null &&
      line.depth >= before.depth &&
      line.seldepth == before.seldepth &&
      const ListEquality<String>().equals(line.pv, before.pv) &&
      (_lines[1]?.seldepth ?? 0) > 4;

  bool _string(String text) {
    final space = text.indexOf(' ');
    final kind = space < 0 ? text : text.substring(0, space);
    final body = space < 0 ? '' : text.substring(space + 1);
    switch (kind) {
      case 'hb_coord':
        final coordination = parseCoordination(body);
        if (coordination == null) return false;
        _coordination = coordination;
        return true;
      case 'hb_summary':
        final total = int.tryParse(parseSummary(body)['total_nodes'] ?? '');
        if (total == null || total == _totalNodes) return false;
        _totalNodes = total;
        return true;
    }
    return false;
  }
}

/// One row the mode shows for a board: the move ([move] null for a sit),
/// its score from the side to move (none when the engine did not score
/// it), and the board's moves from it on.
typedef SeatRow = ({String? move, int? cp, int? mate, List<String> pv});

/// The rows for a seat's search, at most [count].
///
/// Searched alone ([coordinated] false): the lines best first by score for
/// the side to move (a mate for it first, the quicker the better; one
/// against it last), each with its whole line. With the coordinator: while it searches, the main
/// line; once [decision] is known, the decision first (a sit as a row of
/// its own, with no score), then the other moves the coordinator compared,
/// best first by `S`, else `L`, then those it did not score. A move that is
/// the main line's first is shown as the main line; any other is a row of
/// that one move with the coordinator's score.
List<SeatRow> seatRows(
  SeatReport report, {
  required bool coordinated,
  SeatDecision? decision,
  required int count,
}) {
  SeatRow rowOf(SeatLine line) =>
      (move: line.pv.first, cp: line.cp, mate: line.mate, pv: line.pv);
  if (!coordinated) {
    final lines = report.lines.where((line) => line.pv.isNotEmpty).toList()
      ..sort((a, b) {
        final better = _strength(b).compareTo(_strength(a));
        return better != 0 ? better : a.multipv.compareTo(b.multipv);
      });
    return [for (final line in lines.take(count)) rowOf(line)];
  }
  final main = report.main;
  if (decision == null) return [if (main != null) rowOf(main)];
  final candidates = report.coordination?.candidates ?? const <Candidate>[];
  SeatRow lineOf(String move, int? score) => main?.pv.first == move
      ? rowOf(main!)
      : (move: move, cp: score, mate: null, pv: [move]);
  final scored = candidates.where((c) => c.score != null).toList()
    ..sort((a, b) => b.score!.compareTo(a.score!));
  final rows = <SeatRow>[
    switch (decision.move) {
      null => (move: null, cp: null, mate: null, pv: const []),
      final move => lineOf(
        move,
        candidates.where((c) => c.move == move).firstOrNull?.score,
      ),
    },
  ];
  for (final candidate in [
    ...scored,
    ...candidates.where((c) => c.score == null),
  ]) {
    if (rows.length >= count) break;
    if (rows.any((row) => row.move == candidate.move)) continue;
    rows.add(lineOf(candidate.move, candidate.score));
  }
  return rows.take(count).toList();
}

/// How good [line] is for the side to move, for sorting: any mate for it
/// beats any score, the quicker the better; any mate against it is worse
/// than any score, the slower the better; no score is last.
double _strength(SeatLine line) => switch ((line.cp, line.mate)) {
  (_, final int mate) => mate > 0 ? 1e6 - mate : -1e6 - mate,
  (final int cp, _) => cp.toDouble(),
  _ => double.negativeInfinity,
};

/// lila's winning chances of a centipawn score, −1 to 1.
double winningChances(int cp) => 2 / (1 + math.exp(-0.00368208 * cp)) - 1;

double? _chances(int? cp, int? mate) => switch ((cp, mate)) {
  (_, final int mate) => mate > 0 ? 1 : -1,
  (final int cp, _) => winningChances(cp),
  _ => null,
};

/// How far each of [rows] falls behind the best for the side to move, 0 to
/// 1: half the difference in lila's winning chances, as lila measures how
/// much thinner to draw an engine move's arrow than its best one; a mate
/// counts as the whole chance. The first row is the best (0); a row with
/// no score is 1, beyond any arrow. When the first row has no score the
/// others are measured from the best scored one.
List<double> rowShifts(List<SeatRow> rows) {
  final chances = [for (final row in rows) _chances(row.cp, row.mate)];
  final best =
      chances.firstOrNull ??
      chances.nonNulls.fold<double?>(
        null,
        (best, c) => best == null || c > best ? c : best,
      );
  return [
    for (final (i, chance) in chances.indexed)
      i == 0
          ? 0
          : chance == null || best == null
          ? 1
          : ((best - chance) / 2).clamp(0.0, 1.0),
  ];
}

/// A score in pawns from A + B's side — White on board 1, Black on board 2
/// — or plies to mate, + when A + B mate; empty when there is none.
final class TableScore {
  const TableScore({this.cp, this.mate});

  /// A score read from the side to move on [board], whose seat is of
  /// [team]: the sign changes for C + D.
  factory TableScore.forSeat({int? cp, int? mate, required Team team}) {
    final sign = team == Team.ab ? 1 : -1;
    return TableScore(
      cp: cp == null ? null : sign * cp,
      mate: mate == null ? null : sign * mate,
    );
  }

  /// The two boards' scores together: the team's chances follow the plain
  /// sum of both boards' scores, with forced mates apart, so a mate on
  /// either board is the score (of two, the quicker); otherwise the
  /// centipawns add. Empty when none of [scores] holds anything.
  factory TableScore.sum(Iterable<TableScore> scores) {
    final mates = [for (final score in scores) ?score.mate]
      ..sort((a, b) => a.abs().compareTo(b.abs()));
    if (mates.isNotEmpty) return TableScore(mate: mates.first);
    final cps = [for (final score in scores) ?score.cp];
    if (cps.isEmpty) return const TableScore();
    return TableScore(cp: cps.fold<int>(0, (sum, cp) => sum + cp));
  }

  final int? cp;
  final int? mate;

  bool get isEmpty => cp == null && mate == null;

  /// `+0.25`, `-1.40`, `#3`, `#-2`, or `—` when there is nothing.
  String get text => switch ((cp, mate)) {
    (_, final int mate) => mate >= 0 ? '#$mate' : '#-${-mate}',
    (final int cp, _) => _pawns(cp),
    _ => '—',
  };

  @override
  bool operator ==(Object other) =>
      other is TableScore && other.cp == cp && other.mate == mate;

  @override
  int get hashCode => Object.hash(cp, mate);

  @override
  String toString() => text;
}

String _pawns(int cp) {
  if (cp == 0) return '0.00';
  final text = (cp.abs() / 100).toStringAsFixed(2);
  return cp > 0 ? '+$text' : '-$text';
}

/// The engine's `Seat` and `Team` options for searching [board] of
/// [position] for its side to move: `Ablack`, and the team by its colour
/// on board 1 (`white` is White on board 1 and Black on board 2).
({String seat, String team}) seatOptions(
  TablePosition position,
  BoardNumber board,
) {
  final mover = position.mover(board);
  final turn = position.turn(board).name;
  return (
    seat: '${board == BoardNumber.one ? 'A' : 'B'}$turn',
    team: mover.team == Team.ab ? 'white' : 'black',
  );
}
