/// The model-game writer produces two shapes of one movetext: a chapter entry
/// with study headers, and a plain game record for the companion file.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/generation/course/master_improvements.dart';
import 'package:chess_auto_prep/services/generation/course/model_game_selector.dart';
import 'package:chess_auto_prep/services/generation/course/model_game_writer.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_map.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

String _fenAfter(List<String> sans) {
  Position pos = Chess.initial;
  for (final san in sans) {
    pos = pos.play(pos.parseSan(san)!);
  }
  return pos.fen;
}

PgnGameRecord _record({
  String event = 'Test Open',
  String date = '2021.05.03',
  int elo = 2800,
  GameOutcome? outcome = GameOutcome.whiteWin,
  required List<String> moves,
}) => PgnGameRecord(
  white: 'Carlsen, M',
  black: 'Anand, V',
  whiteElo: elo,
  blackElo: elo,
  event: event,
  date: date,
  outcome: outcome,
  movesSan: moves,
);

const _config = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  annotationDetail: MoveAnnotationDetail.full,
);

void main() {
  final ruy = ModelGame(
    record: _record(moves: ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']),
    followedPlies: 5,
  );

  group('label', () {
    test('players, occasion and result', () {
      expect(
        ModelGameWriter(config: _config).label(ruy),
        'Carlsen, M – Anand, V, Test Open 2021 (1-0)',
      );
    });

    test('omits an unknown event, year and result', () {
      final bare = ModelGame(
        record: _record(event: '?', date: '', outcome: null, moves: ['e4']),
        followedPlies: 1,
      );
      expect(
        ModelGameWriter(config: _config).label(bare),
        'Carlsen, M – Anand, V',
      );
    });
  });

  group('chapterPgn', () {
    test('study headers with the real game data under ModelGame* tags', () {
      final pgn = ModelGameWriter(config: _config).chapterPgn(
        ruy,
        courseTitle: 'Course',
        chapterName: '3. Model games',
        variationName: 'Carlsen – Anand',
      );
      expect(pgn, startsWith('[Event "Course"]\n'));
      expect(pgn, contains('[White "3. Model games"]'));
      expect(pgn, contains('[Black "Carlsen – Anand"]'));
      expect(pgn, contains('[Result "*"]'));
      expect(pgn, contains('[ModelGameWhite "Carlsen, M"]'));
      expect(pgn, contains('[ModelGameResult "1-0"]'));
      expect(pgn, contains('[ModelGameWhiteElo "2800"]'));
      expect(pgn.trim(), endsWith('1. e4 e5 2. Nf3 Nc6 3. Bb5 *'));
    });
  });

  group('standalonePgn', () {
    test('a plain game record with the course named in a Repertoire tag', () {
      final pgn = ModelGameWriter(
        config: _config,
      ).standalonePgn(ruy, courseTitle: 'Course');
      expect(pgn, contains('[White "Carlsen, M"]'));
      expect(pgn, contains('[Black "Anand, V"]'));
      expect(pgn, contains('[Result "1-0"]'));
      expect(pgn, contains('[Repertoire "Course"]'));
      expect(pgn, isNot(contains('ModelGame')));
      expect(pgn.trim(), endsWith('1. e4 e5 2. Nf3 Nc6 3. Bb5 1-0'));
    });

    test('unknown event and date fall back to the PGN placeholders', () {
      final pgn = ModelGameWriter(config: _config).standalonePgn(
        ModelGame(
          record: _record(event: '', date: '', moves: ['e4']),
          followedPlies: 1,
        ),
        courseTitle: 'Course',
      );
      expect(pgn, contains('[Event "?"]'));
      expect(pgn, contains('[Date "????.??.??"]'));
    });
  });

  group('departure', () {
    final before = _fenAfter(['e4', 'e5', 'Nf3', 'Nc6']);
    final departs = ModelGame(
      record: _record(moves: ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Ba4']),
      followedPlies: 4,
      departure: ModelGameDeparture(
        index: 4,
        kind: DepartureKind.ours,
        fenBefore: before,
        gameSan: 'Bb5',
        repertoireLine: const ['Bc4', 'Bc5', 'c3'],
      ),
    );

    test('ours: names the repertoire move and hangs our line off it', () {
      final pgn = ModelGameWriter(
        config: _config,
      ).standalonePgn(departs, courseTitle: 'Course');
      expect(
        pgn,
        contains('3. Bb5 {Our repertoire: 3.Bc4} (3. Bc4 Bc5 4. c3) a6 4. Ba4'),
      );
    });

    test('ours: cites the improvement found for that master move', () {
      const cited = MasterGame(
        id: 1,
        twicIssue: 1600,
        event: 'Tata Steel',
        site: 'Wijk aan Zee',
        date: '2025.01.20',
        round: '3',
        white: 'Giri,A',
        black: 'Caruana,F',
        result: '1/2-1/2',
        whiteElo: 2740,
        blackElo: 2800,
        whiteFideId: null,
        blackFideId: null,
        eco: 'C65',
        plyCount: 4,
        movetext: '1. e4 e5 2. Nf3 Nc6',
      );
      MasterImprovement improvement(String masterSan) => MasterImprovement(
        ourSan: 'Bc4',
        masterSan: masterSan,
        gainCp: 35,
        masterGames: 40,
        game: cited,
        continuation: const [],
      );

      expect(
        ModelGameWriter(
          config: _config,
          improvements: {before: improvement('Bb5')},
        ).standalonePgn(departs, courseTitle: 'Course'),
        contains('{Our repertoire: 3.Bc4 — improves on 3.Bb5 (+0.35)}'),
      );
      // A different master move at the same position is not "improved on".
      expect(
        ModelGameWriter(
          config: _config,
          improvements: {before: improvement('d4')},
        ).standalonePgn(departs, courseTitle: 'Course'),
        isNot(contains('improves')),
      );
    });

    test('opponent: lists the replies we prepare, with no variation', () {
      final game = ModelGame(
        record: _record(moves: ['e4', 'c6', 'd4']),
        followedPlies: 1,
        departure: ModelGameDeparture(
          index: 1,
          kind: DepartureKind.opponent,
          fenBefore: _fenAfter(['e4']),
          gameSan: 'c6',
          preparedReplies: const ['e5', 'c5'],
        ),
      );
      final pgn = ModelGameWriter(
        config: _config,
      ).standalonePgn(game, courseTitle: 'Course');
      expect(
        pgn,
        contains(
          '1. e4 c6 {Outside the repertoire — prepared here: 1...e5, 1...c5} '
          '2. d4',
        ),
      );
      expect(pgn, isNot(contains('(')));
    });

    test('a note is prose, so detail none drops it', () {
      final pgn = ModelGameWriter(
        config: _config.copyWith(annotationDetail: MoveAnnotationDetail.none),
      ).standalonePgn(departs, courseTitle: 'Course');
      expect(pgn, isNot(contains('{')));
      // The variation is content, not detail: it is still written.
      expect(pgn, contains('(3. Bc4 Bc5 4. c3)'));
    });
  });

  group('a build rooted mid-opening', () {
    const prefix = [
      'd4', 'Nf6', 'c4', 'c5', 'd5', 'b5', 'cxb5', 'a6', 'bxa6', 'e6', //
    ];

    test('writes the game from the root under a FEN header', () {
      final writer = ModelGameWriter(
        config: TreeBuildConfig(
          startFen: _fenAfter(prefix),
          playAsWhite: false,
        ),
      );
      final game = ModelGame(
        record: _record(moves: [...prefix, 'Nc3', 'exd5', 'Nxd5', 'Be7']),
        followedPlies: 3,
        rootIndex: prefix.length,
      );
      final pgn = writer.standalonePgn(game, courseTitle: 'Benko');
      expect(pgn, contains('[FEN "${_fenAfter(prefix)}"]'));
      expect(pgn, contains('[SetUp "1"]'));
      expect(pgn, contains('6. Nc3 exd5 7. Nxd5 Be7'));
      expect(pgn, isNot(contains('1. d4')));
    });
  });
}
