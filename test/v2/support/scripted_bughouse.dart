import 'dart:async';

import 'package:chess_auto_prep/v2/app/environment.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/hivemind.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/table.dart';
import 'package:chess_auto_prep/v2/engines/engine.dart';
import 'package:chess_auto_prep/v2/engines/hivemind_engine.dart';
import 'package:chess_auto_prep/v2/chess/bughouse/match.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_books.dart';
import 'package:chess_auto_prep/v2/storage/bughouse_matches.dart';

/// A Hivemind the test drives. Each search answers [answer] — by default a
/// few lines of the searched team's first legal moves — at once, or when
/// the test calls [release] while [hold] is on.
final class ScriptedHivemind implements Hivemind {
  @override
  Map<String, Object?> get provenance => const {
    'engine_name': 'Scripted Hivemind',
  };
  final asked = <HivemindQuestion>[];
  HivemindAnswer Function(HivemindQuestion question) answer = firstMoves;
  bool hold = false;
  int stops = 0;
  final _held = <(HivemindQuestion, Completer<HivemindAnswer>)>[];
  final _exited = Completer<EngineExit>();

  @override
  Future<HivemindAnswer> search(HivemindQuestion question) {
    asked.add(question);
    if (_exited.isCompleted) {
      return Future.value(const HivemindFailed('The bughouse engine stopped.'));
    }
    if (!hold) return Future.value(answer(question));
    final done = Completer<HivemindAnswer>();
    _held.add((question, done));
    return done.future;
  }

  /// Answers every search waiting.
  void release() {
    for (final (question, done) in _held) {
      done.complete(answer(question));
    }
    _held.clear();
  }

  int get waiting => _held.length;

  @override
  void stop() {
    stops++;
    if (_held.isNotEmpty) release();
  }

  /// The process goes: every search waiting fails.
  void crash() {
    for (final (_, done) in _held) {
      done.complete(const HivemindFailed('The bughouse engine stopped.'));
    }
    _held.clear();
    if (!_exited.isCompleted) _exited.complete(EngineExit.ended);
  }

  @override
  Future<EngineExit> get exited => _exited.future;

  bool get gone => _exited.isCompleted;

  @override
  Future<void> quit() async => crash();
}

/// Up to three lines, one per legal move of the searched team on the first
/// board it is on move, the first scoring cp −200 and each next one 30
/// worse; no move, no lines.
HivemindAnswer firstMoves(HivemindQuestion question) {
  final position = question.position;
  final board = BoardNumber.values
      .where((b) => position.mover(b).team == question.team)
      .firstOrNull;
  if (board == null) return const HivemindSearched(best: null, lines: []);
  final moves = position.legalMoves(board).take(3).toList();
  JointMove joint(String uci) =>
      board == BoardNumber.one ? JointMove(uci, null) : JointMove(null, uci);
  final lines = [
    for (final (i, move) in moves.indexed)
      JointLine(
        rank: i + 1,
        cp: -200 - 30 * i,
        nodes: 200,
        pv: [joint(move.uci)],
      ),
  ];
  return HivemindSearched(best: lines.firstOrNull?.pv.first, lines: lines);
}

/// The precomputed book, from a map of positions by key.
final class ScriptedHivemindBook implements HivemindBook {
  final positions = <int, HivemindLookup>{};
  int lookups = 0;

  @override
  Future<HivemindLookup> lookup(TablePosition position) async {
    lookups++;
    return positions[position.bookKey] ?? const HivemindNotFound();
  }

  /// What the engine added, in order.
  final saved = <HivemindEntry>[];

  @override
  Future<HivemindSave> save(HivemindEntry entry) async {
    if (saving != null) return saving!(entry);
    saved.add(entry);
    return const HivemindSaved();
  }

  Future<HivemindSave> Function(HivemindEntry entry)? saving;
}

/// The FICS archive, from a map of positions by key; none by default.
final class ScriptedFicsBook implements FicsBook {
  bool present = false;
  final positions = <int, FicsPosition>{};

  @override
  Future<bool> available() async => present;

  @override
  Future<FicsLookup> explore(TablePosition position) async => present
      ? FicsFound((
          games: 5000,
          years: '2001–2021',
          maxPly: 12,
          minGames: 3,
        ), positions[position.bookKey] ?? (games: 0, moves: const []))
      : const FicsAbsent();
}

/// The matches in memory, as the folder keeps them; [failCreate] makes the
/// next create fail as a folder that cannot be made does.
final class ScriptedMatchStore implements MatchStore {
  final saved = <String, StoredMatch>{};
  final deleted = <String>[];
  String? failCreate;

  @override
  Future<List<StoredMatch>> list() async =>
      [...saved.values]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Future<MatchCreate> create(MatchConfig config, DateTime now) async {
    if (failCreate case final detail?) return MatchCreateFailed(detail);
    final id = 'match-${saved.length + 1}';
    final match = StoredMatch(
      id: id,
      config: config,
      createdAt: now,
      status: MatchStatus.pending,
    );
    saved[id] = match;
    return MatchCreated(match);
  }

  @override
  Future<MatchWriteProblem> save(StoredMatch match) async {
    saved[match.id] = match;
    return null;
  }

  @override
  Future<MatchWriteProblem> delete(String id) async {
    saved.remove(id);
    deleted.add(id);
    return null;
  }
}

/// The lab's outside world for a window test: the engine bundled, one
/// scripted engine, a book and an archive the test fills.
final class ScriptedBughouse {
  /// The engine the last start handed out; a start after it went away
  /// hands out a new one that answers the same way.
  ScriptedHivemind engine = ScriptedHivemind();
  final book = ScriptedHivemindBook();
  final archive = ScriptedFicsBook();
  final matches = ScriptedMatchStore();
  bool bundled = true;
  String? startFailure;
  int starts = 0;

  BughouseOutside get outside => (
    bundled: () async => bundled,
    launch: ({required cores}) async {
      starts++;
      final failure = startFailure;
      if (failure != null) return HivemindStartFailed(failure);
      if (engine.gone) {
        engine = ScriptedHivemind()..answer = engine.answer;
      }
      return HivemindStarted(engine);
    },
    hivemindBook: book,
    ficsBook: archive,
    matches: matches,
  );
}
