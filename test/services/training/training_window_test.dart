import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:chess_auto_prep/features/training/models/training_window.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

RepertoireLine _line(
  List<String> moves, {
  Map<String, String> comments = const {},
}) => RepertoireLine(
  id: 'l',
  name: 'l',
  moves: moves,
  color: 'white',
  startPosition: Chess.initial,
  fullPgn: '',
  comments: comments,
);

TrainingSettings _settings({int? depth, bool skipToFirstComment = false}) =>
    TrainingSettings(
      trainingDepth: depth,
      skipToFirstComment: skipToFirstComment,
    );

void main() {
  const moves = ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6'];

  test('the whole line, from the start, by default', () {
    final window = resolveTrainingWindow(
      _line(moves),
      settings: _settings(),
      mode: TrainingMode.repertoire,
    );
    expect(window, (length: 6, startIndex: 0));
  });

  test('training depth clamps the length to the line', () {
    expect(
      resolveTrainingWindow(
        _line(moves),
        settings: _settings(depth: 4),
        mode: TrainingMode.repertoire,
      ).length,
      4,
    );
    expect(
      resolveTrainingWindow(
        _line(moves),
        settings: _settings(depth: 40),
        mode: TrainingMode.repertoire,
      ).length,
      6,
    );
  });

  test('a [%tend] marker stops the quiz after the marked move', () {
    final line = _line(moves, comments: const {'3': '[%tend]'});
    expect(
      resolveTrainingWindow(
        line,
        settings: _settings(),
        mode: TrainingMode.repertoire,
      ).length,
      4,
    );
  });

  test('an end marker before the start marker is ignored', () {
    final line = _line(
      moves,
      comments: const {'1': '[%tend]', '4': '[%tstart]'},
    );
    final window = resolveTrainingWindow(
      line,
      settings: _settings(),
      mode: TrainingMode.tactics,
    );
    expect(window, (length: 6, startIndex: 4));
  });

  test('a [%tstart] marker pins the start in every mode', () {
    final line = _line(moves, comments: const {'2': '[%tstart]'});
    for (final mode in TrainingMode.values) {
      expect(resolveTrainingWindow(line, settings: _settings(), mode: mode), (
        length: 6,
        startIndex: 2,
      ), reason: mode.name);
    }
  });

  test('a start marker past the depth clamp is ignored', () {
    final line = _line(moves, comments: const {'5': '[%tstart]'});
    expect(
      resolveTrainingWindow(
        line,
        settings: _settings(depth: 3),
        mode: TrainingMode.repertoire,
      ),
      (length: 3, startIndex: 0),
    );
  });

  test('skip-to-first-comment starts at the first prose comment, '
      'repertoire mode only', () {
    final line = _line(
      moves,
      comments: const {'1': '[%clk 0:05:00]', '3': 'The Spanish.'},
    );
    expect(
      resolveTrainingWindow(
        line,
        settings: _settings(skipToFirstComment: true),
        mode: TrainingMode.repertoire,
      ).startIndex,
      3,
    );
    expect(
      resolveTrainingWindow(
        line,
        settings: _settings(skipToFirstComment: true),
        mode: TrainingMode.tactics,
      ).startIndex,
      0,
      reason: 'tactics never auto-plays the solution',
    );
  });

  test('firstCommentIndex is 0 when no move inside the window has prose', () {
    final line = _line(moves, comments: const {'5': 'Too late.'});
    expect(firstCommentIndex(line, 4), 0);
    expect(firstCommentIndex(line, 6), 5);
  });
}
