import 'dart:convert';

import 'package:dartchess/dartchess.dart';

import '../chess/generation/eval.dart';
import '../chess/generation/evaluation_source.dart';
import '../chess/generation/sources.dart';
import 'remote_queue.dart';

/// Opt-in database lookups through one run's share of the environment's
/// [RemoteQueue]. Remote values never enter the fixed-depth local cache.
/// Once the service is given up on, the engine answers for the rest of the
/// run without network delays.
final class SearchEvaluator implements PositionEvaluator {
  SearchEvaluator({
    required this.source,
    required this.fallback,
    required this.minDepth,
    required RemoteRun run,
  }) : _run = run;
  final EvaluationSource source;
  final PositionEvaluator fallback;
  final int minDepth;
  final RemoteRun _run;
  final _answers = <String, Future<EvaluationResult>>{};
  bool _closed = false;

  @override
  Future<EvaluationResult> evaluate(Position position) =>
      _answers.putIfAbsent(position.fen, () async {
        final score = await _remote(position);
        if (_closed) {
          return const EvaluationUnavailable('The search was stopped.');
        }
        return score ?? await evaluationOf(fallback, position);
      });

  Future<Evaluated?> _remote(Position position) async {
    final uri = source == EvaluationSource.chessDb
        ? Uri.https('www.chessdb.cn', '/cdb.php', {
            'action': 'queryscore',
            'board': position.fen,
            'learn': '0',
          })
        : Uri.https('lichess.org', '/api/cloud-eval', {
            'fen': position.fen,
            'multiPv': '1',
            'variant': 'standard',
          });
    final body = await _run.get(uri);
    if (body == null) return null;
    final score = source == EvaluationSource.chessDb
        ? chessDbScore(body)
        : lichessScore(
            body,
            whiteToMove: position.turn == Side.white,
            minDepth: minDepth,
          );
    if (score == null) return null;
    return Evaluated(
      score,
      depth: source == EvaluationSource.lichess
          ? (jsonDecode(body) as Map)['depth'] as int?
          : null,
    );
  }

  void close() {
    _closed = true;
    _run.close();
  }
}

/// ChessDB scores are side-to-move, with mate packed around 30000.
Eval? chessDbScore(String body) {
  final match = RegExp(r'^eval:(-?\d+)$').firstMatch(body.trim());
  return match == null ? null : chessDbCp(int.parse(match[1]!));
}

/// A raw ChessDB score as the search's packed centipawns: mate in N is
/// 30000 − N there and 10000 − N here. Null for a number neither.
Eval? chessDbCp(int raw) {
  if (raw.abs() <= mateBaseCp) return Eval(raw);
  final distance = 30000 - raw.abs();
  if (distance < 0 || distance >= 1000) return null;
  return Eval(raw.sign * (mateBaseCp - distance));
}

/// Lichess cloud PV scores are White's view, converted exactly once.
Eval? lichessScore(
  String body, {
  required bool whiteToMove,
  required int minDepth,
}) {
  final decoded = jsonDecode(body);
  if (decoded is! Map ||
      decoded['depth'] is! int ||
      (decoded['depth'] as int) < minDepth) {
    return null;
  }
  final pvs = decoded['pvs'];
  if (pvs is! List || pvs.isEmpty || pvs.first is! Map) return null;
  final pv = pvs.first as Map;
  final cp = pv['cp'];
  final mate = pv['mate'];
  final int value;
  if (cp is int && cp.abs() < mateSaturationCp) {
    value = cp;
  } else if (mate is int && mate != 0 && mate.abs() < 500) {
    value = mate.sign * (mateBaseCp - mate.abs() * 2);
  } else {
    return null;
  }
  return Eval(whiteToMove ? value : -value);
}
