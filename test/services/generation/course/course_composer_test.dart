import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/generation/course/chapter_titles.dart';
import 'package:chess_auto_prep/services/generation/course/master_improvements.dart';
import 'package:chess_auto_prep/services/generation/course/course_composer.dart';
import 'package:chess_auto_prep/services/generation/course/model_game_selector.dart';
import 'package:chess_auto_prep/services/generation/course/opening_namer.dart';
import 'package:chess_auto_prep/services/generation/course/refutation_prober.dart';
import 'package:chess_auto_prep/services/generation/export/move_annotation.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/engine_tail.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_map.dart';
import 'package:chess_auto_prep/services/master_games/master_games_db.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedLine _line(String moves, {double probability = 0.01}) {
  final san = moves.split(' ').where((m) => m.isNotEmpty).toList();
  return ExtractedLine(
    movesSan: san,
    movesUci: san,
    probability: probability,
    moveAnnotations: [
      for (var i = 0; i < san.length; i++)
        MoveAnnotation(
          evalCp: 30,
          myEase: i.isEven ? 0.8 : null,
          likelihood: i.isOdd ? 0.42 : null,
          likelihoodSource: i.isOdd ? MoveLikelihoodSource.maia : null,
        ),
    ],
  );
}

List<ExtractedLine> _fan(String prefix, int count) {
  const fillers = ['a3', 'a4', 'b3', 'b4', 'c3', 'g3', 'g4', 'h3', 'h4', 'Na3'];
  return [
    for (var i = 0; i < count; i++)
      _line('$prefix ${fillers[i % fillers.length]}$i'),
  ];
}

TreeBuildConfig _config({
  bool organize = true,
  MoveAnnotationDetail detail = MoveAnnotationDetail.full,
}) => TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  organizeIntoChapters: organize,
  maxLinesPerChapter: 6,
  minLinesPerChapter: 3,
  annotationDetail: detail,
);

CourseComposer _composer(
  TreeBuildConfig config, {
  List<String> prefix = const [],
}) => CourseComposer(
  config: config,
  namer: CourseNamer(
    // No bundled assets in a unit test: naming degrades to move references,
    // which is exactly the fallback path worth pinning.
    namer: OpeningNamer.unavailable(startFen: kStandardStartFen),
    rootWhiteToMove: true,
    startMoveNumber: 1,
    repertoirePrefix: prefix,
    playAsWhite: config.playAsWhite,
  ),
  repertoireStartFen: kStandardStartFen,
  repertoirePrefix: prefix,
  repertoireName: 'Test repertoire',
);

/// A composer whose build root is ten plies in, the way a Benko chapter's is.
/// [_modelGameStartFen] follows `config.startFen`, so a model game written
/// from move one would be movetext that cannot be played from the header FEN.
CourseComposer _midOpeningComposer(List<String> prefix) {
  final rootFen = _fenAfter(prefix);
  return CourseComposer(
    config: TreeBuildConfig(
      startFen: rootFen,
      playAsWhite: false,
      organizeIntoChapters: true,
      maxLinesPerChapter: 6,
      minLinesPerChapter: 3,
    ),
    namer: CourseNamer(
      namer: OpeningNamer.unavailable(startFen: rootFen),
      rootWhiteToMove: true,
      startMoveNumber: 6,
      repertoirePrefix: prefix,
      playAsWhite: false,
    ),
    repertoireStartFen: rootFen,
    repertoirePrefix: const [],
    repertoireName: 'Benko',
  );
}

String _fenAfter(List<String> sans) {
  Position pos = Chess.initial;
  for (final san in sans) {
    pos = pos.play(pos.parseSan(san)!);
  }
  return pos.fen;
}

PgnGameRecord _record({
  required String white,
  required String black,
  required int elo,
  required GameOutcome outcome,
  required List<String> moves,
}) => PgnGameRecord(
  white: white,
  black: black,
  whiteElo: elo,
  blackElo: elo,
  event: 'Test Open',
  date: '2021.05.03',
  outcome: outcome,
  movesSan: moves,
);

