import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/generation/course/chapter_titles.dart';
import 'package:chess_auto_prep/services/generation/course/course_composer.dart';
import 'package:chess_auto_prep/services/generation/course/opening_namer.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/line_pruner.dart';
import 'package:flutter_test/flutter_test.dart';

ExtractedLine _line(String moves, {double probability = 0.01}) {
  final san = moves.split(' ').where((m) => m.isNotEmpty).toList();
  return ExtractedLine(movesSan: san, movesUci: san, probability: probability);
}

TreeBuildConfig _config({
  MoveAnnotationDetail detail = MoveAnnotationDetail.likelihood,
}) => TreeBuildConfig(
  startFen: kStandardStartFen,
  playAsWhite: true,
  organizeIntoChapters: false,
  annotationDetail: detail,
);

CourseComposer _composer(
  TreeBuildConfig config, {
  List<String> prefix = const [],
}) => CourseComposer(
  config: config,
  namer: CourseNamer(
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

void main() {
  group('folded lines in the composed course', () {
    final host = _line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4');

    test('a fold is written as a variation off the move it parts on', () {
      final fold = _line('e4 e5 Nf3 Nc6 Bb5 Nf6 O-O', probability: 0.014);
      final course = _composer(_config()).compose(
        lines: [host],
        folds: {
          LinePruner.lineKey(host.movesSan): [
            FoldedLine(line: fold, divergePly: 5, hostRank: 0),
          ],
        },
      );

      final pgn = course.entries.single.pgn;
      // The variation replaces Black's third move and runs to the fold's end.
      expect(pgn, contains('(3... Nf6'));
      expect(pgn, contains('O-O)'));
      expect(pgn, contains('read not drilled'));
      expect(pgn, contains('1.4% of games'));
      // The mainline is untouched: training still quizzes only what it did.
      expect(course.entries.single.movesSan, host.movesSan);
    });

    test('a fold running past the host repeats its last move to continue', () {
      final fold = _line('e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O');
      final course = _composer(_config()).compose(
        lines: [host],
        folds: {
          LinePruner.lineKey(host.movesSan): [
            FoldedLine(line: fold, divergePly: 7, hostRank: 0),
          ],
        },
      );

      // There is no move to play "instead" of, so the sideline restates the
      // host's last move and continues from it.
      expect(course.entries.single.pgn, contains('4. Ba4 (4. Ba4 '));
      expect(course.entries.single.pgn, contains('Nf6 5. O-O)'));
    });

    test('the fold sits after the repertoire prefix, not before it', () {
      const prefix = ['d4', 'Nf6', 'c4', 'c5', 'd5', 'b5'];
      final benkoHost = _line('cxb5 a6 bxa6 Bxa6');
      final fold = _line('cxb5 a6 e3 axb5', probability: 0.02);
      final course = _composer(_config(), prefix: prefix).compose(
        lines: [benkoHost],
        folds: {
          LinePruner.lineKey(benkoHost.movesSan): [
            FoldedLine(line: fold, divergePly: 2, hostRank: 0),
          ],
        },
      );

      // Ply 2 of the line is ply 8 overall — White's fifth move.
      expect(course.entries.single.pgn, contains('5. bxa6 (5. e3 '));
      expect(course.entries.single.pgn, contains('axb5) Bxa6'));
    });

    test('no folds is the document the composer always wrote', () {
      final withFolds = _composer(_config()).compose(lines: [host], folds: {});
      final without = _composer(_config()).compose(lines: [host]);
      expect(withFolds.entries.single.pgn, without.entries.single.pgn);
    });

    test('a bare movetext export writes the moves but not the note', () {
      final fold = _line('e4 e5 Nf3 Nc6 Bb5 Nf6 O-O');
      final course = _composer(_config(detail: MoveAnnotationDetail.none))
          .compose(
            lines: [host],
            folds: {
              LinePruner.lineKey(host.movesSan): [
                FoldedLine(line: fold, divergePly: 5, hostRank: 0),
              ],
            },
          );
      expect(course.entries.single.pgn, contains('(3... Nf6'));
      expect(course.entries.single.pgn, isNot(contains('read not drilled')));
    });
  });
}
