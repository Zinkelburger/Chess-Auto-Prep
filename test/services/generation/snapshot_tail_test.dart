import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/generation/engine_tail.dart';
import 'package:chess_auto_prep/services/generation/export/move_annotation.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/pgn_export.dart';
import 'package:flutter_test/flutter_test.dart';

/// The snapshot/export path — what re-extracting an already-built tree goes
/// through. Its engine tail has to behave the same as the course export's.
String _write({
  EngineTail? tail,
  List<MoveAnnotation> annotations = const [],
  MoveAnnotationDetail detail = MoveAnnotationDetail.full,
}) => writeRepertoireLine(
  movesSan: const ['e4', 'e5', 'Nf3'],
  title: 'L1',
  line: ExtractedLine(
    movesSan: const ['e4', 'e5', 'Nf3'],
    movesUci: const [],
    probability: 0.5,
    moveAnnotations: annotations,
  ),
  isWhiteRepertoire: true,
  rootFen: kStandardStartFen,
  detail: detail,
  rankByImportance: false,
  engineTail: tail,
);

void main() {
  test('no tail leaves the line exactly where preparation ended', () {
    expect(_write(), contains('1. e4 e5 2. Nf3 *'));
  });

  test('the tail extends the mainline, so it is trained', () {
    final pgn = _write(
      tail: const EngineTail(movesSan: ['Nc6', 'Bb5', 'a6'], depth: 22),
      detail: MoveAnnotationDetail.none,
    );

    // No parentheses anywhere: these are line moves, not a variation.
    expect(pgn, contains('1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *'));
    expect(pgn, isNot(contains('(')));
  });

  test('the note lands on the first engine move, not an earlier one', () {
    // Regression: annotations are allowed to be shorter than the moves they
    // describe, and appending onto a short list slid the note onto move 1.
    final pgn = _write(
      tail: const EngineTail(movesSan: ['Nc6', 'Bb5'], depth: 22),
    );

    expect(
      pgn,
      contains(
        'Nc6 {Engine continuation from here at depth 22 — best play, '
        'not prepared theory}',
      ),
    );
    expect(pgn, isNot(contains('e4 {Engine continuation')));
  });

  test('the note survives even with per-move metrics turned off', () {
    // Knowing where preparation stopped is not a metric; it is the one thing
    // a reader needs whatever detail level they picked.
    final pgn = _write(
      tail: const EngineTail(movesSan: ['Nc6'], depth: 22),
      detail: MoveAnnotationDetail.likelihood,
    );

    expect(pgn, contains('Engine continuation from here at depth 22'));
  });

  test('an empty tail is the same as no tail', () {
    expect(
      _write(tail: const EngineTail(movesSan: [], depth: 22)),
      contains('1. e4 e5 2. Nf3 *'),
    );
  });

  test('existing annotations keep their own moves', () {
    final pgn = _write(
      annotations: const [
        MoveAnnotation(evalCp: 30),
        MoveAnnotation(evalCp: 20),
        MoveAnnotation(evalCp: 25),
      ],
      tail: const EngineTail(movesSan: ['Nc6'], depth: 22),
    );

    expect(pgn, contains('1. e4 {[%eval +0.30]}'));
    expect(pgn, contains('Nc6 {Engine continuation'));
  });
}
