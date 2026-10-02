import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../chess/bughouse/expectimax.dart';
import '../chess/bughouse/table.dart';

/// Shared with the offline builder and the web API. Search snapshots are
/// committed only when complete; every costly engine evaluation checkpoints.
final class BughouseExpectimaxBook {
  BughouseExpectimaxBook(this.path);
  final String path;
  Database? _connection;
  Database get _db {
    if (_connection case final db?) return db;
    Directory(p.dirname(path)).createSync(recursive: true);
    final db = _connection = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA busy_timeout=10000');
    db.execute('''CREATE TABLE IF NOT EXISTS analysis (
      pos INTEGER NOT NULL, board TEXT NOT NULL, profile TEXT NOT NULL,
      plies INTEGER NOT NULL, nodes INTEGER NOT NULL, fen TEXT NOT NULL,
      data TEXT NOT NULL, updated INTEGER NOT NULL,
      PRIMARY KEY(pos, board, profile))''');
    db.execute('''CREATE TABLE IF NOT EXISTS evaluation (
      fen TEXT NOT NULL, board TEXT NOT NULL, engine TEXT NOT NULL,
      budget INTEGER NOT NULL, value REAL NOT NULL, best TEXT,
      nodes INTEGER NOT NULL, depth INTEGER,
      PRIMARY KEY(fen, board, engine, budget))''');
    return db;
  }

  Future<BughouseEvaluation> evaluate(
    TablePosition position,
    BoardNumber board,
    int budget,
    String engine,
    BughouseValue run,
  ) async {
    final args = [
      position.keyText,
      board == BoardNumber.one ? 'A' : 'B',
      engine,
      budget,
    ];
    final found = _db.select(
      'SELECT value,best,nodes,depth FROM evaluation WHERE fen=? AND board=? AND engine=? AND budget>=? ORDER BY budget DESC LIMIT 1',
      args,
    );
    if (found.isNotEmpty) {
      final row = found.single;
      return (
        value: (row['value'] as num).toDouble(),
        best: row['best'] as String?,
        nodes: row['nodes'] as int,
        depth: row['depth'] as int?,
      );
    }
    final result = await run(position, board);
    _db.execute('INSERT OR REPLACE INTO evaluation VALUES (?,?,?,?,?,?,?,?)', [
      ...args,
      result.value,
      result.best,
      result.nodes,
      result.depth,
    ]);
    return result;
  }

  Future<List<BughouseBranch>?> load(
    TablePosition position,
    BoardNumber board,
    BughouseSearchOptions options,
  ) async {
    final found = _db.select(
      'SELECT data FROM analysis WHERE pos=? AND board=? AND profile LIKE ? AND fen=? AND plies>=? AND nodes>=? ORDER BY plies DESC,nodes DESC LIMIT 1',
      [
        position.bookKey,
        board == BoardNumber.one ? 'A' : 'B',
        '${BughouseSearchOptions.model}:%',
        position.keyText,
        options.plies,
        options.nodes,
      ],
    );
    if (found.isEmpty) return null;
    final data =
        jsonDecode(found.single['data'] as String) as Map<String, Object?>;
    return [
      for (final row in data['rows'] as List)
        readBranch(row as Map<String, Object?>),
    ];
  }

  Future<void> save(
    TablePosition position,
    BoardNumber board,
    BughouseSearchOptions options,
    List<BughouseBranch> rows,
  ) async {
    final data = jsonEncode({
      'model': BughouseSearchOptions.model,
      'perspective': 'white-on-selected-board',
      'plies': options.plies,
      'nodes': options.nodes,
      'selection': 'Hivemind best + top 4 probabilities >1%',
      'tail': 'unexpanded probability retains searched value',
      'rows': rows.map(writeBranch).toList(),
    });
    _db.execute('INSERT OR REPLACE INTO analysis VALUES (?,?,?,?,?,?,?,?)', [
      position.bookKey,
      board == BoardNumber.one ? 'A' : 'B',
      options.key,
      options.plies,
      options.nodes,
      position.keyText,
      data,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ]);
  }

  void close() {
    _connection?.close();
    _connection = null;
  }
}

Map<String, Object?> writeBranch(BughouseBranch branch) => {
  'uci': branch.move.uci,
  'san': branch.move.san,
  'board': branch.move.board == BoardNumber.one ? 'A' : 'B',
  'probability': branch.probability,
  'fen': branch.child.position.dualFen,
  'eval': branch.child.evaluation,
  'white': branch.child.white,
  'black': branch.child.black,
  'coverage': branch.child.coverage,
  'nodes': branch.child.nodes,
  'depth': branch.child.depth,
  'replies': branch.child.branches.map(writeBranch).toList(),
};

BughouseBranch readBranch(Map<String, Object?> row) {
  double number(String name) => (row[name] as num).toDouble();
  final fens = (row['fen'] as String).split('|');
  return BughouseBranch(
    (
      board: row['board'] == 'A' ? BoardNumber.one : BoardNumber.two,
      uci: row['uci'] as String,
      san: row['san'] as String,
    ),
    number('probability'),
    BughouseNode(
      position: TablePosition(
        Crazyhouse.fromSetup(Setup.parseFen(fens[0])),
        Crazyhouse.fromSetup(Setup.parseFen(fens[1])),
      ),
      evaluation: number('eval'),
      white: number('white'),
      black: number('black'),
      coverage: number('coverage'),
      nodes: row['nodes'] as int,
      depth: row['depth'] as int?,
      branches: [
        for (final child in row['replies'] as List)
          readBranch(child as Map<String, Object?>),
      ],
    ),
  );
}