void main() {
  group('CourseComposer', () {
    test('emits one PGN game per line', () {
      final lines = _fan('e4 e5', 4);
      final course = _composer(_config()).compose(lines: lines);

      expect(course.entries, hasLength(4));
      expect(course.outline, hasLength(1));
      expect(course.outline.single.entryCount, 4);
    });

    test('tags chapter in [White] and variation in [Black]', () {
      final course = _composer(
        _config(),
      ).compose(lines: [..._fan('e4 e5 Nf3', 4), ..._fan('e4 c5 Nf3', 4)]);

      final first = course.entries.first;
      expect(first.pgn, contains('[White "${first.chapterName}"]'));
      expect(first.pgn, contains('[Black "${first.variationName}"]'));
      expect(first.pgn, contains('[Result "*"]'));
    });

    test('the emitted file is read back as chapters by RepertoireService', () {
      final course = _composer(
        _config(),
      ).compose(lines: [..._fan('e4 e5 Nf3', 4), ..._fan('e4 c5 Nf3', 4)]);

      final parsed = RepertoireService().parseRepertoirePgn(
        course.toPgn(),
        trainingColor: 'white',
      );

      expect(parsed, hasLength(8));
      expect(
        parsed.map((l) => l.chapter).whereType<String>().toSet(),
        hasLength(2),
        reason: 'header chapter detection must recognise our own export',
      );
      // The line's display name comes from [Black] once chapters are detected.
      expect(parsed.first.name, course.entries.first.variationName);
    });

    test('names chapters by their defining move when no book is available', () {
      final course = _composer(
        _config(),
      ).compose(lines: [..._fan('e4 e5 Nf3', 4), ..._fan('e4 c5 Nf3', 4)]);

      expect(course.outline.map((c) => c.name), [
        startsWith('1. After 1...'),
        startsWith('2. After 1...'),
      ]);
    });

    test('chapter names are unique so consumers cannot merge them', () {
      final course = _composer(_config()).compose(
        lines: [
          ..._fan('e4 e5 Nf3', 4),
          ..._fan('e4 c5 Nf3', 4),
          ..._fan('e4 d5 exd5', 4),
        ],
      );

      final names = course.outline.map((c) => c.name).toList();
      expect(names.toSet(), hasLength(names.length));
    });

    test('full detail writes the computed metrics next to the moves', () {
      final course = _composer(_config()).compose(lines: _fan('e4 e5', 2));

      expect(course.entries.first.pgn, contains('[%eval '));
      expect(course.entries.first.pgn, contains('[%myEase '));
      expect(course.entries.first.pgn, contains('[%maiaProbability '));
    });

    test('detail none writes bare movetext', () {
      final course = _composer(
        _config(detail: MoveAnnotationDetail.none),
      ).compose(lines: _fan('e4 e5', 2));

      expect(course.entries.first.pgn, isNot(contains('[%')));
      expect(course.entries.first.pgn, contains('1. e4'));
    });

    test('chapters off produces a single flat group', () {
      final course = _composer(
        _config(organize: false),
      ).compose(lines: [..._fan('e4 e5 Nf3', 4), ..._fan('e4 c5 Nf3', 4)]);

      expect(course.outline, hasLength(1));
      expect(course.entries, hasLength(8));
    });

    test('the repertoire prefix is prepended to every exported line', () {
      final course = _composer(
        _config(),
        prefix: ['d4', 'Nf6'],
      ).compose(lines: _fan('c4 e6', 3));

      expect(course.entries.first.movesSan.take(2), ['d4', 'Nf6']);
      expect(course.entries.first.pgn, contains('1. d4 Nf6'));
    });

    test('prefix moves carry no annotations', () {
      final course = _composer(
        _config(),
        prefix: ['d4', 'Nf6'],
      ).compose(lines: _fan('c4 e6', 3));

      // The first annotated move must be the line's own first move, not d4.
      final movetext = course.entries.first.pgn.split('\n\n').last;
      expect(movetext.indexOf('[%eval'), greaterThan(movetext.indexOf('Nf6')));
    });

    group('model games', () {
      final games = [
        ModelGame(
          record: _record(
            white: 'Carlsen, M',
            black: 'Anand, V',
            elo: 2800,
            outcome: GameOutcome.whiteWin,
            moves: ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5'],
          ),
          followedPlies: 5,
        ),
      ];

      test('a build rooted mid-opening writes the game from that root', () {
        const prefix = [
          'd4', 'Nf6', 'c4', 'c5', 'd5', 'b5', 'cxb5', 'a6', 'bxa6', 'e6', //
        ];
        final game = ModelGame(
          record: _record(
            white: 'Stalmach, R',
            black: 'Suleymanli, S',
            elo: 2370,
            outcome: GameOutcome.blackWin,
            moves: [...prefix, 'Nc3', 'exd5', 'Nxd5', 'Be7'],
          ),
          followedPlies: 3,
          rootIndex: prefix.length,
        );

        final course = _midOpeningComposer(
          prefix,
        ).compose(lines: _fan('Nc3 exd5', 4), modelGames: [game]);

        final pgn = course.entries.last.pgn;
        // The prefix is already on the board under the FEN header; writing it
        // again produced a game whose first move is illegal in its own
        // position.  Numbering starts at the root's move six, Black to reply.
        expect(pgn, contains('6. Nc3 exd5'));
        expect(pgn, isNot(contains('1. d4')));
        expect(course.entries.last.movesSan, ['Nc3', 'exd5', 'Nxd5', 'Be7']);
      });

      test('append as a trailing chapter', () {
        final course = _composer(
          _config(),
        ).compose(lines: _fan('e4 e5', 4), modelGames: games);

        expect(course.outline.last.kind, ChapterKind.modelGames);
        expect(course.outline.last.name, endsWith('Model games'));
        expect(course.modelGameCount, 1);
        expect(course.entries.last.movesSan, contains('Bb5'));
      });

      test('name themselves with players, event and result', () {
        final course = _composer(
          _config(),
        ).compose(lines: _fan('e4 e5', 4), modelGames: games);

        expect(
          course.entries.last.variationName,
          'Carlsen, M – Anand, V, Test Open 2021 (1-0)',
        );
      });

      test('preserve the real game data under ModelGame* headers', () {
        final course = _composer(
          _config(),
        ).compose(lines: _fan('e4 e5', 4), modelGames: games);

        final pgn = course.entries.last.pgn;
        expect(pgn, contains('[ModelGameWhite "Carlsen, M"]'));
        expect(pgn, contains('[ModelGameResult "1-0"]'));
        expect(pgn, contains('[ModelGameWhiteElo "2800"]'));
        // "*" keeps header chapter detection working for the whole file.
        expect(pgn, contains('[Result "*"]'));
      });

      test('do not break chapter detection for the rest of the file', () {
        final course = _composer(_config()).compose(
          lines: [..._fan('e4 e5 Nf3', 4), ..._fan('e4 c5 Nf3', 4)],
          modelGames: games,
        );

        final parsed = RepertoireService().parseRepertoirePgn(
          course.toPgn(),
          trainingColor: 'white',
        );
        expect(parsed.last.chapter, endsWith('Model games'));
      });

      test('are read back as model games, not as lines to learn', () {
        final course = _composer(_config()).compose(
          lines: [..._fan('e4 e5 Nf3', 4), ..._fan('e4 c5 Nf3', 4)],
          modelGames: games,
        );

        final parsed = RepertoireService().parseRepertoirePgn(
          course.toPgn(),
          trainingColor: 'white',
        );
        expect(parsed.where((l) => l.isModelGame), hasLength(1));
        expect(parsed.last.isModelGame, isTrue);
      });

      test('carry no invented commentary', () {
        final course = _composer(
          _config(),
        ).compose(lines: _fan('e4 e5', 4), modelGames: games);

        expect(course.entries.last.pgn, isNot(contains('{')));
      });

      test('are also emitted as real games for a companion file', () {
        final course = _composer(
          _config(),
        ).compose(lines: _fan('e4 e5', 4), modelGames: games);
        expect(course.modelGamePgns, hasLength(1));
        final pgn = course.modelGamePgns.single;
        expect(pgn, contains('[White "Carlsen, M"]'));
        expect(pgn, contains('[Black "Anand, V"]'));
        expect(pgn, contains('[Result "1-0"]'));
        expect(pgn, contains('[Event "Test Open"]'));
        expect(pgn, contains('[Repertoire "'));
        expect(pgn.trim(), endsWith('1-0'));
        expect(pgn, isNot(contains('ModelGameWhite')));
        // Both shapes share one movetext.
        expect(course.entries.last.pgn, contains('1. e4 e5 2. Nf3 Nc6 3. Bb5'));
        expect(pgn, contains('1. e4 e5 2. Nf3 Nc6 3. Bb5'));
      });

      group('departure annotations', () {
        final before = _fenAfter(['e4', 'e5', 'Nf3', 'Nc6']);
        // The game played 3.Bb5 where the repertoire plays 3.Bc4.
        final departs = ModelGame(
          record: _record(
            white: 'Carlsen, M',
            black: 'Anand, V',
            elo: 2800,
            outcome: GameOutcome.whiteWin,
            moves: ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Ba4'],
          ),
          followedPlies: 4,
          departure: ModelGameDeparture(
            index: 4,
            kind: DepartureKind.ours,
            fenBefore: before,
            gameSan: 'Bb5',
            repertoireLine: const ['Bc4', 'Bc5', 'c3'],
          ),
        );

        test('our departure: comment names the repertoire move and the '
            'repertoire mainline hangs off the game move', () {
          final course = _composer(
            _config(),
          ).compose(lines: _fan('e4 e5', 4), modelGames: [departs]);
          for (final pgn in [
            course.entries.last.pgn,
            course.modelGamePgns.single,
          ]) {
            expect(
              pgn,
              contains(
                '3. Bb5 {Our repertoire: 3.Bc4} (3. Bc4 Bc5 4. c3) a6 4. Ba4',
              ),
            );
          }
        });

        test('our departure cites the improvement when the probe found one '
            'at that position for that master move', () {
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
          final course = _composer(_config()).compose(
            lines: _fan('e4 e5', 4),
            modelGames: [departs],
            improvements: {
              before: const MasterImprovement(
                ourSan: 'Bc4',
                masterSan: 'Bb5',
                gainCp: 35,
                masterGames: 40,
                game: cited,
                continuation: ['a6'],
              ),
            },
          );
          expect(
            course.modelGamePgns.single,
            contains('{Our repertoire: 3.Bc4 — improves on 3.Bb5 (+0.35)}'),
          );
          // A different master move at the same position is not "improved on".
          final other = _composer(_config()).compose(
            lines: _fan('e4 e5', 4),
            modelGames: [departs],
            improvements: {
              before: const MasterImprovement(
                ourSan: 'Bc4',
                masterSan: 'd4',
                gainCp: 35,
                masterGames: 40,
                game: cited,
                continuation: [],
              ),
            },
          );
          expect(
            other.modelGamePgns.single,
            contains('{Our repertoire: 3.Bc4}'),
          );
          expect(other.modelGamePgns.single, isNot(contains('improves')));
        });

        test('opponent departure: lists the replies we prepare', () {
          final game = ModelGame(
            record: _record(
              white: 'Carlsen, M',
              black: 'Anand, V',
              elo: 2800,
              outcome: GameOutcome.whiteWin,
              moves: ['e4', 'c6', 'd4'],
            ),
            followedPlies: 1,
            departure: ModelGameDeparture(
              index: 1,
              kind: DepartureKind.opponent,
              fenBefore: _fenAfter(['e4']),
              gameSan: 'c6',
              preparedReplies: const ['e5', 'c5'],
            ),
          );
          final course = _composer(
            _config(),
          ).compose(lines: _fan('e4 e5', 4), modelGames: [game]);
          expect(
            course.modelGamePgns.single,
            contains(
              '1. e4 c6 {Outside the repertoire — prepared here: 1...e5, 1...c5} 2. d4',
            ),
          );
          expect(course.modelGamePgns.single, isNot(contains('(')));
        });

        test('an annotated model game is still read back as a model game', () {
          final course = _composer(_config()).compose(
            lines: [..._fan('e4 e5 Nf3', 4), ..._fan('e4 c5 Nf3', 4)],
            modelGames: [departs],
          );
          final parsed = RepertoireService().parseRepertoirePgn(
            course.toPgn(),
            trainingColor: 'white',
          );
          expect(parsed.where((l) => l.isModelGame), hasLength(1));
        });
      });
    });

    group('engine tails', () {
      const cut = ExtractedLine(
        movesSan: ['e4', 'e5', 'Nf3'],
        movesUci: [],
        probability: 0.5,
        leafFen: 'cutoff',
      );

      test('extends the mainline so the moves are trained', () {
        final course = _composer(_config(detail: MoveAnnotationDetail.none))
            .compose(
              lines: [cut],
              engineTails: const {
                'cutoff': EngineTail(movesSan: ['Nc6', 'Bb5', 'a6'], depth: 22),
              },
            );

        final entry = course.entries.single;
        expect(entry.movesSan, ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6']);
        expect(entry.pgn, contains('2. Nf3 Nc6 3. Bb5 a6'));
      });

      test('marks where preparation stopped', () {
        final course = _composer(_config(detail: MoveAnnotationDetail.full))
            .compose(
              lines: [cut],
              engineTails: const {
                'cutoff': EngineTail(movesSan: ['Nc6', 'Bb5'], depth: 22),
              },
            );

        // Trained like the rest, but the file still says which moves the
        // build actually vouched for.
        expect(
          course.entries.single.pgn,
          contains(
            'Nc6 {Engine continuation from here at depth 22 — best play, '
            'not prepared theory}',
          ),
        );
      });

      test('no tail for a line the engine had nothing to say about', () {
        final course = _composer(
          _config(detail: MoveAnnotationDetail.none),
        ).compose(lines: [cut], engineTails: const {});

        expect(course.entries.single.pgn, isNot(contains('Prepared line')));
      });
    });

    group('refutations', () {
      // A line the build stopped because the reply left us winning.
      const blunder = ExtractedLine(
        movesSan: ['e4', 'e5', 'Nc3', 'Nf6', 'Bc4', 'Nxe4'],
        movesUci: [],
        probability: 0.01,
        leafFen: 'x',
      );

      test('hang the punishment off the move that loses', () {
        final course = _composer(_config(detail: MoveAnnotationDetail.none))
            .compose(
              lines: [blunder],
              refutations: const {
                'x': ['Nxe4', 'd5', 'Bxd5'],
              },
            );

        final entry = course.entries.single;
        expect(entry.refutation, ['Nxe4', 'd5', 'Bxd5']);
        expect(
          entry.pgn,
          contains('3. Bc4 Nxe4 (3... Nxe4 4. Nxe4 d5 5. Bxd5)'),
        );
      });

      test('leave the mainline ending where the repertoire ends', () {
        final course = _composer(_config(detail: MoveAnnotationDetail.none))
            .compose(
              lines: [blunder],
              refutations: const {
                'x': ['Nxe4', 'd5'],
              },
            );

        expect(course.entries.single.movesSan, [
          'e4',
          'e5',
          'Nc3',
          'Nf6',
          'Bc4',
          'Nxe4',
        ]);
      });

      test('a line with nothing to punish is written unchanged', () {
        final course = _composer(
          _config(detail: MoveAnnotationDetail.none),
        ).compose(lines: [blunder]);

        expect(course.entries.single.refutation, isEmpty);
        expect(course.entries.single.pgn, isNot(contains('(')));
      });
    });

    group('refuted alternatives', () {
      ExtractedLine lineWithChoices(String moves, List<LineChoice> choices) {
        final line = _line(moves);
        return ExtractedLine(
          movesSan: line.movesSan,
          movesUci: line.movesUci,
          probability: line.probability,
          moveAnnotations: line.moveAnnotations,
          choices: choices,
        );
      }

      const refuted = RefutedAlternative(
        san: 'f3',
        continuation: ['e5', 'g4', 'Qh4#'],
        lossCp: 430,
      );

      test('replace the move they were played instead of', () {
        final course = _composer(_config(detail: MoveAnnotationDetail.none))
            .compose(
              lines: [
                lineWithChoices('e4 e5 Nf3', [
                  const LineChoice(
                    moveIndex: 0,
                    fenBefore: 'start',
                    isOurMove: true,
                    bestEvalCpForUs: 30,
                    knownUcis: [],
                  ),
                ]),
              ],
              alternatives: const {'start': refuted},
            );

        final entry = course.entries.single;
        expect(entry.refutedAlternatives, ['f3']);
        expect(entry.pgn, contains('1. e4 (1. f3? e5 2. g4 Qh4#) e5'));
        expect(entry.movesSan, ['e4', 'e5', 'Nf3']);
      });

      test('carry what the move costs when the export carries metrics', () {
        final course = _composer(_config()).compose(
          lines: [
            lineWithChoices('e4 e5', [
              const LineChoice(
                moveIndex: 0,
                fenBefore: 'start',
                isOurMove: true,
                bestEvalCpForUs: 30,
                knownUcis: [],
              ),
            ]),
          ],
          alternatives: const {'start': refuted},
        );

        expect(course.entries.single.pgn, contains('(1. f3? {[%loss 4.30]}'));
      });

      test('never become trainable moves', () {
        final course = _composer(_config(detail: MoveAnnotationDetail.none))
            .compose(
              lines: [
                lineWithChoices('e4 e5 Nf3', [
                  const LineChoice(
                    moveIndex: 0,
                    fenBefore: 'start',
                    isOurMove: true,
                    bestEvalCpForUs: 30,
                    knownUcis: [],
                  ),
                ]),
              ],
              alternatives: const {'start': refuted},
            );

        final parsed = RepertoireService().parseRepertoirePgn(
          course.toPgn(),
          trainingColor: 'white',
        );

        // The sideline is there to read, not to drill: the trainable line is
        // still exactly what the repertoire selected.
        expect(parsed.single.moves, ['e4', 'e5', 'Nf3']);
      });

      test('a position with no refuted move adds nothing', () {
        final course = _composer(_config(detail: MoveAnnotationDetail.none))
            .compose(
              lines: [
                lineWithChoices('e4 e5', [
                  const LineChoice(
                    moveIndex: 0,
                    fenBefore: 'start',
                    isOurMove: true,
                    bestEvalCpForUs: 30,
                    knownUcis: [],
                  ),
                ]),
              ],
            );

        expect(course.entries.single.refutedAlternatives, isEmpty);
        expect(course.entries.single.pgn, isNot(contains('(')));
      });

      test('are offset by the repertoire prefix, like annotations', () {
        final course =
            _composer(
              _config(detail: MoveAnnotationDetail.none),
              prefix: ['d4', 'd5'],
            ).compose(
              lines: [
                lineWithChoices('c4 e6', [
                  const LineChoice(
                    moveIndex: 0,
                    fenBefore: 'afterD4D5',
                    isOurMove: true,
                    bestEvalCpForUs: 30,
                    knownUcis: [],
                  ),
                ]),
              ],
              alternatives: const {
                'afterD4D5': RefutedAlternative(
                  san: 'Nc3',
                  continuation: ['Nf6'],
                  lossCp: 200,
                ),
              },
            );

        // The prefix moves are plies 0-1, so the line's own first move is
        // ply 2 — the sideline hangs off 2. c4, not 1. d4.
        expect(course.entries.single.pgn, contains('2. c4 (2. Nc3?! Nf6) e6'));
      });
    });
  });
}
