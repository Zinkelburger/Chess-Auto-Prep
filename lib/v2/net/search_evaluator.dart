import 'dart:async';
import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:http/http.dart' as http;

import '../chess/generation/eval.dart';
import '../chess/generation/evaluation_source.dart';
import '../chess/generation/sources.dart';

/// Serial, bounded, opt-in database lookups. Remote values never enter the
/// fixed-depth local cache. A failed connection or rate limit opens the circuit
/// for this run, leaving the engine available without repeated network delays.
final class SearchEvaluator implements PositionEvaluator {
  SearchEvaluator({
    required this.source,
    required this.fallback,
    required this.minDepth,
    http.Client? client,
  }) : _client = client ?? http.Client();
  final EvaluationSource source;
  final PositionEvaluator fallback;
  final int minDepth;
  final http.Client _client;
  final _answers = <String, Future<EvaluationResult>>{};
  Future<void> _tail = Future.value();
  bool _offline = false;
  bool _closed = false;
  int _requests = 0;

  @override
  Future<EvaluationResult> evaluate(Position position) =>
      _answers.putIfAbsent(position.fen, () async {
        final before = _tail;
        final gate = Completer<void>();
        _tail = gate.future;
        Evaluated? score;
        try {
          await before;
          if (!_closed && !_offline && _requests < 1000) {
            score = await _remote(position);
          }
        } finally {
          gate.complete();
        }
        if (_closed)
          return const EvaluationUnavailable('The search was stopped.');
        return score ?? await evaluationOf(fallback, position);
      });

  Future<Evaluated?> _remote(Position position) async {
    _requests++;
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
    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 429 || response.statusCode >= 500) {
        _offline = true;
      }
      if (response.statusCode != 200) return null;
      final score = source == EvaluationSource.chessDb
          ? chessDbScore(response.body)
          : lichessScore(
              response.body,
              whiteToMove: position.turn == Side.white,
              minDepth: minDepth,
            );
      if (score == null) return null;
      return Evaluated(
        score,
        depth: source == EvaluationSource.lichess
            ? (jsonDecode(response.body) as Map)['depth'] as int?
            : null,
      );
    } on Object {
      _offline = true;
      return null;
    }
  }

  void close() {
    _closed = true;
    _client.close();
  }
}

/// ChessDB scores are side-to-move, with mate packed around 30000.
Eval? chessDbScore(String body) {
  final match = RegExp(r'^eval:(-?\d+)$').firstMatch(body.trim());
  if (match == null) return null;
  final raw = int.parse(match[1]!);
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
