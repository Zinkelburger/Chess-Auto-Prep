/// [CourseBuilder] on its own — the half of an export that turns extracted
/// lines into a course document.
///
/// The branching worth pinning is the model-game source ladder and the note
/// that explains an empty result. It used to live on
/// `GenerationSessionController` as a private method that assigned to a
/// public field, so testing it meant standing up a whole build; here it is a
/// value the builder returns.
library;

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/generation/course/course_builder.dart';
import 'package:chess_auto_prep/services/generation/course/enrichment_runner.dart';
import 'package:chess_auto_prep/services/generation/export/move_annotation.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_map.dart';
import 'package:flutter_test/flutter_test.dart';

import '../generation_test_helpers.dart';

ExtractedLine _line(List<String> san) => ExtractedLine(
  movesSan: san,
  movesUci: san,
  probability: 0.2,
  moveAnnotations: [
    for (var i = 0; i < san.length; i++) const MoveAnnotation(),
  ],
);

/// An engine build: no game database is involved, so "no database" is not
/// something the user needs to hear about.
TreeBuildConfig _engineBuild({int modelGames = 3}) => TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  buildMode: BuildMode.stockfishExpectimax,
  modelGameCount: modelGames,
  refutationLines: false,
  alternativeLines: false,
  engineTailPlies: 0,
);

/// A database build: the user asked for games, so an empty result is worth
/// explaining.
TreeBuildConfig _databaseBuild({int modelGames = 3}) => TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  buildMode: BuildMode.dbExplorer,
  modelGameCount: modelGames,
  refutationLines: false,
  alternativeLines: false,
  engineTailPlies: 0,
);

/// A game that shares no position with the fixture repertoire, so it is a
/// candidate the selector will look at and reject.
const _unrelatedGame = PgnGameRecord(
  white: 'Petrosian',
  black: 'Spassky',
  whiteElo: 2650,
  blackElo: 2690,
  event: 'Moscow',
  date: '1966.04.11',
  outcome: GameOutcome.draw,
  movesSan: ['b3', 'e5', 'Bb2', 'Nc6'],
);

PgnFreqMap _databaseHolding(PgnGameRecord game) =>
    PgnFreqMap()..games.offer(game);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StandardTree fixture;

  CourseBuilder makeBuilder({PgnFreqMap? database}) => CourseBuilder(
    enrichment: EnrichmentRunner(
      config: () => null,
      isCancelled: () => false,
      onStatus: (_) {},
      ensureEngine: () async {},
    ),
    gameDatabase: () => database,
    // No master-games database in a unit test: the ladder's last rung is
    // what an ordinary machine without the TWIC download actually hits.
    masterDbFor: (_) => null,
    fenMap: () => null,
  );

  Future<CourseBuild> buildWith(
    TreeBuildConfig config, {
    PgnFreqMap? database,
  }) => makeBuilder(database: database).build(
    tree: fixture.toTree(),
    lines: [
      _line(['e4', 'e5', 'Nf3']),
      _line(['d4', 'd5', 'c4']),
    ],
    config: config,
    repertoireFilePath: '/tmp/Italian.pgn',
    rootFen: kStandardStartFen,
    prefix: const [],
  );

  setUp(() => fixture = StandardTree());

  group('the composed course', () {
    test('carries every line it was given', () async {
      final built = await buildWith(_engineBuild());
      expect(built.course.entries, isNotEmpty);
    });

    test('is named after the repertoire file, not its path', () async {
      final built = await buildWith(_engineBuild());
      expect(built.course.title, contains('Italian'));
    });
  });

  group('the model-game note', () {
    test('stays empty when model games were never asked for', () async {
      final built = await buildWith(_engineBuild(modelGames: 0));
      expect(built.modelGameNote, isEmpty);
      expect(built.course.modelGamePgns, isEmpty);
    });

    test(
      'stays empty on an engine build, which never has a database',
      () async {
        // The old code said "this build had no game database" here too, which
        // is noise: an engine build is not supposed to have one.
        final built = await buildWith(_engineBuild());
        expect(built.modelGameNote, isEmpty);
      },
    );

    test('explains the missing database on a build that wanted one', () async {
      final built = await buildWith(_databaseBuild());
      expect(built.modelGameNote, contains('no game database'));
    });

    test('names the database it searched when nothing in it fits', () async {
      // The database loaded and retained games — they just do not follow
      // this repertoire, which is a different thing from not having one and
      // the only one of the two the user can act on.
      final built = await buildWith(
        _databaseBuild(),
        database: _databaseHolding(_unrelatedGame),
      );
      expect(built.modelGameNote, contains('strongest games in the database'));
      expect(built.modelGameNote, contains('follows this repertoire'));
    });
  });

  group('modelGamesPathFor', () {
    test('sits beside the course under a companion name', () {
      expect(
        CourseBuilder.modelGamesPathFor('/books/Benko.pgn'),
        '/books/Benko_model_games.pgn',
      );
    });

    test('replaces the extension rather than appending to it', () {
      expect(
        CourseBuilder.modelGamesPathFor('/books/Sicilian.notpgn'),
        '/books/Sicilian_model_games.pgn',
      );
    });
  });
}
