/// Parse cdbdirect_get response strings (matches C cdbdirect_parse_response).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'chessdb_score.dart';
import 'db_move_list.dart';

/// Every move in a cdbdirect response, best first.
///
/// Two wire formats exist and both appear in real dumps: the verbose
/// `move:e2e4,score:30,rank:0,note:!,winrate:0.515|…` records, and the
/// compact `e2e4:30|d2d4:25` pairs.  A bare `eval:42` carries no moves and
/// yields an empty list — the position is scored but the dump has no move
/// breakdown for it.
List<DbMove> parseCdbDirectMoveList(String? response) {
  if (response == null || response.isEmpty) return const [];
  final lower = response.toLowerCase();
  if (lower == 'unknown' ||
      lower.startsWith('error') ||
      lower.startsWith('invalid')) {
    return const [];
  }
  if (response.startsWith('eval:') && !response.contains('|')) {
    return const [];
  }

  final moves = <DbMove>[];
  for (final raw in response.split('|')) {
    final seg = raw.trim();
    if (seg.isEmpty) continue;

    if (seg.contains('move:') || seg.contains('score:')) {
      String? move;
      int? score;
      int? rank;
      String? note;
      for (final field in seg.split(',')) {
        if (field.startsWith('move:')) {
          move = field.substring(5);
        } else if (field.startsWith('score:')) {
          score = int.tryParse(field.substring(6));
        } else if (field.startsWith('rank:')) {
          rank = int.tryParse(field.substring(5));
        } else if (field.startsWith('note:')) {
          final value = field.substring(5).trim();
          if (value.isNotEmpty) note = value;
        }
      }
      if (move == null || move.isEmpty || score == null) continue;
      final mapped = mapChessDbRawScoreStm(score);
      moves.add(
        DbMove(
          uci: move,
          stmCp: mapped.stmCp,
          mate: mapped.mate,
          rank: rank,
          note: note,
        ),
      );
      continue;
    }

    // Compact `uci:score` pair.  `ply:12` and other bookkeeping segments use
    // the same shape, so anything whose key is not move-like is skipped.
    final colon = seg.indexOf(':');
    if (colon <= 0) continue;
    final move = seg.substring(0, colon);
    if (!_looksLikeUci(move)) continue;
    final score = int.tryParse(seg.substring(colon + 1));
    if (score == null) continue;
    final mapped = mapChessDbRawScoreStm(score);
    moves.add(DbMove(uci: move, stmCp: mapped.stmCp, mate: mapped.mate));
  }

  return DbMoveList.sorted(moves);
}

/// `e2e4`, `e7e8q` — four coordinate characters plus an optional promotion.
bool _looksLikeUci(String s) {
  if (s.length < 4 || s.length > 5) return false;
  bool file(int i) => s.codeUnitAt(i) >= 0x61 && s.codeUnitAt(i) <= 0x68;
  bool rank(int i) => s.codeUnitAt(i) >= 0x31 && s.codeUnitAt(i) <= 0x38;
  return file(0) && rank(1) && file(2) && rank(3);
}

/// Returns STM-perspective centipawns and optional best move, or null on miss.
({int cp, int depth, String? bestMove})? parseCdbDirectResponse(
  String? response,
) {
  if (response == null || response.isEmpty) return null;
  final lower = response.toLowerCase();
  if (lower == 'unknown' ||
      lower.startsWith('error') ||
      lower.startsWith('invalid')) {
    return null;
  }

  if (response.startsWith('eval:') && !response.contains('|')) {
    final cp = int.tryParse(response.substring(5));
    if (cp == null) return null;
    return (cp: cp, depth: 20, bestMove: null);
  }

  final segments = response.split('|');
  int? bestCp;
  int bestRank = 9999;
  String? bestMove;

  for (final raw in segments) {
    final seg = raw.trim();
    if (seg.isEmpty) continue;

    if (seg.contains('move:') || seg.contains('score:')) {
      String? move;
      int? score;
      var rank = 9999;
      for (final field in seg.split(',')) {
        if (field.startsWith('move:')) {
          move = field.substring(5);
        } else if (field.startsWith('score:')) {
          score = int.tryParse(field.substring(6));
        } else if (field.startsWith('rank:')) {
          rank = int.tryParse(field.substring(5)) ?? 9999;
        }
      }
      if (move != null && move.isNotEmpty && score != null) {
        if (bestCp == null || rank < bestRank) {
          bestCp = score;
          bestRank = rank;
          bestMove = move;
        }
      }
    } else {
      final colon = seg.indexOf(':');
      if (colon <= 0) continue;
      final move = seg.substring(0, colon);
      final score = int.tryParse(seg.substring(colon + 1));
      if (score != null && bestCp == null) {
        bestCp = score;
        bestMove = move;
        bestRank = 0;
      }
    }
  }

  if (bestCp == null) return null;
  return (cp: bestCp, depth: 20, bestMove: bestMove);
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

  final missing = <String>[];
  if (!hasCurrent) missing.add('CURRENT');
  if (!hasSst) missing.add('.sst files');
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
