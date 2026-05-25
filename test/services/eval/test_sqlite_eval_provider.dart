import 'package:chess_auto_prep/services/eval/eval_canonicalize.dart';
import 'package:chess_auto_prep/services/eval/external_eval_provider.dart';
import 'package:chess_auto_prep/services/eval/sqlite_eval_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'eval_test_helpers.dart';

void main() {
  setUpAll(() async {
    await initEvalTestSqlite();
  });

  const fens = [
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
    'rnbqkbnr/pp1ppppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2',
    'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 3',
  ];

  late Database db;
  late String dbPath;

  setUp(() async {
    dbPath = inMemoryDatabasePath;
    db = await databaseFactory.openDatabase(dbPath);
    await db.execute('''
      CREATE TABLE chessdb_evals(
        fen TEXT PRIMARY KEY,
        cp INTEGER,
        mate INTEGER,
        depth INTEGER,
        move TEXT
      )
    ''');

    final rows = <Map<String, Object?>>[
      {'fen': canonicalizeFen4(fens[0]), 'cp': 30, 'mate': null, 'depth': 22, 'move': 'e2e4'},
      {'fen': canonicalizeFen4(fens[1]), 'cp': -15, 'mate': null, 'depth': 20, 'move': 'e7e5'},
      {'fen': canonicalizeFen4(fens[2]), 'cp': null, 'mate': 3, 'depth': 24, 'move': 'g1f3'},
      {'fen': canonicalizeFen4(fens[3]), 'cp': 10, 'mate': null, 'depth': 12, 'move': 'b1c3'},
      {'fen': canonicalizeFen4(fens[4]), 'cp': null, 'mate': null, 'depth': 0, 'move': null},
    ];
    for (final row in rows) {
      await db.insert('chessdb_evals', row);
    }
  });

  tearDown(() async {
    await db.close();
  });

  Future<SqliteEvalProvider> provider() async {
    final p = SqliteEvalProvider(
      path: dbPath,
      openOverride: (_) => Future.value(db),
    );
    await p.init();
    return p;
  }

  test('lookup returns cp hit with sufficient depth', () async {
    final p = await provider();
    final result = await p.lookup(fens[0], minDepth: 20);
    expect(result.isHit, isTrue);
    expect(result.hit!.cp, 30);
    expect(result.hit!.bestMove, 'e2e4');
  });

  test('lookup returns shallow for insufficient depth', () async {
    final p = await provider();
    final result = await p.lookup(fens[3], minDepth: 18);
    expect(result.shallow, isTrue);
  });

  test('lookup maps mate to white-normalized cp', () async {
    final p = await provider();
    final result = await p.lookup(fens[2], minDepth: 20);
    expect(result.isHit, isTrue);
    expect(result.hit!.mate, 3);
    expect(result.hit!.cp, greaterThan(9000));
  });

  test('lookup hard miss for absent FEN', () async {
    final p = await provider();
    final result = await p.lookup(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1',
      minDepth: 10,
    );
    expect(result.hardMiss, isTrue);
  });

  test('lookup hard miss when cp and mate both null', () async {
    final p = await provider();
    final result = await p.lookup(fens[4], minDepth: 1);
    expect(result.hardMiss, isTrue);
  });
}
