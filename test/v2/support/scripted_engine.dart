import 'dart:async';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/engines/engine.dart';
import 'package:chess_auto_prep/v2/engines/engine_line.dart';

/// An engine whose lines the test writes. Each `analyse` ends the previous
/// search, as the real one does.
final class ScriptedEngine implements Engine {
  final searches = <ScriptedSearch>[];
  final _exited = Completer<EngineExit>();
  bool quitCalled = false;

  @override
  String get name => 'Scripted 1';

  ScriptedSearch get current => searches.last;

  @override
  Search analyse(Fen fen, {required int multiPv}) {
    final search = ScriptedSearch(fen: fen, multiPv: multiPv);
    searches.add(search);
    return search.search;
  }

  @override
  Future<EngineExit> get exited => _exited.future;

  @override
  Future<void> quit() async {
    quitCalled = true;
    _end(EngineExit.ended);
  }

  /// The process dies on its own.
  void crash() => _end(EngineExit.ended);

  /// The engine stops answering and is killed for it, the way a real one is
  /// when it never says `bestmove`.
  void wedge() => _end(EngineExit.unresponsive);

  void _end(EngineExit exit) {
    searches.lastOrNull?.end();
    if (!_exited.isCompleted) _exited.complete(exit);
  }
}

/// A search whose `stop` only marks it; the test ends it with [end], the
/// way a real engine ends one with `bestmove`, so late lines can be sent.
final class ScriptedSearch {
  ScriptedSearch({required this.fen, required this.multiPv});

  final Fen fen;
  final int multiPv;
  final _lines = StreamController<EngineLine>();
  final _done = Completer<void>();
  bool stopped = false;

  late final search = Search(
    lines: _lines.stream,
    stop: () {
      stopped = true;
      return _done.future;
    },
  );

  bool get ended => _done.isCompleted;

  void emit(EngineLine line) => _lines.add(line);

  void end() {
    if (ended) return;
    _done.complete();
    unawaited(_lines.close());
  }
}

EngineLine line({
  int multiPv = 1,
  int depth = 10,
  Score score = const Centipawns(0),
  List<String> pv = const ['g1f3'],
}) => EngineLine(multiPv: multiPv, depth: depth, score: score, pv: pv);
