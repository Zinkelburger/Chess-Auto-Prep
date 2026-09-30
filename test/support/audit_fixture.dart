import 'dart:async';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pv_text.dart';
import 'package:chess_auto_prep/engines/engine.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/engines/maia/move_policy.dart';

// A chapter with one of everything the audit finds, the engine and the
// model that find it: the audit's owner and pane tests share them.

/// White: after 1.e4 the model barely expects 1...e6 — too rarely for the
/// Replies tab at the default floor — which the engine rates level with
/// Black's best and the chapter never answers; after 1.e4 c5 the chapter's
/// 2.Nc3 loses 1.3 pawns against 2.Nf3.
const auditChapter = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 2. Nf3 *

[Event "Sicilian"]
[Result "*"]

1. e4 c5 2. Nc3 *
''';

Fen after(String moves) {
  var fen = Fen.initial;
  for (final uci in moves.split(' ').where((m) => m.isNotEmpty)) {
    fen = pvMoves(fen, [uci]).single.after;
  }
  return fen;
}

/// Engine lines by position: what the table engine answers, best first,
/// from the side to move.
Map<String, List<(String, int)>> auditTable() => {
  after('').position: [('e2e4', 30), ('d2d4', 28), ('g1f3', 25)],
  after('e2e4').position: [('e7e5', -30), ('e7e6', -40), ('c7c5', -45)],
  after('e2e4 e7e5').position: [('g1f3', 30), ('f1c4', 25), ('b1c3', 20)],
  after('e2e4 c7c5').position: [('g1f3', 40), ('d2d4', 35), ('c2c3', 30)],
  // After 2.Nc3, from Black's side.
  after('e2e4 c7c5 b1c3').position: [('b8c6', 90)],
};

/// The model's shares: after 1.e4 it expects e5 and c5, e6 hardly at all
/// ([e6] of the games, 1% unless a test says otherwise).
final class AuditShares implements MovePolicy {
  const AuditShares({this.e6 = 0.01});

  final double e6;

  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async =>
      fen.position == after('e2e4').position
      ? MaiaPolicy({'e7e5': 0.6, 'c7c5': 0.3, 'e7e6': e6})
      : const MaiaPolicy({});
}

/// An engine that answers every search from [lines] at the depth asked,
/// then ends it, as a real one does with `bestmove`.
final class TableEngine implements Engine {
  TableEngine(this.lines);

  final Map<String, List<(String, int)>> lines;
  final asked = <String>[];
  Future<void>? hold;
  bool quitCalled = false;

  /// After this many searches the process goes: [exited] completes and
  /// every later search ends with no lines, as a Stockfish that crashed.
  int? dieAfter;
  final _exited = Completer<EngineExit>();

  @override
  String get name => 'Table';

  @override
  Search analyse(Fen fen, {required int multiPv, int? depth}) {
    asked.add(fen.position);
    final controller = StreamController<EngineLine>();
    if (dieAfter case final searches? when asked.length > searches) {
      if (!_exited.isCompleted) _exited.complete(EngineExit.ended);
      unawaited(controller.close());
      return Search(lines: controller.stream, stop: () async {});
    }
    unawaited(() async {
      if (hold case final waiting?) await waiting;
      final known = lines[fen.position] ?? const [('a2a3', 0)];
      for (final (index, (uci, cp)) in known.take(multiPv).indexed) {
        controller.add(
          EngineLine(
            multiPv: index + 1,
            depth: depth ?? 14,
            score: Centipawns(cp),
            pv: [uci],
          ),
        );
      }
      await controller.close();
    }());
    return Search(lines: controller.stream, stop: () async {});
  }

  @override
  Future<EngineExit> get exited => _exited.future;

  @override
  Future<void> quit() async {
    quitCalled = true;
    if (!_exited.isCompleted) _exited.complete(EngineExit.ended);
  }
}
