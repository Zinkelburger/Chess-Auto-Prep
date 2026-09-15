/// Parse cdbdirect_get response strings (matches C cdbdirect_parse_response).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'chessdb_score.dart';
import 'db_move_list.dart';

/// Depth reported for every dump answer: the dump carries no per-move depth,
/// so the C reader this ports treats each as a nominal 20-ply search.
const int _kDumpDepth = 20;

/// One scored move of a piped response, before ChessDB's score encoding is
/// decoded. [rank] and [note] exist only in the verbose format.
typedef _Segment = ({String uci, int rawScore, int? rank, String? note});

/// Every move in a cdbdirect response, best first.
///
/// Two wire formats exist and both appear in real dumps: the verbose
/// `move:e2e4,score:30,rank:0,note:!,winrate:0.515|…` records, and the
/// compact `e2e4:30|d2d4:25` pairs.  A bare `eval:42` carries no moves and
/// yields an empty list — the position is scored but the dump has no move
/// breakdown for it.
List<DbMove> parseCdbDirectMoveList(String? response) {
  if (!_carriesMoves(response)) return const [];
  return DbMoveList.sorted([
    for (final segment in _segments(response!)) _decodeSegment(segment),
  ]);
}

/// The dump's answer for a position: its raw ChessDB score (see
/// [mapChessDbRawScoreStm]), a nominal depth and the best move when one is
/// named. Null on a miss or an unparsable response.
///
/// The best move is the lowest-ranked verbose segment, or the first compact
/// one; an `eval:N` answer scores the position without naming a move.
({int score, int depth, String? bestMove})? parseCdbDirectResponse(
  String? response,
) {
  if (response == null || _isMissResponse(response)) return null;

  if (_isBareEval(response)) {
    final score = int.tryParse(response.substring(_evalPrefix.length));
    if (score == null) return null;
    return (score: score, depth: _kDumpDepth, bestMove: null);
  }

  _Segment? best;
  for (final segment in _segments(response)) {
    if (best == null || _rankOf(segment) < _rankOf(best)) best = segment;
  }
  if (best == null) return null;
  return (score: best.rawScore, depth: _kDumpDepth, bestMove: best.uci);
}

const String _evalPrefix = 'eval:';
const int _unranked = 9999;

int _rankOf(_Segment segment) => segment.rank ?? _unranked;

bool _isMissResponse(String response) {
  if (response.isEmpty) return true;
  final lower = response.toLowerCase();
  return lower == 'unknown' ||
      lower.startsWith('error') ||
      lower.startsWith('invalid');
}

/// `eval:42` — a score for the position with no move breakdown.
bool _isBareEval(String response) =>
    response.startsWith(_evalPrefix) && !response.contains('|');

bool _carriesMoves(String? response) =>
    response != null && !_isMissResponse(response) && !_isBareEval(response);

/// The scored moves of a piped response, in wire order.
///
/// Bookkeeping segments (`ply:12`) share the compact `key:value` shape, so a
/// compact segment counts only when its key looks like a UCI move.
Iterable<_Segment> _segments(String response) sync* {
  for (final raw in response.split('|')) {
    final segment = raw.trim();
    if (segment.isEmpty) continue;
    final parsed = segment.contains('move:') || segment.contains('score:')
        ? _parseVerbose(segment)
        : _parseCompact(segment);
    if (parsed != null) yield parsed;
  }
}

/// `move:e2e4,score:30,rank:0,note:!,winrate:0.515`.
_Segment? _parseVerbose(String segment) {
  String? uci;
  int? score;
  int? rank;
  String? note;
  for (final field in segment.split(',')) {
    final colon = field.indexOf(':');
    if (colon < 0) continue;
    final value = field.substring(colon + 1);
    switch (field.substring(0, colon)) {
      case 'move':
        uci = value;
      case 'score':
        score = int.tryParse(value);
      case 'rank':
        rank = int.tryParse(value);
      case 'note':
        final trimmed = value.trim();
        if (trimmed.isNotEmpty) note = trimmed;
    }
  }
  if (uci == null || uci.isEmpty || score == null) return null;
  return (uci: uci, rawScore: score, rank: rank, note: note);
}

/// `e2e4:30`.
_Segment? _parseCompact(String segment) {
  final colon = segment.indexOf(':');
  if (colon <= 0) return null;
  final uci = segment.substring(0, colon);
  if (!_looksLikeUci(uci)) return null;
  final score = int.tryParse(segment.substring(colon + 1));
  if (score == null) return null;
  return (uci: uci, rawScore: score, rank: null, note: null);
}

DbMove _decodeSegment(_Segment segment) {
  final decoded = mapChessDbRawScoreStm(segment.rawScore);
  return DbMove(
    uci: segment.uci,
    stmCp: decoded.stmCp,
    mate: decoded.mate,
    rank: segment.rank,
    note: segment.note,
  );
}

/// `e2e4`, `e7e8q` — four coordinate characters plus an optional promotion.
bool _looksLikeUci(String s) {
  if (s.length < 4 || s.length > 5) return false;
  bool file(int i) => s.codeUnitAt(i) >= 0x61 && s.codeUnitAt(i) <= 0x68;
  bool rank(int i) => s.codeUnitAt(i) >= 0x31 && s.codeUnitAt(i) <= 0x38;
  return file(0) && rank(1) && file(2) && rank(3);
}

/// Result of validating a ChessDB TerarkDB `data/` directory.
class CdbDirectDirValidation {
  const CdbDirectDirValidation({required this.isValid, required this.message});

  final bool isValid;
  final String message;
}

/// Resolve [path] to the TerarkDB data directory (handles parent dump folders).
Future<Directory?> resolveCdbDirectDataDir(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return null;

  final dir = Directory(trimmed);
  if (await dir.exists()) return dir;

  final nested = Directory(p.join(trimmed, 'data'));
  if (await nested.exists()) return nested;
  return null;
}

/// Detailed validation: requires `CURRENT` and at least one `.sst` file.
Future<CdbDirectDirValidation> validateCdbDirectDataDirDetailed(
  String path,
) async {
  if (path.trim().isEmpty) {
    return const CdbDirectDirValidation(
      isValid: false,
      message: 'No directory selected',
    );
  }

  final dir = await resolveCdbDirectDataDir(path);
  if (dir == null) {
    return CdbDirectDirValidation(
      isValid: false,
      message: 'Directory not found: $path',
    );
  }

  final hasCurrent = await File(p.join(dir.path, 'CURRENT')).exists();
  var hasSst = false;
  await for (final entity in dir.list()) {
    if (p.extension(entity.path) == '.sst') {
      hasSst = true;
      break;
    }
  }

  if (hasCurrent && hasSst) {
    return CdbDirectDirValidation(
      isValid: true,
      message: 'Valid ChessDB data directory (${dir.path})',
    );
  }

  final missing = <String>[
    if (!hasCurrent) 'CURRENT',
    if (!hasSst) '.sst files',
  ];
  return CdbDirectDirValidation(
    isValid: false,
    message:
        'Missing ${missing.join(' and ')} — point at the TerarkDB data/ folder',
  );
}

/// True when [path] looks like a TerarkDB data directory.
Future<bool> validateCdbDirectDataDir(String path) async {
  return (await validateCdbDirectDataDirDetailed(path)).isValid;
}
