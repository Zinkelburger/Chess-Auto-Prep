/// How much of a built tree the master book actually reached.
///
/// Nothing measures TWIC usage during a build — [BuildStats] counts Lichess,
/// Maia, Stockfish and ChessDB calls but has no master-book counter — so this
/// answers the question after the fact: walk a serialized tree, ask the book
/// about every position, and report where it had something to say.
///
///   flutter test test/benchmark/book_coverage.dart \
///     --dart-define=TREE=…/tree.json --dart-define=DB=…/master_games.db
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:flutter_test/flutter_test.dart';

const _tree = String.fromEnvironment('TREE');
const _db = String.fromEnvironment('DB');
const _minGames = int.fromEnvironment('MASTER_MIN_GAMES', defaultValue: 3);

void _say(String s) => stdout.writeln('[book] $s');

void main() {
  test('book coverage', () async {
    if (_tree.isEmpty || _db.isEmpty) fail('TREE and DB are required');
    final root =
        (jsonDecode(File(_tree).readAsStringSync())
                as Map<String, dynamic>)['tree']
            as Map<String, dynamic>;
    final book = MasterGamesDb.open(_db, readOnly: true);

    // Per ply: nodes, how many the book knew at all, how many cleared
    // masterMinGames, and the games behind them.
    final nodes = <int, int>{};
    final known = <int, int>{};
    final practice = <int, int>{};
    final games = <int, List<int>>{};
    // Of the opponent replies the build kept, how many did masters play?
    var oppChildren = 0, oppChildrenInBook = 0;
    var total = 0, totalKnown = 0, totalPractice = 0;
    var deepestPractice = 0;

    void walk(Map<String, dynamic> n) {
      final ply = (n['depth'] as num?)?.toInt() ?? 0;
      final fen = n['fen'] as String? ?? '';
      final children =
          (n['children'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      total++;
      nodes[ply] = (nodes[ply] ?? 0) + 1;
      final moves = fen.isEmpty ? const <BookMove>[] : book.bookMoves(fen);
      final g = moves.fold<int>(0, (a, m) => a + m.games);
      if (moves.isNotEmpty) {
        known[ply] = (known[ply] ?? 0) + 1;
        totalKnown++;
      }
      if (g >= _minGames) {
        practice[ply] = (practice[ply] ?? 0) + 1;
        totalPractice++;
        (games[ply] ??= []).add(g);
        if (ply > deepestPractice) deepestPractice = ply;

        // Children here are the opponent's replies when it is their turn;
        // compare what the build kept against what masters actually played.
        final uciPlayed = {for (final m in moves) m.uci};
        for (final c in children) {
          final uci = c['move_uci'] as String? ?? c['uci'] as String? ?? '';
          if (uci.isEmpty) continue;
          oppChildren++;
          if (uciPlayed.contains(uci)) oppChildrenInBook++;
        }
      }
      for (final c in children) {
        walk(c);
      }
    }

    walk(root);

    _say('tree: $total nodes');
    _say(
      'book knew something about $totalKnown '
      '(${(100 * totalKnown / total).toStringAsFixed(1)}%)',
    );
    _say(
      'master practice (>= $_minGames games): $totalPractice '
      '(${(100 * totalPractice / total).toStringAsFixed(1)}%), '
      'deepest at ply $deepestPractice',
    );
    _say(
      'moves kept at book positions: $oppChildren, of which masters '
      'played $oppChildrenInBook '
      '(${oppChildren == 0 ? 0 : (100 * oppChildrenInBook / oppChildren).toStringAsFixed(1)}%)',
    );
    _say('');
    _say('ply   nodes   in-book   practice   median games');
    final plies = nodes.keys.toList()..sort();
    for (final ply in plies) {
      final n = nodes[ply]!;
      final k = known[ply] ?? 0;
      final pr = practice[ply] ?? 0;
      final gs = (games[ply] ?? [])..sort();
      final med = gs.isEmpty ? 0 : gs[gs.length ~/ 2];
      _say(
        '${ply.toString().padLeft(3)} '
        '${n.toString().padLeft(7)} '
        '${k.toString().padLeft(9)} '
        '${pr.toString().padLeft(10)} '
        '${med.toString().padLeft(14)}',
      );
    }
    book.close();
  }, timeout: const Timeout(Duration(minutes: 30)));
}
