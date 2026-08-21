@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/services/master_games/game_authority.dart';
import 'package:chess_auto_prep/services/master_games/master_book_rebuild.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Three games that play the same first three moves, so one book row has to
/// choose between them.  The blitz game is the highest rated by 300 points —
/// which is exactly the situation a TWIC corpus is full of, and exactly the
/// one where `top_game` gives the wrong citation.
const _pgn = '''
[Event "Titled Tue 16th Dec 2025"]
[Site "chess.com INT"]
[Date "2025.12.16"]
[White "Blitz,Winner"]
[Black "Blitz,Loser"]
[Result "1-0"]
[WhiteElo "2800"]
[BlackElo "2790"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0

[Event "36th Czech Open A 2025"]
[Site "Pardubice CZE"]
[Date "2025.08.02"]
[White "Otb,Strong"]
[Black "Otb,Opponent"]
[Result "1/2-1/2"]
[WhiteElo "2500"]
[BlackElo "2480"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 1/2-1/2

[Event "Regional Weekender"]
[Site "Hastings ENG"]
[Date "2025.09.02"]
[White "Otb,Weak"]
[Black "Otb,Other"]
[Result "0-1"]
[WhiteElo "2200"]
[BlackElo "2210"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 d6 0-1
''';

const _ruyFen =
    'r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3';
const _afterNf3 =
    'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mgcite');
    dbPath = '${tmp.path}/master_games.db';
    importPgnIntoMasterGames(
      MasterGamesImportRequest(dbPath: dbPath, pgnText: _pgn, twicIssue: 1),
    );
  });
  tearDown(() async => tmp.delete(recursive: true));

  test('import records each game authority', () {
    final db = MasterGamesDb.open(dbPath, readOnly: true);
    int count(GameAuthority a) =>
        db.raw
                .select('SELECT count(*) FROM games WHERE authority = ?', [
                  a.code,
                ])
                .first
                .columnAt(0)
            as int;

    expect(count(GameAuthority.online), 1);
    expect(count(GameAuthority.classical), 2);
    db.close();
  });

  test('the citation is the strongest classical game, not the strongest', () {
    final db = MasterGamesDb.open(dbPath, readOnly: true);
    // 3.Bb5 was played by all three; the blitz game is 300 points stronger.
    final bb5 = db.bookMoves(_afterNf3).firstWhere((m) => m.uci == 'f1b5');
    expect(bb5.games, 3);

    expect(db.game(bb5.topGameId)!.white, 'Blitz,Winner');
    expect(db.game(bb5.citeGameId)!.white, 'Otb,Strong');
    expect(db.game(bb5.citeGameId)!.site, 'Pardubice CZE');
    db.close();
  });

  test('a move only ever played online still cites something', () {
    final db = MasterGamesDb.open(dbPath, readOnly: true);
    // 3...a6 is the blitz game alone: no classical game to prefer.
    final a6 = db.bookMoves(_ruyFen).firstWhere((m) => m.uci == 'a7a6');
    expect(a6.topClassicalGameId, 0);
    expect(a6.citeGameId, a6.topGameId);
    expect(db.game(a6.citeGameId)!.white, 'Blitz,Winner');
    db.close();
  });

  test('a reclassified game gives up the citation it had won', () async {
    // Imitate the classifier being sharpened: the Czech Open game is demoted
    // out of the classical tier, so its citation must pass to the weaker
    // over-the-board game rather than stick.
    final rw = MasterGamesDb.open(dbPath);
    final before = rw.bookMoves(_afterNf3).firstWhere((m) => m.uci == 'f1b5');
    expect(rw.game(before.citeGameId)!.white, 'Otb,Strong');

    rw.raw.execute(
      "UPDATE games SET event = 'Czech Open Blitz 2025' WHERE white = ?",
      ['Otb,Strong'],
    );
    refreshAuthorities(rw);
    await rebuildClassicalCitations(rw);

    final after = rw.bookMoves(_afterNf3).firstWhere((m) => m.uci == 'f1b5');
    expect(
      rw.game(after.citeGameId)!.white,
      'Otb,Weak',
      reason: 'the demoted game must not keep a citation it no longer earns',
    );
    rw.close();
  });

  test('the rebuild reproduces what the import wrote, and is idempotent', () {
    // Wipe the columns to imitate a pre-v3 database, then walk it.
    final rw = MasterGamesDb.open(dbPath);
    rw.raw.execute(
      'UPDATE book SET top_classical_game = 0, classical_max_elo = 0',
    );
    final bb5Before = rw
        .bookMoves(_afterNf3)
        .firstWhere((m) => m.uci == 'f1b5');
    expect(bb5Before.citeGameId, bb5Before.topGameId, reason: 'fallback');

    final first = rebuildClassicalCitations(rw);
    return first.then((r1) async {
      expect(r1.gamesScanned, 2, reason: 'only classical games are replayed');
      expect(r1.movesRecorded, greaterThan(0));

      final bb5 = rw.bookMoves(_afterNf3).firstWhere((m) => m.uci == 'f1b5');
      expect(rw.game(bb5.citeGameId)!.white, 'Otb,Strong');

      // Running it again must change nothing: the guard keeps the stronger
      // game, so a resumed or repeated pass is safe.
      final r2 = await rebuildClassicalCitations(rw);
      expect(r2.gamesScanned, 2);
      expect(r2.movesRecorded, 0);
      final again = rw.bookMoves(_afterNf3).firstWhere((m) => m.uci == 'f1b5');
      expect(again.topClassicalGameId, bb5.topClassicalGameId);
      rw.close();
    });
  });
}
