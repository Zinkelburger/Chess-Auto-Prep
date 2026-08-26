/// "X improves on Y in `<game>`": the pass must claim an improvement only when
/// masters mostly played something else *and* the engine, judging both moves
/// at the same depth, backs ours by the configured margin — and it must
/// cite a real game with the continuation that game played.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/analysis/discovery_result.dart';
import 'package:chess_auto_prep/services/generation/course/course_composer.dart';
import 'package:chess_auto_prep/services/generation/course/master_improvements.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/course/chapter_titles.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/generation/course/opening_namer.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_fakes.dart';

const _config = TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  verifyDepth: 20,
  improvementMinGainCp: 40,
);

String _fenAfter(List<String> sans) {
  Position pos = Chess.initial;
  for (final san in sans) {
    pos = pos.play(pos.parseSan(san)!);
  }
  return pos.fen;
}

BookMove _book(String uci, {int games = 10, int top = 1, int recent = 1}) =>
    BookMove(
      uci: uci,
      games: games,
      whiteWins: games ~/ 2,
      draws: games - games ~/ 2,
      blackWins: 0,
      averageElo: 2600,
      maxElo: 2750,
      lastYear: 2025,
      topGameId: top,
      recentGameId: recent,
    );

/// Masters after 1.e4 e5 2.Nf3 Nc6 mostly play 3.Bb5; our line plays 3.Bc4.
const _game = MasterGame(
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
  plyCount: 12,
  movetext: '1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 4. O-O Nxe4 5. Re1 Nd6 6. Nxe5',
);

void main() {
  final before = _fenAfter(['e4', 'e5', 'Nf3', 'Nc6']);
  final afterBc4 = _fenAfter(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4']);
  final afterBb5 = _fenAfter(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']);

  ExtractedLine line() => ExtractedLine(
    movesSan: const ['e4', 'e5', 'Nf3', 'Nc6', 'Bc4'],
    movesUci: const ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4'],
    probability: 0.2,
    choices: [
      LineChoice(
        moveIndex: 4,
        fenBefore: before,
        isOurMove: true,
        bestEvalCpForUs: 30,
        knownUcis: const ['f1c4'],
      ),
    ],
  );

  FakeStockfishPool pool({required int bc4Cp, required int bb5Cp}) {
    final p = FakeStockfishPool();
    // Black to move after each: scores are White-POV in DiscoveryLine.
    p.discoveryByFen[afterBc4] = DiscoveryResult(
      lines: [
        discoveryLine(pvNumber: 1, cpWhite: bc4Cp, pv: ['f8c5']),
      ],
    );
    p.discoveryByFen[afterBb5] = DiscoveryResult(
      lines: [
        discoveryLine(pvNumber: 1, cpWhite: bb5Cp, pv: ['a7a6']),
      ],
    );
    return p;
  }

  MasterImprovementProber prober(FakeStockfishPool p, {List<BookMove>? book}) =>
      MasterImprovementProber(
        config: _config,
        pool: p,
        book: (fen) => fen == before
            ? (book ?? [_book('f1b5', games: 40), _book('f1c4', games: 9)])
            : const [],
        gameById: (id) => id == 1 ? _game : null,
      );

  group('MasterImprovementProber', () {
    test(
      'cites the game and its continuation when the engine backs us',
      () async {
        final found = await prober(pool(bc4Cp: 60, bb5Cp: 10)).probe([line()]);
        final imp = found[before]!;
        expect(imp.ourSan, 'Bc4');
        expect(imp.masterSan, 'Bb5');
        expect(imp.gainCp, 50);
        expect(imp.masterGames, 40);
        expect(imp.continuation, ['Nf6', 'O-O', 'Nxe4', 'Re1', 'Nd6', 'Nxe5']);
        expect(
          imp.note,
          'Bc4 improves on Bb5 (Giri–Caruana, Wijk aan Zee 2025, ½–½)',
        );
        expect(imp.sidelineComment, contains('40 master games'));
      },
    );

    test('stays silent when the gain is under the threshold', () async {
      final found = await prober(pool(bc4Cp: 30, bb5Cp: 10)).probe([line()]);
      expect(found, isEmpty);
    });

    test('stays silent when masters agree with the repertoire', () async {
      final found = await prober(
        pool(bc4Cp: 60, bb5Cp: 10),
        book: [_book('f1c4', games: 50), _book('f1b5', games: 9)],
      ).probe([line()]);
      expect(found, isEmpty);
    });

    test('stays silent without an engine', () async {
      final p = pool(bc4Cp: 60, bb5Cp: 10)..workers = 0;
      expect(await prober(p).probe([line()]), isEmpty);
    });

    test(
      'judges both moves at the same depth (two searches per site)',
      () async {
        final p = pool(bc4Cp: 60, bb5Cp: 10);
        await prober(p).probe([line()]);
        expect(p.discoverMultiPvCalls, hasLength(2));
      },
    );
  });

  group('CourseComposer with improvements', () {
    test(
      'writes the note on our move and the master move as a sideline',
      () async {
        final p = pool(bc4Cp: 60, bb5Cp: 10);
        final improvements = await prober(p).probe([line()]);
        final composer = CourseComposer(
          config: _config.copyWith(organizeIntoChapters: false),
          namer: CourseNamer(
            namer: OpeningNamer.unavailable(startFen: kStandardStartFen),
            rootWhiteToMove: true,
            startMoveNumber: 1,
            repertoirePrefix: const [],
            playAsWhite: true,
          ),
          repertoireStartFen: kStandardStartFen,
          repertoirePrefix: const [],
        );
        final course = composer.compose(
          lines: [line()],
          improvements: improvements,
        );
        final pgn = course.entries.single.pgn;
        expect(
          pgn,
          contains(
            'Bc4 {Bc4 improves on Bb5 (Giri–Caruana, Wijk aan Zee 2025, ½–½)',
          ),
        );
        expect(
          pgn,
          contains(
            '(3. Bb5 {Giri–Caruana, Wijk aan Zee 2025, ½–½; 40 master games} Nf6 4. O-O Nxe4 5. Re1 Nd6 6. Nxe5)',
          ),
        );
      },
    );
  });
}
