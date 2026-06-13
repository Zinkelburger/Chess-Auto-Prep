/// ChessDB cloud API client (queryscore).
///
/// Endpoint: `http://www.chessdb.cn/cdb.php?action=queryscore&board=[FEN]`
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/eval_constants.dart';
import '../../utils/fen_utils.dart';
import 'eval_canonicalize.dart';
import 'external_eval_provider.dart';

const _defaultBaseUrl = 'http://www.chessdb.cn/cdb.php';
const _quotaDateKey = 'chessdb_api_quota_date';
const _quotaCountKey = 'chessdb_api_quota_count';

typedef ChessDbHttpFetch = Future<http.Response> Function(Uri uri);

/// Parse a queryscore response body into white-normalized cp.
///
/// Returns null on unknown / invalid / rate-limit responses.
EvalHit? parseChessDbQueryScoreBody(String body, String fen) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;

  if (trimmed.contains('unknown') ||
      trimmed.contains('invalid board') ||
      trimmed.toLowerCase().contains('rate limit') ||
      trimmed.toLowerCase().contains('too many')) {
    return null;
  }

  final isWhiteStm = isWhiteToMove(canonicalizeFen4(fen));

  // Plain-text: eval:123
  final evalMatch = RegExp(r'eval:\s*(-?\d+)', caseSensitive: false)
      .firstMatch(trimmed);
  if (evalMatch != null) {
    final raw = int.parse(evalMatch.group(1)!);
    final mapped = mapChessDbApiScore(raw, isWhiteToMove: isWhiteStm);
    if (mapped == null) return null;
    final cp = mapped.$1;
    final mate = mapped.$2;
    return EvalHit(cp: cp, mate: mate, depth: 0);
  }

  // JSON: {"status":"ok","eval":123,...}
  try {
    final json = jsonDecode(trimmed);
    if (json is Map<String, dynamic>) {
      final status = json['status']?.toString() ?? '';
      if (status == 'unknown' || status == 'invalid board') return null;
      if (json.containsKey('eval')) {
        final raw = (json['eval'] as num).toInt();
        final mapped = mapChessDbApiScore(raw, isWhiteToMove: isWhiteStm);
        if (mapped == null) return null;
        final cp = mapped.$1;
        final mate = mapped.$2;
        final depth = (json['depth'] as num?)?.toInt() ?? 0;
        return EvalHit(cp: cp, mate: mate, depth: depth);
      }
    }
  } catch (_) {
    // Not JSON — fall through.
  }

  return null;
}

/// Map ChessDB raw score (STM) to white-normalized (cp, mate?).
(int cp, int? mate)? mapChessDbApiScore(int raw, {required bool isWhiteToMove}) {
  int stmCp;
  int? mate;

  if (raw.abs() > kMateCpBase) {
    final ply = 30000 - raw.abs();
    mate = raw > 0 ? ply : -ply;
    stmCp = raw > 0 ? (kMateCpBase - ply) : (-kMateCpBase - ply);
  } else {
    stmCp = raw;
  }

  final whiteCp = isWhiteToMove ? stmCp : -stmCp;
  return (whiteCp, mate);
}

class ChessDbApiProvider implements ExternalEvalProvider {
  final int dailyQuota;
  final int concurrency;
  final ChessDbHttpFetch? httpFetch;
  final SharedPreferences? prefsOverride;

  int _usedToday = 0;
  String _quotaDate = '';
  bool _quotaLoaded = false;
  int _inFlight = 0;
  final _waiters = <Completer<void>>[];

  ChessDbApiProvider({
    this.dailyQuota = 5000,
    this.concurrency = 2,
    this.httpFetch,
    this.prefsOverride,
  });

  int get usedToday => _usedToday;
  int get quotaLimit => dailyQuota;
  bool get quotaRemaining => _usedToday < dailyQuota;

  Future<void> init() async {
    if (_quotaLoaded) return;
    final prefs = prefsOverride ?? await SharedPreferences.getInstance();
    final today = _todayKey();
    _quotaDate = prefs.getString(_quotaDateKey) ?? '';
    if (_quotaDate == today) {
      _usedToday = prefs.getInt(_quotaCountKey) ?? 0;
    } else {
      _usedToday = 0;
      _quotaDate = today;
      await prefs.setString(_quotaDateKey, today);
      await prefs.setInt(_quotaCountKey, 0);
    }
    _quotaLoaded = true;
  }

  Future<void> flushQuota() async {
    if (!_quotaLoaded) return;
    final prefs = prefsOverride ?? await SharedPreferences.getInstance();
    await prefs.setString(_quotaDateKey, _quotaDate);
    await prefs.setInt(_quotaCountKey, _usedToday);
  }

  @override
  Future<EvalLookupResult> lookup(String fen, {required int minDepth}) async {
    await init();
    if (!quotaRemaining) return const EvalLookupResult.miss();

    await _acquireSlot();
    try {
      if (!quotaRemaining) return const EvalLookupResult.miss();

      final board = Uri.encodeComponent(canonicalizeFen4(fen));
      final uri = Uri.parse('$_defaultBaseUrl?action=queryscore&board=$board');
      final fetch = httpFetch ?? http.get;
      final response = await fetch(uri);

      if (response.statusCode == 429) return const EvalLookupResult.miss();

      final hit = parseChessDbQueryScoreBody(response.body, fen);
      if (hit == null) return const EvalLookupResult.miss();

      if (hit.depth > 0 && hit.depth < minDepth) {
        return const EvalLookupResult.shallow();
      }

      _usedToday++;
      unawaited(flushQuota());
      return EvalLookupResult.found(hit);
    } catch (e) {
      if (kDebugMode) debugPrint('[ChessDbApiProvider] lookup failed: $e');
      return const EvalLookupResult.miss();
    } finally {
      _releaseSlot();
    }
  }

  Future<void> _acquireSlot() async {
    while (_inFlight >= concurrency) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _inFlight++;
  }

  void _releaseSlot() {
    _inFlight--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }

  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}
